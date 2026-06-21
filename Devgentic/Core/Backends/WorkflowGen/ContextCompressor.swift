//
//  ContextCompressor.swift
//  Devgentic
//
//  Created by Raj Singh on 13/03/26.
//
//  Token budget management for upstream context injection.
//  Compresses upstream node outputs to fit within a character budget
//  before injecting them into the next node's system instructions.
//

import Foundation
import os

private let compressorLogger = DGLogger(category: "ContextCompressor")

/// Compresses upstream node results into a context string suitable for
/// injection into a downstream node's system instructions.
enum ContextCompressor {

    /// Maximum characters per individual upstream result.
    static let maxCharsPerUpstream: Int = 2000

    /// Maximum total characters for all upstream context combined.
    static let maxTotalContextChars: Int = 6000

    // MARK: - Compile Context

    /// Compiles upstream results into a structured context preamble string.
    /// Applies truncation to stay within the token budget.
    /// Media artifacts are included as text references when the target model
    /// does not support the required modality.
    ///
    /// - Parameters:
    ///   - results: The upstream `NodeResultEnvelope` values to include.
    ///   - targetModalities: The downstream model's supported modalities (defaults to `.textOnly`).
    ///   - budget: Maximum total characters for the compiled context (defaults to `maxTotalContextChars`).
    ///   - perNodeBudget: Maximum characters per individual upstream result (defaults to `maxCharsPerUpstream`).
    /// - Returns: A formatted string block ready for injection into system instructions.
    static func compile(
        results: [NodeResultEnvelope],
        targetModalities: SupportedModalities = .textOnly,
        budget: Int = maxTotalContextChars,
        perNodeBudget: Int = maxCharsPerUpstream
    ) -> String {
        guard !results.isEmpty else {
            compressorLogger.info("Compile: no upstream results, returning empty context")
            return ""
        }

        var sections: [String] = []
        let perResultBudget = min(perNodeBudget, budget / results.count)
        compressorLogger.info("Compile: \(results.count) upstream results, totalBudget=\(budget), perNodeBudget=\(perNodeBudget), perResultBudget=\(perResultBudget)")

        for (index, result) in results.enumerated() {
            let statusLabel: String
            switch result.status {
            case .completed: statusLabel = "Completed"
            case .failed(let reason): statusLabel = "Failed: \(reason.localizedDescription)"
            case .canceled: statusLabel = "Canceled"
            case .skipped(let reason): statusLabel = "Skipped: \(reason)"
            }

            let truncatedOutput: String
            let originalSize = result.output.count
            if originalSize > perResultBudget {
                truncatedOutput = Self.truncateAtBoundary(result.output, maxLength: perResultBudget)
                    + "\n[... output truncated to ~\(perResultBudget) characters ...]"
                compressorLogger.info("  [\(index + 1)] '\(result.profileName)': \(originalSize) chars → truncated to ~\(perResultBudget)")
            } else {
                truncatedOutput = result.output
                compressorLogger.info("  [\(index + 1)] '\(result.profileName)': \(originalSize) chars (within budget)")
            }
            compressorLogger.debug("  [\(index + 1)] '\(result.profileName)' content preview: \(String(result.output.prefix(300)))")

            let section = """
            --- [Step \(index + 1): \(result.profileName) (\(result.profileType.rawValue))] ---
            Status: \(statusLabel)
            \(truncatedOutput)
            """
            sections.append(section)
        }

        let body = sections.joined(separator: "\n\n")

        // Final budget enforcement on the entire block
        let preamble = """
        ### UPSTREAM WORKFLOW CONTEXT
        The following results were produced by earlier steps in this workflow pipeline.
        Use them as context to inform your response.

        \(body)
        ---
        """

        if preamble.count > budget {
            compressorLogger.warning("Final preamble \(preamble.count) chars exceeds budget \(budget), applying final truncation")
            return truncateAtBoundary(preamble, maxLength: budget) + "\n[... context truncated ...]"
        }

        compressorLogger.info("Compiled context: \(preamble.count) chars (budget: \(budget))")
        return preamble
    }

    // MARK: - Workflow Compilation

