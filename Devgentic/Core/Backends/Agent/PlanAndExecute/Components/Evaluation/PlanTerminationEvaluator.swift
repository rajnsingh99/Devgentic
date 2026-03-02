//
//  PlanTerminationEvaluator.swift
//  Devgentic
//
//  Created for Plan & Execute Architecture.
//  Evaluates whether the current plan step has reached completion.
//

import Foundation

/// Concrete implementation of `PlanTerminationEvaluating`.
/// Analyzes the LLM's cognitive step to determine if the current plan step is done.
struct PlanTerminationEvaluator: PlanTerminationEvaluating {

    func evaluateStep(
        step: LeanCognitiveStep,
        currentStepIndex: Int,
        totalSteps: Int,
        iterationInStep: Int,
        maxIterationsPerStep: Int
    ) -> PlanTerminationStatus {

        // Check if we've exceeded the per-step iteration budget
        if iterationInStep >= maxIterationsPerStep {
            return .replanRequired(
                failedStep: currentStepIndex,
                reason: "Step \(currentStepIndex) exceeded maximum iterations (\(maxIterationsPerStep)) without completion."
            )
        }

        // If the tool_name is null/empty/"null"/"none", the LLM signals step completion
        let toolName = step.toolName?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? ""
        if toolName.isEmpty || toolName == "null" || toolName == "none" {
            let outcome = step.content.isEmpty ? "Step completed." : step.content
            return .stepCompleted(outcome: outcome)
        }

        // Otherwise, the step has more work to do
        return .proceed
    }
}
