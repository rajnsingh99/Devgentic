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
    /// Continue execution but surface a visible warning — the next identical evaluation
    /// will trigger an abort. Carries TWO messages:
    ///   - `uiMessage`: terse text for the `.warning(.circuitBreaker)` stream event
    ///     shown to the human (chip/toast).
    ///   - `modelAlert`: directive text injected into the next iteration's working
    ///     memory so the model itself can course-correct before the hard abort.
    /// This split exists because the two audiences need different detail levels —
    /// humans want a short signal, models need explicit escape hatches.
    case proceedWithWarning(uiMessage: String, modelAlert: String)
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

    /// Records a user-denied tool permission specifically. User denials produce a
    /// binding "do not retry" constraint — we abort more aggressively (2 consecutive)
    /// than general tool failures (3 consecutive). Models (especially Q4-quantized)
    /// reliably ignore the "do not retry this exact action" directive in scratchpad,
    /// so the circuit breaker is the actual enforcement.
    mutating func recordDenial() -> CircuitBreakerAction

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
    /// The local model was unloaded (e.g., idle timer fired during HITL suspension).
    /// The executor should attempt to reload the model and retry the iteration.
    case modelReload(message: String)
    /// Soft abort with a best-effort synthesized answer. The executor emits the
    /// reason as message content so the user sees *something* — used for
    /// iteration-exhaustion and circuit-breaker paths that still want to show
    /// partial work.
    case abort(reason: String)
    /// Hard capability failure — the model cannot satisfy the request at all
    /// (e.g. reasoning-only model rejecting `tools` parameter). The executor
    /// emits this as an `.error` stream event so the UI renders a distinct
    /// error card instead of plain message content. No retries attempted.
    case capabilityFailure(reason: String)
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
    /// Parsing or validation failed and the model needs a targeted corrective alert
    /// to course-correct in the next iteration. Carries the typed reason so the
    /// executor can build a reason-specific alert instead of a generic "invalid JSON"
    /// string. `reasoning` is the model's raw reasoning text (what little was extractable).
    case suspectedFormatFailure(reason: ParseFailureReason, reasoning: String)
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
