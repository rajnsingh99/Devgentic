// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
//
//  WorkflowInputAssembler.swift
//  Devgentic
//
//  Created by Raj Singh.
//

import Foundation
import os

private let assemblerLogger = DGLogger(category: "WorkflowInputAssembler")

/// Assembles upstream node results into the input a downstream workflow node receives:
/// compiled text (`compileForWorkflow`), the artifact manifest (`renderArtifactManifest`),
/// and inlined document text (`extractDocumentText`). Nothing here truncates.
enum WorkflowInputAssembler {

    // MARK: - Workflow Compilation

    // Why: a node's input is unbounded: the author picks the downstream model, and sizes are logged per upstream and in
    // total for field reports.
    /// Compiles upstream node outputs into a downstream node's `<input>`: a single upstream arrives bare, several are
    /// separated by `---`. Only `.completed` results are included unless `includeFailures` is true, which also surfaces
    /// failed upstreams with their reason. Nothing is truncated.
    static func compileForWorkflow(
        results: [NodeResultEnvelope],
        includeFailures: Bool = false
    ) -> String {
        // Normally only completed results contribute; with `includeFailures` (an error handler on an upstream's `error` port)
        // failed results are included too, annotated with their reason.
        let usableResults = results.filter { result in
            switch result.status {
            case .completed:            return true
            case .failed:               return includeFailures
            // A user-skipped upstream carries its input as its output and counts as an arrival everywhere, including fan-in joins,
            // so chained user skips compose.
            case .skipped(reason: .byUser): return true
            case .canceled, .skipped:   return false
            }
        }

        guard !usableResults.isEmpty else {
            assemblerLogger.info("compileForWorkflow: no usable upstream results, returning empty")
            return ""
        }

        assemblerLogger.info("compileForWorkflow: \(usableResults.count)/\(results.count) usable results (includeFailures=\(includeFailures)), no truncation")

        var sections: [String] = []

        for (index, result) in usableResults.enumerated() {
            assemblerLogger.info("  [\(index)] '\(result.profileName)': \(result.output.count) chars (passed through in full)")
            assemblerLogger.debug("  [\(index)] '\(result.profileName)' preview: \(String(result.output.prefix(200)))")

            // Annotate an error-routed failed upstream so the downstream handler has
            // the failure reason alongside whatever partial output was produced.
            if case .failed(let reason) = result.status {
                let note = "[Upstream node \"\(result.profileName)\" failed: \(reason.localizedDescription)]"
                sections.append(result.output.isEmpty ? note : note + "\n\n" + result.output)
            } else {
                sections.append(result.output)
            }
        }

        // Join: single result = raw text, multiple = separated by ---
        let body = sections.count == 1
            ? sections[0]
            : sections.joined(separator: "\n\n---\n\n")

        // Not a cap but an observability floor: an oversized prompt fails at the provider with a message that does not name the
        // workflow node.
        if body.count > 100_000 {
            assemblerLogger.warning("compileForWorkflow: compiled \(body.count) chars from \(usableResults.count) upstream(s) — NOT truncated (by design). CONSEQUENCE: if the downstream node's model has a smaller context window this request will fail at the provider. Reduce what the upstream nodes emit, or point that node at a larger-context model.")
        } else {
            assemblerLogger.info("compileForWorkflow: output \(body.count) chars")
        }
        return body
    }

    // MARK: - Untrusted-content escaping [WF-SE2 / WF-SE5]

    // Why: call it only where content may be upstream, third-party or installed (not user-authored): escaping elsewhere
    // corrupts a legitimate `<T>`.
    /// Escapes XML-significant characters so untrusted content (upstream output, artifact labels, document text, ChatOps
    /// attachments) cannot close the section it is embedded in. `&` runs first, and it is a no-op for Markdown wrapping,
    /// which has no closing delimiter.
    static func escapeIfBoundaryThreat(
        _ text: String, section: String, wrapping: PromptWrapping, logTag: String = "[WF_EXEC]"
    ) -> String {
        guard wrapping == .xml else { return text }
        guard text.range(of: "</\(section)", options: .caseInsensitive) != nil else { return text }
        assemblerLogger.notice("\(logTag) A payload bound for the <\(section)> section contains its closing tag ('</\(section)') and was entity-escaped IN FULL (\(text.count) chars). CONSEQUENCE: the section boundary cannot be forged, but this payload reaches the model with &/</> as XML entities — if it was legitimate markup that must stay verbatim, rename or wrap the offending text upstream.")
        return escapeForXMLEmbedding(text, wrapping: wrapping)
    }

    static func escapeForXMLEmbedding(_ text: String, wrapping: PromptWrapping) -> String {
        switch wrapping {
        case .markdown: return text
        case .xml:
            return text
                .replacingOccurrences(of: "&", with: "&amp;")
                .replacingOccurrences(of: "<", with: "&lt;")
                .replacingOccurrences(of: ">", with: "&gt;")
        }
    }

    // MARK: - Artifact Passing (Workflow media/file handoff)

