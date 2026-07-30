//
//  FileReferenceResolver.swift
//  Devgentic
//
//  Decides which inline `code` spans in a chat message are FILE REFERENCES the user can tap
//  to open in the Code Viewer.
//
//  A model's prose is full of inline code that looks file-ish but isn't — `Double.NaN`,
//  `System.out.println`, `array.map`, `AbstractionDemo`. A shape rule ("has a dot and an
//  extension") would linkify most of them, and every dead link costs more trust than the live
//  ones earn. So a span qualifies only two ways, and NEITHER is shape alone:
//
//    1. ABSOLUTE PATH — rooted at `/` or `~/`, no whitespace, not a directory.
//    2. BARE FILENAME — matches, exactly, a file this conversation actually read or wrote
//       (see `fileIndex(from:)`). Membership in that index is the filter; `Double.NaN` was
//       never a tool argument, so it can never resolve.
//
//  Both then require a readable regular file to exist at the resolved path RIGHT NOW.
//
//  SILENT BY DESIGN: a span that doesn't qualify stays plain text. There is no "couldn't open"
//  state, because there is no link to tap in the first place.
//
//  Candidate extraction here is PURE and synchronous — it does no I/O, so it is safe to call
//  from a view body. Existence checking is separate and belongs off the main thread; see
//  `verifyExisting(_:)` and its caller in `ContentBlockView`.
//

import Foundation

private let logger = DGLogger(category: "FileReferenceResolver")

enum FileReferenceResolver {

    /// Longest span still considered — well past any real path, short enough that a pasted
    /// blob of code inside backticks is rejected before any per-character work.
    static let maxPathLength = 1024

    /// True when `span` is SHAPED like an absolute file path. Pure, no filesystem access.
    ///
    /// Rejects, in order: over-long spans, anything not rooted at `/` or `~/`, spans with
    /// interior whitespace or newlines (prose, shell command lines, `cd /tmp && ls`), and
    /// directories written with a trailing slash — the viewer opens files, not folders.
    static func looksLikeAbsolutePath(_ span: String) -> Bool {
        let trimmed = span.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.count <= maxPathLength else { return false }
        guard trimmed.hasPrefix("/") || trimmed.hasPrefix("~/") else { return false }
        // A path with a space in it is legal on macOS, but inside a markdown code span it is
        // far more often a command (`/usr/bin/env python x.py`). Requiring no whitespace is
        // the conservative read, and matches how these paths are actually emitted.
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

    /// True when `span` could be a bare filename — no directory part, no whitespace.
    ///
    /// Deliberately permissive, because shape is NOT the filter here: a bare name only
    /// resolves if the conversation actually touched a file called that (see
    /// `candidatePath(_:in:)`). Trying to recognise "looks like a filename" by shape is what
    /// linkifies `Double.NaN` and `array.map`; membership in the index cannot.
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
        var links: [String: String] = [:]
        for span in codeSpans(inMarkdown: text) {
            let key = span.trimmingCharacters(in: .whitespacesAndNewlines)
            guard links[key] == nil, let path = candidatePath(span, in: index) else { continue }
            links[key] = path
        }
        return links
    }

    /// Every distinct candidate path in a rendered block, in no particular order.
    ///
    /// Takes the already-parsed runs rather than re-scanning the markdown, so a path in
    /// ordinary prose is ignored: only text the author marked as code is eligible.
    static func candidates(inCodeSpans spans: [String]) -> Set<String> {
        Set(spans.compactMap(candidatePath))
    }

    /// The text of every inline `code` span in a markdown string.
    ///
    /// Parses with the same call `ContentBlockView.createStyledString` uses, so the spans
    /// verified here are exactly the runs that will be considered for linking. Deriving them
    /// from a different parse would let the two drift and produce links on the wrong ranges.
    static func codeSpans(inMarkdown text: String) -> [String] {
        guard let parsed = try? AttributedString(markdown: text) else { return [] }
        return parsed.runs.compactMap { run in
            guard (run.inlinePresentationIntent ?? []).contains(.code) else { return nil }
            return String(parsed[run.range].characters)
        }
    }

    /// Candidate paths in a markdown block — pure, no I/O. Feed the result to
    /// `verifyExisting` off-main.
    static func candidates(inMarkdown text: String) -> Set<String> {
        candidates(inCodeSpans: codeSpans(inMarkdown: text))
    }

    /// Filters `candidates` down to those that are readable REGULAR files right now.
    ///
    /// BLOCKING — every entry is a `stat`. Call it off the main thread. A path on an
    /// unresponsive network mount can hang this for seconds, which is exactly why it must
    /// never sit in a view body.
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

    /// Params beyond this are not scanned for a path.
    ///
    /// A write's params carry the ENTIRE file as `content`, so JSON-decoding every tool call
    /// in a long conversation would parse megabytes to find a handful of paths. Writes don't
    /// need it — they already carry `effect.path` — so the cap only ever skips calls whose
    /// path is already known by a cheaper route.
    static let maxParamsScanLength = 2_048

    /// `basename → absolute path`, built from the files this conversation actually touched.
    ///
    /// This index is the whole reason bare filenames are safe. A shape rule ("has a dot and an
    /// extension") would linkify `Double.NaN`, `System.out.println` and `array.map`; requiring
    /// the name to match a file the agent genuinely read or wrote cannot, because those names
    /// were never tool arguments.
    ///
    /// AMBIGUITY IS DROPPED, NOT GUESSED. If a conversation touched both `src/Main.java` and
    /// `test/Main.java`, a bare `Main.java` is genuinely unresolvable — and opening the wrong
    /// file is worse than not linking, because it is silent. The name is excluded entirely.
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

    /// Private scheme, deliberately not `file:`. An unhandled `file:` link would be opened by
    /// the SYSTEM — launching Xcode, or worse, whatever is registered for that extension —
    /// on any surface where our `OpenURLAction` isn't installed. An unhandled private scheme
    /// does nothing, which is the correct failure for a silent feature.
    static let scheme = "devgentic-file"

    /// The link URL for a verified path. Percent-encodes so spaces and unicode survive.
    static func linkURL(forVerifiedPath path: String) -> URL? {
        var components = URLComponents()
        components.scheme = scheme
        components.host = "open"
        components.queryItems = [URLQueryItem(name: "path", value: path)]
        return components.url
    }

    /// The path carried by one of our link URLs, or nil if this isn't one of ours.
    static func path(fromLinkURL url: URL) -> String? {
        guard url.scheme == scheme, url.host == "open" else { return nil }
        guard let path = URLComponents(url: url, resolvingAgainstBaseURL: false)?
            .queryItems?.first(where: { $0.name == "path" })?.value,
              !path.isEmpty else { return nil }
        return path
    }
}