    /// Compiles upstream results into a clean `<input>` block for workflow nodes.
    ///
    /// Unlike `compile()` (which adds metadata headers, step labels, and status lines),
    /// this method produces raw text that a downstream node can process without
    /// knowing it's in a workflow. Only `.completed` results are included by
    /// default; pass `includeFailures: true` to also surface error-routed failed
    /// upstreams (each annotated with its failure reason) so an error-handler node
    /// can see what failed and any partial output.
    ///
    /// Output format:
    /// - Single upstream: raw text (no wrapper, no separator)
    /// - Multiple upstreams: text blocks separated by `\n\n---\n\n`
    /// - A failed upstream (when included) is prefixed with a one-line failure note.
    ///
    /// - Parameters:
    ///   - results: Upstream `NodeResultEnvelope` values.
    ///   - budget: Maximum total characters (defaults to `maxTotalContextChars`).
    ///   - perNodeBudget: Maximum characters per upstream (defaults to `maxCharsPerUpstream`).
    ///   - includeFailures: When true, `.failed` upstreams are included and annotated
    ///     with their reason (used by error-recovery routing). Default false.
    /// - Returns: Clean text ready for injection into `<input>` tag. Empty string if no usable results.
    static func compileForWorkflow(
        results: [NodeResultEnvelope],
        budget: Int = maxTotalContextChars,
        perNodeBudget: Int = maxCharsPerUpstream,
        includeFailures: Bool = false
    ) -> String {
        // Normally only completed results contribute — failed/skipped are handled
        // by the executor's dependency logic. When `includeFailures` is set (the
        // consumer is an error handler wired to an upstream's `error` port), failed
        // results are included too and annotated below with their reason.
        let usableResults = results.filter { result in
            switch result.status {
            case .completed:            return true
            case .failed:               return includeFailures
            case .canceled, .skipped:   return false
            }
        }

        guard !usableResults.isEmpty else {
            compressorLogger.info("compileForWorkflow: no usable upstream results, returning empty")
            return ""
        }

        let perResultBudget = min(perNodeBudget, budget / usableResults.count)
        compressorLogger.info("compileForWorkflow: \(usableResults.count)/\(results.count) usable results (includeFailures=\(includeFailures)), totalBudget=\(budget), perResultBudget=\(perResultBudget)")

        var sections: [String] = []

        for (index, result) in usableResults.enumerated() {
            let originalSize = result.output.count
            let truncatedOutput: String

            if originalSize > perResultBudget {
                // Append a visible marker so the downstream node (and its model) knows
                // its input was cut, rather than silently receiving a partial output.
                truncatedOutput = truncateAtBoundary(result.output, maxLength: perResultBudget)
                    + "\n[... upstream output truncated to ~\(perResultBudget) characters ...]"
                compressorLogger.info("  [\(index)] '\(result.profileName)': \(originalSize) chars → truncated to ~\(perResultBudget)")
            } else {
                truncatedOutput = result.output
                compressorLogger.info("  [\(index)] '\(result.profileName)': \(originalSize) chars (within budget)")
            }
            compressorLogger.debug("  [\(index)] '\(result.profileName)' preview: \(String(result.output.prefix(200)))")

            // Annotate an error-routed failed upstream so the downstream handler has
            // the failure reason alongside whatever partial output was produced.
            if case .failed(let reason) = result.status {
                let note = "[Upstream node \"\(result.profileName)\" failed: \(reason.localizedDescription)]"
                sections.append(truncatedOutput.isEmpty ? note : note + "\n\n" + truncatedOutput)
            } else {
                sections.append(truncatedOutput)
            }
        }

        // Join: single result = raw text, multiple = separated by ---
        let body = sections.count == 1
            ? sections[0]
            : sections.joined(separator: "\n\n---\n\n")

        // Final budget enforcement
        if body.count > budget {
            compressorLogger.warning("compileForWorkflow: output \(body.count) chars exceeds budget \(budget), applying final truncation")
            return truncateAtBoundary(body, maxLength: budget)
        }

        compressorLogger.info("compileForWorkflow: output \(body.count) chars (budget: \(budget))")
        return body
    }

    // MARK: - Artifact Passing (Workflow media/file handoff)

    /// Maximum characters of extracted document text to inline into a downstream
    /// node's input. Separate from the node-output budget so a large attached PDF
    /// can't crowd out the upstream nodes' actual responses.
    static let maxArtifactTextChars: Int = 4000

    /// Maximum number of artifacts enumerated in the manifest. Bounds the manifest
    /// section so a node fanned-in from many media-producing branches can't emit an
    /// unbounded file list into the prompt; overflow is summarised as a count.
    static let maxManifestEntries: Int = 25

