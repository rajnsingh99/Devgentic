// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
//
//  FileReferenceResolver.swift
//  Devgentic
//
//  Created by Raj Singh.
//

import Foundation

private let logger = DGLogger(category: "FileReferenceResolver")

/// Decides which inline code spans in a chat message are file references the user can tap to open in the Code Viewer.
/// A span qualifies as an absolute path or as a bare filename the conversation read or wrote; the file must exist.
/// Candidate extraction is pure (no I/O); existence checking is separate and belongs off the main thread.
enum FileReferenceResolver {

    /// Longest span still considered — well past any real path, short enough that a pasted
    /// blob of code inside backticks is rejected before any per-character work.
    static let maxPathLength = 1024

    /// Returns true when `span` is shaped like an absolute file path; pure, no filesystem access.
    /// Rejects over-long spans, anything not rooted at `/` or `~/`, interior whitespace, and trailing-slash directories.
    static func looksLikeAbsolutePath(_ span: String) -> Bool {
        let trimmed = span.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.count <= maxPathLength else { return false }
        guard trimmed.hasPrefix("/") || trimmed.hasPrefix("~/") else { return false }
        // A path with a space is legal, but in a code span it is far more often a command (`/usr/bin/env python x.py`),
        // so requiring no whitespace is the conservative read.
        guard !trimmed.contains(where: { $0.isWhitespace }) else { return false }
        guard !trimmed.hasSuffix("/") else { return false }
        // Bare `/` and `~/` are roots, not files.
        guard trimmed != "/", trimmed != "~/" else { return false }
        return true
    }

    /// The absolute filesystem path for a span, with `~` expanded. Nil when the span isn't
    /// path-shaped. Still pure — this does NOT assert the file exists.
    static func candidatePath(_ span: String) -> String? {
        guard looksLikeAbsolutePath(span) else { return nil }
        let trimmed = span.trimmingCharacters(in: .whitespacesAndNewlines)
        return (trimmed as NSString).expandingTildeInPath
    }

    // MARK: - Bare filenames

    /// Longest span still considered as a bare filename. macOS caps a single path component
    /// at 255 bytes, so anything longer cannot be one.
    static let maxFileNameLength = 255

    /// Returns true when `span` could be a bare filename (no directory part, no whitespace).
    /// Deliberately permissive: a bare name only resolves if the conversation touched a file of that name.
    static func looksLikeBareFileName(_ span: String) -> Bool {
        let trimmed = span.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.count <= maxFileNameLength else { return false }
        guard !trimmed.contains("/") else { return false }
        guard !trimmed.contains(where: { $0.isWhitespace }) else { return false }
        // "." and ".." are directory entries, not files anyone means to open.
        guard trimmed != ".", trimmed != ".." else { return false }
        return true
    }

    /// Resolves a span to an openable absolute path: an absolute path by shape, or a bare
    /// filename via `index`. Still pure — existence is checked separately.
    static func candidatePath(_ span: String, in index: [String: String]) -> String? {
        if let absolute = candidatePath(span) { return absolute }
        guard looksLikeBareFileName(span) else { return nil }
        return index[span.trimmingCharacters(in: .whitespacesAndNewlines)]
    }

    /// Every candidate path in a markdown block, resolving bare filenames through `index`.
    /// Returns span → absolute path, since a bare span cannot be re-derived later.
    static func candidateLinks(inMarkdown text: String, index: [String: String]) -> [String: String] {
        candidateLinks(inCodeSpans: codeSpans(inMarkdown: text), index: index)
    }

    /// Returns every distinct candidate path in a rendered block, in no particular order.
    /// Takes already-parsed code spans rather than re-scanning markdown, so only text marked as code is eligible.
    static func candidates(inCodeSpans spans: [String]) -> Set<String> {
        Set(spans.compactMap(candidatePath))
    }

    /// Maps each code span to its candidate path, for spans the caller has already parsed.
    /// A dictionary rather than a `Set`: a bare filename cannot be re-derived from its path.
    static func candidateLinks(inCodeSpans spans: [String], index: [String: String]) -> [String: String] {
        var links: [String: String] = [:]
        for span in spans {
            let key = span.trimmingCharacters(in: .whitespacesAndNewlines)
            guard links[key] == nil, let path = candidatePath(span, in: index) else { continue }
            links[key] = path
        }
        return links
    }

