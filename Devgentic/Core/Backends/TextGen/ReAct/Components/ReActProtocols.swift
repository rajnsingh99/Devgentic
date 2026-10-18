// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
//
//  ReActProtocols.swift
//  Devgentic
//
//  Created by Raj Singh.
//

import Foundation

// MARK: - Safety & Retry Protocols

/// The resulting action the executor must take based on safety evaluations.
enum CircuitBreakerAction: Equatable, Sendable {
    case proceed
    /// Continue but surface a visible warning; the next identical evaluation triggers an abort.
    /// `uiMessage` is terse text for the `.warning(.circuitBreaker)` stream event shown to the human.
    /// `modelAlert` is directive text injected into the next iteration's working memory so the model can course-correct.
    case proceedWithWarning(uiMessage: String, modelAlert: String)
    case intervene(systemMessage: String)
    case abort(AbortTrigger)
}

// MARK: - Abort Trigger

/// Why the circuit breaker wants to stop, plus everything the executor needs to act on it.
/// `category` and the recovery-policy bypass derive from `kind`, so a new trigger must answer for them.
struct AbortTrigger: Equatable, Sendable {

    enum Kind: Equatable, Sendable {
        /// The same (tool, args, output) fingerprint repeated N times in a row.
        case repetitiveAction
        /// One tool called N times with identical args AND identical output across iterations.
        case staleToolRepetition
        /// N consecutive tool failures without recovery.
        case consecutiveToolFailures
        /// The user declined N consecutive tool calls.
        case consecutiveDenials
    }

    let kind: Kind
    /// Operator- and user-facing text. Says what happened, not what will happen about it.
    let reason: String

    // Why: a generic "tools are failing repeatedly" alert made the model misread a loop of successful calls as tool failures.
    /// What the model is told when the run continues; carried per trigger rather than as one shared sentence.
    let modelNarrative: String

    /// The error category for this trigger, derived from `kind`.
    var category: AgentErrorCategory {
        switch kind {
        case .repetitiveAction:      return .cbRepetitiveAction
        case .staleToolRepetition:   return .cbToolRetryLimit
        case .consecutiveToolFailures: return .cbConsecutiveFail
        case .consecutiveDenials:    return .cbAskUserLimit
        }
    }

    /// The user-facing warning when the profile's tolerance downgrades this trigger and the run continues.
    /// Cuts the abort-only "Breaking … loop." suffix of `reason`, which `AgentFailureReason.classify` keys off.
    var continuingWarning: String {
        let happened = reason.components(separatedBy: " Breaking ").first ?? reason
        return "\(category.displayName): \(happened) The run continues — press Stop if it looks stuck."
    }

    /// Identifies "the same loop" across iterations: the reason with its counts removed, so a
    /// streak that grows from 3 to 4 to 5 is announced once.
    var announcementKey: String {
        "\(kind)|" + reason.filter { !$0.isNumber }
    }

    var honoursToolFailurePolicy: Bool {
        switch kind {
        case .repetitiveAction, .staleToolRepetition,
             .consecutiveToolFailures, .consecutiveDenials:
            return true
        }
    }
}

/// Evaluates execution state to prevent infinite loops and hallucination spirals.
/// Every requirement has a live executor call site.
protocol CognitiveSafetyGuarding: Sendable {
    var hallucinatedTools: Set<String> { get }

    /// Records the result of a tool execution and checks for consecutive failure limits.
    mutating func recordToolResult(isSuccess: Bool) -> CircuitBreakerAction

    /// Records a user-denied tool permission, a binding "do not retry" constraint; aborts after 2 consecutive denials
    /// (3 for general failures). The breaker is the enforcement, as models often ignore the scratchpad directive.
    mutating func recordDenial() -> CircuitBreakerAction

    mutating func recordHallucination(_ toolName: String)
}

/// The resulting action the executor must take when encountering an LLM error.
enum RetryAction: Equatable, Sendable {
    case throttle(seconds: TimeInterval, message: String)
    /// A transient failure a bounded wait may clear: retry after `delaySeconds`.
    /// Two producers with separate budgets: transport (5xx, timeout) via `TransportResiliencePolicy.maxTransientRetries`,
    /// and MLX model-slot contention via `LLMRetryStrategy.maxModelSlotRetries`; the strategy returns `.fatal` when spent.
    case networkRetry(message: String, delaySeconds: TimeInterval)
    case parseRetry(systemAlert: String, attemptCount: Int, maxAttempts: Int)
    /// A deterministic, non-retryable failure (auth, bad model id, context overflow, malformed request, exhausted retries).
    /// The executor renders an error card with the honest reason and classifies telemetry with `category`; never retried.
    case fatal(reason: String, category: AgentErrorCategory)
    /// The local model was unloaded (e.g., idle timer fired during HITL suspension).
    /// The executor should attempt to reload the model and retry the iteration.
    case modelReload(message: String)
    /// Soft abort: the reason is emitted as message content so the user still sees partial work.
    /// Used for iteration exhaustion and circuit-breaker paths.
    case abort(reason: String)
    /// Hard capability failure: the model cannot satisfy the request at all (e.g. a reasoning-only model rejecting `tools`).
    /// Emitted as an `.error` stream event so the UI shows a distinct error card; no retries.
    case capabilityFailure(reason: String)
}

/// Handles LLM rate limits (HTTP 429) and network/JSON retry logic.
protocol LLMRetryHandling: Sendable {
    mutating func handleError(_ error: Error) -> RetryAction
    mutating func resetParseFailures()
}

// MARK: - Execution and Evaluation Protocols

/// Defines the outcome of a termination evaluation check.
enum TerminationStatus: Equatable, Sendable {
    case proceed
    case completed(finalThought: String)
    case maxIterationsReached
    /// Parsing or validation failed and the model needs a targeted corrective alert in the next iteration.
    /// Carries the typed reason so the executor builds a reason-specific alert; `reasoning` is the raw reasoning text.
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
