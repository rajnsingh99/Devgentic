//
//  PlanTerminationEvaluator.swift
//  Devgentic
//
//  Evaluates whether a subtask's inner execution loop should terminate.
//

import Foundation

struct PlanTerminationEvaluator: TerminationEvaluating {

    func evaluate(step: ModernCognitiveStep, currentIteration: Int, maxIterations: Int) -> TerminationStatus {
        if currentIteration >= maxIterations {
            return .maxIterationsReached
        }
        if step.toolCalls.isEmpty {
            return .completed(finalThought: step.reasoning)
        }
        return .proceed
    }
}