    /// Renders a compact, human/agent-readable manifest of upstream artifacts.
    ///
    /// Each line names the kind, label, mime type, and a resolvable locator (disk
    /// path or remote URL) so a downstream agent with file/HTTP tools can act on it.
    /// Returns an empty string when there are no artifacts. Cheap and synchronous —
    /// safe to call from prompt-build time. Capped at `maxManifestEntries` lines.
    static func renderArtifactManifest(_ artifacts: [MediaArtifact]) -> String {
        guard !artifacts.isEmpty else { return "" }

        var lines: [String] = artifacts.prefix(maxManifestEntries).enumerated().map { index, artifact in
            let label = artifact.label
                ?? Self.locatorName(for: artifact.reference)
                ?? "untitled"
            let locator = Self.locatorDescription(for: artifact.reference)
            return "\(index + 1). [\(artifact.kind.rawValue)] \"\(label)\" (\(artifact.mimeType)) — \(locator)"
        }
        if artifacts.count > maxManifestEntries {
            lines.append("…and \(artifacts.count - maxManifestEntries) more file(s).")
        }

        return """
        The following file(s) were produced by upstream steps and are available to you:
        \(lines.joined(separator: "\n"))
        """
    }

    /// Extracts and concatenates the text of `.document` artifacts (PDF, DOCX, XLSX,
    /// CSV, PPTX, RTF, plain text) via `FileProcessorService`, so a downstream text
    /// model can read attached documents even without native file support.
    ///
    /// Only `.document` artifacts backed by a resolvable disk path are extracted —
    /// images/audio/video can't be turned into text (they surface via the manifest
    /// and, later, native multimodal input). Output is bounded by `budget`.
    /// Returns the concatenated text plus a typed list of documents that couldn't be
    /// retrieved (via the throwing `readFileContentOrThrow`, preserving the real
    /// cause). Report-and-skip: the caller traces/surfaces the failures and the node
    /// continues with whatever extracted (this is enrichment, not a hard dependency).
    static func extractDocumentText(
        from artifacts: [MediaArtifact],
        budget: Int = maxArtifactTextChars,
        fileProcessor: FileProcessorService
    ) async -> (text: String, failures: [FileRetrievalError]) {
        let documents = artifacts.filter { $0.kind == .document }
        guard !documents.isEmpty, budget > 0 else { return ("", []) }

        // Even per-document share (floored) so the first document can't consume the
        // entire budget and starve the rest — two attached PDFs each get a fair cut.
        // Unused share is left on the table rather than reallocated, keeping the
        // total bounded by `budget`.
        let perDocBudget = max(500, budget / documents.count)

        var sections: [String] = []
        var failures: [FileRetrievalError] = []
        var used = 0

        for artifact in documents {
            guard used < budget else { break }
            guard case .diskPath(let url) = artifact.reference else { continue }

            do {
                let text = try await fileProcessor.readFileContentOrThrow(for: url, maxSize: perDocBudget)
                guard !text.isEmpty else { continue }
                let name = artifact.label ?? url.lastPathComponent
                let clipped = text.count > perDocBudget
                    ? truncateAtBoundary(text, maxLength: perDocBudget) + "\n[... document truncated ...]"
                    : text
                sections.append("--- \(name) ---\n\(clipped)")
                used += clipped.count
            } catch let retrievalError as FileRetrievalError {
                failures.append(retrievalError)
            } catch {
                failures.append(.readFailed(path: url.path, underlying: error.localizedDescription))
            }
        }

        return (sections.joined(separator: "\n\n"), failures)
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

    // MARK: - Boundary-Aware Truncation

    /// Truncates text at the nearest sentence or word boundary before `maxLength`.
    /// Searches the last 20% of the cut region for a boundary (min 20 chars to avoid
    /// empty search ranges on small budgets). Falls back to hard cut if no boundary found.
    private static func truncateAtBoundary(_ text: String, maxLength: Int) -> String {
        guard maxLength > 0, text.count > maxLength else { return text.count > maxLength ? String(text.prefix(max(maxLength, 0))) : text }

        let cutRegion = text.prefix(maxLength)

        // Search window: last 20% of budget, but at least 20 chars (avoids empty range for small budgets)
        let lookbackSize = max(20, maxLength / 5)
        let searchFloor = max(0, maxLength - lookbackSize)

        let searchStart = cutRegion.index(cutRegion.startIndex, offsetBy: searchFloor)

        // Try sentence boundary first (. ! ? followed by space or newline)
        if let lastSentenceEnd = cutRegion.range(
            of: #"[.!?]\s"#,
            options: [.regularExpression, .backwards],
            range: searchStart..<cutRegion.endIndex
        ) {
            return String(cutRegion[..<lastSentenceEnd.upperBound])
        }

        // Try word boundary (last whitespace)
        if let lastSpace = cutRegion.range(
            of: #"\s"#,
            options: [.regularExpression, .backwards],
            range: searchStart..<cutRegion.endIndex
        ) {
            return String(cutRegion[..<lastSpace.lowerBound])
        }

        // No boundary found (e.g., single long token) — hard cut is acceptable
        return String(cutRegion)
    }
}
