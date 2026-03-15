//
//  EpisodeTerminationEvaluator.swift
//  Devgentic
//
//  Created for ReAct Executor Modularization.
//

import Foundation
import OSLog

private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "com.devgentic.app", category: "TerminationEvaluator")

/// A concrete implementation of `TerminationEvaluating`.
/// Analyzes cognitive steps to determine if the agent has reached a valid exit condition
/// or if it has exhausted its iteration budget.
struct EpisodeTerminationEvaluator: TerminationEvaluating {
    
    func evaluate(step: ModernCognitiveStep, currentIteration: Int, maxIterations: Int) -> TerminationStatus {
        
        // Condition 1: Exceeded Iteration Budget
        if currentIteration >= maxIterations {
            logger.warning("🛑 Max iterations (\(maxIterations)) reached. Forcing termination.")
            return .maxIterationsReached
        }
        
        // Condition 2: Agent signaled task completion by returning a null/empty tool
        if step.toolCalls.isEmpty {
            logger.info("🛑 Null-Termination Triggered. Agent signaled task completion.")
            return .completed(finalThought: step.reasoning)
        }
        
        // Condition 3: Proceed with the loop
        return .proceed
    }
}
