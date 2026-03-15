//
//  ReActProtocols.swift
//  Devgentic
//
//  Created for ReAct Executor Modularization.
//

import Foundation

// MARK: - Phase 3: Safety & Retry Protocols

/// The resulting action the executor must take based on safety evaluations.
enum CircuitBreakerAction: Equatable, Sendable {
    case proceed
    case intervene(systemMessage: String)
    case abort(reason: String)
}

/// Evaluates execution state to prevent infinite loops, hallucination spirals,
/// and handles friction in user clarification requests.
protocol CognitiveSafetyGuarding: Sendable {
    var hallucinatedTools: Set<String> { get }
    
    /// Evaluates if a tool has been retried too many times with the exact same parameters.
    mutating func evaluateToolAttempt(toolName: String, paramsHash: Int) -> CircuitBreakerAction
    
    /// Records the result of a tool execution and checks for consecutive failure limits.
    mutating func recordToolResult(isSuccess: Bool) -> CircuitBreakerAction
    
    /// Evaluates the loop state when the agent asks for user clarification (prevents endless questioning).
    mutating func evaluateAskUser() -> CircuitBreakerAction
    
    /// Evaluates the loop state when the agent interacts with memory (prevents endless stalling).
    mutating func evaluateMemoryHydration() -> CircuitBreakerAction
    
    /// Checks if the user's response was too vague repeatedly.
    mutating func recordClarificationResponse(isVague: Bool) -> CircuitBreakerAction
    
    mutating func recordHallucination(_ toolName: String)
    mutating func resetCountersOnSuccess()
}

/// The resulting action the executor must take when encountering an LLM error.
enum RetryAction: Equatable, Sendable {
    case throttle(seconds: TimeInterval, message: String)
    case networkRetry(message: String)
    case parseRetry(systemAlert: String, attemptCount: Int, maxAttempts: Int)
    case abort(reason: String)
}

/// Handles LLM rate limits (HTTP 429) and network/JSON retry logic.
protocol LLMRetryHandling: Sendable {
    mutating func handleError(_ error: Error) -> RetryAction
    mutating func resetParseFailures()
}

// MARK: - Phase 4: Execution and Evaluation Protocols

/// Defines the outcome of a termination evaluation check.
enum TerminationStatus: Equatable, Sendable {
    case proceed
    case completed(finalThought: String)
    case maxIterationsReached
    /// The LLM returned prose describing tool usage intent but failed to produce structured tool calls.
    /// The executor should inject a corrective system alert and retry.
    case suspectedFormatFailure(reasoning: String)
}

/// Analyzes cognitive steps to determine if the execution loop has reached a natural conclusion.
protocol TerminationEvaluating: Sendable {
    func evaluate(step: ModernCognitiveStep, currentIteration: Int, maxIterations: Int) -> TerminationStatus
}

/// Defines the result of an attempted tool dispatch, including human-in-the-loop interactions.
enum ToolDispatchOutcome: Sendable {
    case executed(result: ToolExecutionResult, paramsString: String)
    case requiresConfirmation(paramsString: String)
    case userDenied(result: ToolExecutionResult, paramsString: String)
}

/// Coordinates the actual execution of tools, parameter serialization, metric tracking,
/// and handles the interaction with human-in-the-loop (HITL) approval services.
protocol ToolDispatching: Sendable {
    /// Serializes parameters and initiates the Human-in-the-Loop check if required.
    func prepareDispatch(
        toolName: String,
        arguments: [String: JSONValue],
        availableTools: [AgentTool]
    ) -> ToolDispatchOutcome

    /// Bypasses or completes the HITL check and actually executes the tool payload.
    func executePreparedTool(
        toolName: String,
        arguments: [String: JSONValue],
        availableTools: [AgentTool],
        parentContext: TraceContext
    ) async -> ToolExecutionResult
}
