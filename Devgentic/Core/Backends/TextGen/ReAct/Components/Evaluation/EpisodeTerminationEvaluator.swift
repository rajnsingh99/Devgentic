//
//  EpisodeTerminationEvaluator.swift
//  Devgentic
//
//  Created for ReAct Executor Modularization.
//

import Foundation
import OSLog

private let logger = DGLogger(category: "TerminationEvaluator")

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
        
        // Condition 2: Parse pipeline exhausted all stages without extracting tool calls.
        // The model likely intended to call tools but produced unparseable output.
        // Route to .suspectedFormatFailure so the executor injects a corrective alert
        // and retries, rather than silently terminating with a confident response.
        if step.toolCalls.isEmpty && step.parseExhausted {
            logger.warning("🔄 Parse pipeline exhausted — not treating as genuine completion.")
            return .suspectedFormatFailure(reasoning: step.reasoning)
        }

        // Condition 3: Agent signaled task completion by returning a null/empty tool
        if step.toolCalls.isEmpty {
            logger.info("🛑 Null-Termination Triggered. Agent signaled task completion.")
            return .completed(finalThought: step.reasoning)
        }
        
        // Condition 3: Proceed with the loop
        return .proceed
    }
}
