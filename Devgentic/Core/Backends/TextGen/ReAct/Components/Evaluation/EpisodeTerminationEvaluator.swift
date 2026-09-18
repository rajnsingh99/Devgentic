// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
//
//  EpisodeTerminationEvaluator.swift
//  Devgentic
//
//  Pattern-matches a ModernCognitiveStep's `parseOutcome` to decide whether
//  the executor should continue the loop, exit cleanly, or inject a typed
//  corrective alert and retry.
//

import Foundation
import OSLog

private let logger = DGLogger(category: "TerminationEvaluator")

/// A concrete implementation of `TerminationEvaluating`.
/// Uses the step's typed `parseOutcome` as the primary decision input —
/// falls back to the iteration budget as the global guardrail.
struct EpisodeTerminationEvaluator: TerminationEvaluating {

    func evaluate(step: ModernCognitiveStep, currentIteration: Int, maxIterations: Int) -> TerminationStatus {

        // Hard ceiling — iteration budget exhausted regardless of outcome.
        if currentIteration >= maxIterations {
            logger.warning("🛑 Max iterations (\(maxIterations)) reached. Forcing termination.")
            return .maxIterationsReached
        }

        // Primary decision: pattern-match the step's typed parse outcome.
        switch step.parseOutcome {

        case .success:
            // Tool calls were extracted and validated — continue the loop.
            return .proceed

        case .genuineCompletion:
            // Model intentionally produced no tool calls. Exit cleanly with
            // the model's reasoning as the final thought.
            logger.info("🛑 Genuine completion. Agent signaled task completion.")
            return .completed(finalThought: step.reasoning)

        case .failed(let reason):
            // Parse/validation failure — inject a typed corrective alert and retry.
            // The executor builds the alert string from the reason using
            // `ParseFailureReason.modelCorrectiveAlert(availableToolNames:)`.
            logger.warning("🔄 Parse outcome failed: \(String(describing: reason)). Retrying with corrective alert.")
            return .suspectedFormatFailure(reason: reason, reasoning: step.reasoning)
        }
    }
}
