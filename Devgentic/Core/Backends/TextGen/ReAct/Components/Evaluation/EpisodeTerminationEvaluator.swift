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

        // ⚠️ THE ANSWER IS READ BEFORE THE BUDGET (Timeout inventory D-19). The ceiling used to be
        // checked FIRST, "regardless of outcome": a model that answered on its last allowed step had
        // that answer replaced by the exhaustion template, and the user was told the agent ran out
        // of steps when it had finished.
        let isLastStep = currentIteration >= maxIterations

        // Primary decision: pattern-match the step's typed parse outcome.
        switch step.parseOutcome {

        case .success:
            // Tool calls were extracted and validated — continue the loop.
            // On the last step only `final_answer` may run: any other call would execute and its
            // result could never be read (no step is left to read it), so the budget ends here.
            if isLastStep {
                if step.toolCalls.contains(where: { $0.name == "final_answer" }) { return .proceed }
                logger.warning("🛑 Max iterations (\(maxIterations)) reached with \(step.toolCalls.count) tool call(s) pending. CONSEQUENCE: they are NOT run — no step remains to read their results.")
                return .maxIterationsReached
            }
            return .proceed

        case .genuineCompletion:
            // Model intentionally produced no tool calls. Exit cleanly with
            // the model's reasoning as the final thought.
            logger.info("🛑 Genuine completion. Agent signaled task completion.")
            return .completed(finalThought: step.reasoning)

        case .failed where isLastStep:
            logger.warning("🛑 Max iterations (\(maxIterations)) reached on an unparseable step. Forcing termination.")
            return .maxIterationsReached

        case .failed(let reason):
            // Parse/validation failure — inject a typed corrective alert and retry.
            // The executor builds the alert string from the reason using
            // `ParseFailureReason.modelCorrectiveAlert(availableToolNames:)`.
            logger.warning("🔄 Parse outcome failed: \(String(describing: reason)). Retrying with corrective alert.")
            return .suspectedFormatFailure(reason: reason, reasoning: step.reasoning)
        }
    }
}