    // Document text is inlined in full; oversized totals are logged (like `compileForWorkflow`'s 100k warning), never
    // truncated, since fitting the downstream model's context window is the author's call.

    /// Maximum number of artifacts enumerated in the manifest. Bounds the manifest
    /// section so a node fanned-in from many media-producing branches can't emit an
    /// unbounded file list into the prompt; overflow is summarised as a count.
    static let maxManifestEntries: Int = 25

    /// Renders a compact manifest of upstream artifacts: kind, label, mime type and a resolvable locator (disk path or
    /// remote URL) per line. Returns an empty string when there are no artifacts; cheap and synchronous, capped at
    /// `maxManifestEntries` lines.
    static func renderArtifactManifest(_ artifacts: [MediaArtifact]) -> String {
        guard !artifacts.isEmpty else { return "" }

        // The manifest is pre-escaped field by field and must not be escaped again: only the label is untrusted, while locator,
        // kind and mime are app-produced and must reach the agent byte-exact (a path with `R&D` must not become `R&amp;D`).
        var lines: [String] = artifacts.prefix(maxManifestEntries).enumerated().map { index, artifact in
            let label = artifact.label
                ?? Self.locatorName(for: artifact.reference)
                ?? "untitled"
            let safeLabel = escapeForXMLEmbedding(label, wrapping: .xml)
            let locator = Self.locatorDescription(for: artifact.reference)
            return "\(index + 1). [\(artifact.kind.rawValue)] \"\(safeLabel)\" (\(artifact.mimeType)) — \(locator)"
        }
        if artifacts.count > maxManifestEntries {
            lines.append("…and \(artifacts.count - maxManifestEntries) more file(s).")
        }

        return """
        The following file(s) were produced by upstream steps and are available to you:
        \(lines.joined(separator: "\n"))
        """
    }

    /// Extracts and concatenates the text of `.document` artifacts with a resolvable disk path via `FileProcessorService`,
    /// so a text model can read them. Returns the text plus a typed list of documents it could not retrieve; failures are
    /// skipped, not fatal. Nothing is truncated.
    static func extractDocumentText(
        from artifacts: [MediaArtifact],
        fileProcessor: FileProcessorService
    ) async -> (text: String, failures: [FileRetrievalError]) {
        let documents = artifacts.filter { $0.kind == .document }
        guard !documents.isEmpty else { return ("", []) }

        var sections: [String] = []
        var failures: [FileRetrievalError] = []

        for artifact in documents {
            guard case .diskPath(let url) = artifact.reference else {
                // The manifest can't help here either: an `.ephemeralData` locator renders as
                // "<in-memory data, N bytes>", so this document is invisible to the node.
                assemblerLogger.warning("[WF_CONTEXT] Document artifact '\(artifact.label ?? "untitled")' has no disk path (in-memory or remote reference) and cannot be inlined. CONSEQUENCE: the downstream node sees this document only as a manifest entry it cannot read — persist the artifact to disk upstream if its content matters.")
                continue
            }

            do {
                // `Int.max` on purpose: no layer here may cut a document; extractors treat `maxSize` as a hard cap and the plain-text
                // reader throws above it.
                let text = try await fileProcessor.readFileContentOrThrow(for: url, maxSize: Int.max)
                let name = artifact.label ?? url.lastPathComponent
                guard !text.isEmpty else {
                    assemblerLogger.notice("[WF_CONTEXT] Document '\(name)' extracted to EMPTY text and is not inlined. CONSEQUENCE: the downstream node sees it only in the manifest — if it should contribute content, check the file is not image-only (e.g. a scanned PDF with no text layer).")
                    continue
                }
                sections.append("--- \(name) ---\n\(text)")
            } catch let retrievalError as FileRetrievalError {
                failures.append(retrievalError)
            } catch {
                failures.append(.readFailed(path: url.path, underlying: error.localizedDescription))
            }
        }

        let text = sections.joined(separator: "\n\n")
        if text.count > 100_000 {
            assemblerLogger.warning("[WF_CONTEXT] extractDocumentText: inlined \(text.count) chars from \(sections.count) document(s) — NOT truncated (by design, 2026-08-15). CONSEQUENCE: if the downstream node's model has a smaller context window this request will fail at the provider. Attach smaller documents, or point that node at a larger-context model.")
        } else {
            assemblerLogger.info("[WF_CONTEXT] extractDocumentText: inlined \(text.count) chars from \(sections.count) of \(documents.count) document(s), \(failures.count) failure(s).")
        }
        return (text, failures)
    }

    /// Best-effort display name from a media reference (file name for disk/remote).
    private static func locatorName(for reference: MediaReference) -> String? {
        switch reference {
        case .diskPath(let url), .remoteURL(let url): return url.lastPathComponent
        case .ephemeralData: return nil
        }
    }

    /// Resolvable locator string for the manifest.
    private static func locatorDescription(for reference: MediaReference) -> String {
        switch reference {
        case .diskPath(let url): return url.path
        case .remoteURL(let url): return url.absoluteString
        case .ephemeralData(let data): return "<in-memory data, \(data.count) bytes>"
        }
    }

}
