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
    /// - Returns: A formatted string block ready for injection into system instructions.
    static func compile(
        results: [NodeResultEnvelope],
        targetModalities: SupportedModalities = .textOnly,
        budget: Int = maxTotalContextChars
    ) -> String {
        guard !results.isEmpty else { return "" }

        var sections: [String] = []
        let perResultBudget = min(maxCharsPerUpstream, budget / results.count)

        for (index, result) in results.enumerated() {
            let statusLabel: String
            switch result.status {
            case .completed: statusLabel = "Completed"
            case .failed(let msg): statusLabel = "Failed: \(msg)"
            case .canceled: statusLabel = "Canceled"
            case .skipped(let reason): statusLabel = "Skipped: \(reason)"
            }

            let truncatedOutput: String
            if result.output.count > perResultBudget {
                truncatedOutput = String(result.output.prefix(perResultBudget)) + "\n[... output truncated to \(perResultBudget) characters ...]"
            } else {
                truncatedOutput = result.output
            }

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
            return String(preamble.prefix(budget)) + "\n[... context truncated ...]"
        }

        return preamble
    }
}
