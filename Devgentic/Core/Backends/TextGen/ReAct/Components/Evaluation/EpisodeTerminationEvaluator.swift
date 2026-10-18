// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
//
//  EpisodeTerminationEvaluator.swift
//  Devgentic
//
//  Created by Raj Singh.
//

import Foundation
import OSLog

private let logger = DGLogger(category: "TerminationEvaluator")

/// A concrete implementation of `TerminationEvaluating`.
/// Uses the step's typed `parseOutcome` as the primary decision input —
/// falls back to the iteration budget as the global guardrail.
struct EpisodeTerminationEvaluator: TerminationEvaluating {

    func evaluate(step: ModernCognitiveStep, currentIteration: Int, maxIterations: Int) -> TerminationStatus {

        // The answer is read before the step budget, so a model that answers on its last allowed step keeps
        // its answer.
        let isLastStep = currentIteration >= maxIterations

        // Primary decision: pattern-match the step's typed parse outcome.
        switch step.parseOutcome {

        case .success:
            // Tool calls were extracted and validated: continue the loop.
            // On the last step only `final_answer` may run; any other call's result could never be read.
            if isLastStep {
                if step.toolCalls.contains(where: { $0.name == "final_answer" }) { return .proceed }
                logger.warning("🛑 Max iterations (\(maxIterations)) reached with \(step.toolCalls.count) tool call(s) pending. CONSEQUENCE: they are NOT run — no step remains to read their results.")
                return .maxIterationsReached
            }
            return .proceed

        case .genuineCompletion:
            // The model produced no tool calls: exit cleanly with its reasoning as the final thought.
            logger.info("🛑 Genuine completion. Agent signaled task completion.")
            return .completed(finalThought: step.reasoning)

        case .failed where isLastStep:
            logger.warning("🛑 Max iterations (\(maxIterations)) reached on an unparseable step. Forcing termination.")
            return .maxIterationsReached

        case .failed(let reason):
            // Parse/validation failure: inject a typed corrective alert and retry.
            // The executor builds the alert via `ParseFailureReason.modelCorrectiveAlert(availableToolNames:)`.
            logger.warning("🔄 Parse outcome failed: \(String(describing: reason)). Retrying with corrective alert.")
            return .suspectedFormatFailure(reason: reason, reasoning: step.reasoning)
        }
    }
}