    /// Returns the text of every inline code span in a markdown string.
    /// Uses the same parse as `ContentBlockView.createStyledString`, so verified spans match the runs considered for links.
    static func codeSpans(inMarkdown text: String) -> [String] {
        guard let parsed = try? AttributedString(markdown: text) else { return [] }
        return parsed.runs.compactMap { run in
            guard (run.inlinePresentationIntent ?? []).contains(.code) else { return nil }
            // A link whose label is inline code never reaches here: `AttributedString(markdown:)` drops `.code` on link labels,
            // so no `run.link == nil` guard is needed (pinned by `LinkedCodeSpanTests`).
            return String(parsed[run.range].characters)
        }
    }

    /// Candidate paths in a markdown block — pure, no I/O. Feed the result to
    /// `verifyExisting` off-main.
    static func candidates(inMarkdown text: String) -> Set<String> {
        candidates(inCodeSpans: codeSpans(inMarkdown: text))
    }

    /// Filters `candidates` down to readable regular files that exist right now.
    /// Blocking: every entry is a `stat`, so call it off the main thread (a network mount can hang for seconds).
    static func verifyExisting(_ candidates: Set<String>) -> Set<String> {
        var verified: Set<String> = []
        for path in candidates {
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory),
                  !isDirectory.boolValue else { continue }
            verified.insert(path)
        }
        return verified
    }

    // MARK: - The conversation's own files

    /// Params longer than this are not scanned for a path.
    /// A write's params carry the whole file as `content`, and writes already carry `effect.path`, so skipping them is free.
    static let maxParamsScanLength = 2_048

    /// Returns `basename → absolute path` for files this conversation actually read or wrote; membership is the filter.
    /// Ambiguous basenames (same name in two directories) are dropped, since opening the wrong file is worse than no link.
    static func fileIndex(from messages: [ChatMessage]) -> [String: String] {
        var index: [String: String] = [:]
        var ambiguous: Set<String> = []

        func note(_ path: String) {
            let name = (path as NSString).lastPathComponent
            guard !name.isEmpty, !ambiguous.contains(name) else { return }
            if let existing = index[name], existing != path {
                index.removeValue(forKey: name)
                ambiguous.insert(name)
                logger.debug("[FileRef] '\(name)' names two different files in this conversation — left unlinked rather than guessing between \(existing) and \(path).")
                return
            }
            index[name] = path
        }

        for message in messages {
            for event in message.flattenedTimelineEvents {
                guard case .toolExecution(let data) = event else { continue }
                // Cheapest first: a write's effect is already decoded and persisted, so it
                // survives a relaunch when the session-scoped snapshots do not.
                if let path = data.effect?.path {
                    note(path)
                    continue
                }
                // Reads and other file-touching calls: resolve from params, but only when
                // they're small enough that decoding is free.
                guard data.params.count <= maxParamsScanLength,
                      let action = TimelineFileViewerAction.resolve(data: data) else { continue }
                note(action.filePath)
            }
        }
        return index
    }

    // MARK: - Link URLs

    /// Private link scheme, deliberately not `file:`: an unhandled `file:` link would be opened by the system,
    /// whereas an unhandled private scheme does nothing.
    static let scheme = "devgentic-file"

    /// The link URL for a verified path. Percent-encodes so spaces and unicode survive.
    static func linkURL(forVerifiedPath path: String) -> URL? {
        var components = URLComponents()
        components.scheme = scheme
        components.host = "open"
        components.queryItems = [URLQueryItem(name: "path", value: path)]
        return components.url
    }

    /// Returns the path carried by one of our link URLs, or nil if the URL is not ours.
    /// This is a parser, not an authorisation check: a model can write such a link, so callers must check the path
    /// against the set they actually verified (`ContentBlockView` uses `resolvedFileLinks`).
    static func path(fromLinkURL url: URL) -> String? {
        guard url.scheme == scheme, url.host == "open" else { return nil }
        guard let path = URLComponents(url: url, resolvingAgainstBaseURL: false)?
            .queryItems?.first(where: { $0.name == "path" })?.value,
              !path.isEmpty else { return nil }
        return path
    }
}
