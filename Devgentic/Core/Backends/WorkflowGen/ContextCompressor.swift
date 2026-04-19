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
    /// knowing it's in a workflow. Only `.completed` results are included.
    ///
    /// Output format:
    /// - Single upstream: raw text (no wrapper, no separator)
    /// - Multiple upstreams: text blocks separated by `\n\n---\n\n`
    ///
    /// - Parameters:
    ///   - results: Upstream `NodeResultEnvelope` values.
    ///   - budget: Maximum total characters (defaults to `maxTotalContextChars`).
    ///   - perNodeBudget: Maximum characters per upstream (defaults to `maxCharsPerUpstream`).
    /// - Returns: Clean text ready for injection into `<input>` tag. Empty string if no completed results.
    static func compileForWorkflow(
        results: [NodeResultEnvelope],
        budget: Int = maxTotalContextChars,
        perNodeBudget: Int = maxCharsPerUpstream
    ) -> String {
        // Filter to only completed results — failed/skipped are handled by the executor's dependency logic
        let completedResults = results.filter {
            if case .completed = $0.status { return true }
            return false
        }

        guard !completedResults.isEmpty else {
            compressorLogger.info("compileForWorkflow: no completed upstream results, returning empty")
            return ""
        }

        let perResultBudget = min(perNodeBudget, budget / completedResults.count)
        compressorLogger.info("compileForWorkflow: \(completedResults.count)/\(results.count) completed results, totalBudget=\(budget), perResultBudget=\(perResultBudget)")

        var sections: [String] = []

        for (index, result) in completedResults.enumerated() {
            let originalSize = result.output.count
            let truncatedOutput: String

            if originalSize > perResultBudget {
                truncatedOutput = truncateAtBoundary(result.output, maxLength: perResultBudget)
                compressorLogger.info("  [\(index)] '\(result.profileName)': \(originalSize) chars → truncated to ~\(perResultBudget)")
            } else {
                truncatedOutput = result.output
                compressorLogger.info("  [\(index)] '\(result.profileName)': \(originalSize) chars (within budget)")
            }
            compressorLogger.debug("  [\(index)] '\(result.profileName)' preview: \(String(result.output.prefix(200)))")

            sections.append(truncatedOutput)
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
