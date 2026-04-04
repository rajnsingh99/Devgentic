//
//  CognitiveCircuitBreaker.swift
//  Devgentic
//
//  Created for ReAct Executor Modularization.
//

import Foundation
import OSLog

private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "com.devgentic.app", category: "CircuitBreaker")

struct ToolInvocationKey: Hashable, Sendable {
    let toolName: String
    let paramsHash: Int
}

/// A concrete implementation of `CognitiveSafetyGuarding`.
/// Manages friction counters, loop prevention, and hallucination tracking.
/// By returning `CircuitBreakerAction`, it dictates the orchestrator's next move.
struct CognitiveCircuitBreaker: CognitiveSafetyGuarding {

    // MARK: - Limits (configurable via AgentConfig.retryPolicy)

    private let maxConsecutiveAskUser: Int
    private let maxConsecutiveIdle: Int
    private let maxToolRetries: Int
    let maxConsecutiveToolFailures: Int
    let maxRepetitiveActions: Int

    init(maxConsecutiveToolFailures: Int = 3,
         maxRepetitiveActions: Int = 3,
         maxConsecutiveAskUser: Int = 3,
         maxConsecutiveIdle: Int = 5,
         maxToolRetries: Int = 2) {
        self.maxConsecutiveToolFailures = maxConsecutiveToolFailures
        self.maxRepetitiveActions = maxRepetitiveActions
        self.maxConsecutiveAskUser = maxConsecutiveAskUser
        self.maxConsecutiveIdle = maxConsecutiveIdle
        self.maxToolRetries = maxToolRetries
    }
    
    // MARK: - State Tracking
    
    private(set) var consecutiveToolFailures = 0
    private(set) var clarificationFriction = 0
    private(set) var consecutiveAskUserCalls = 0
    private(set) var consecutiveIdleSteps = 0
    private(set) var hallucinatedTools: Set<String> = []
    private(set) var recentInvocations: [ToolInvocationKey: Int] = [:]

    /// Tracks consecutive iterations where every tool call in the iteration
    /// produces the same fingerprint (tool + args hash + observation hash).
    /// Reset whenever a different action pattern is observed.
    private(set) var lastIterationFingerprint: String? = nil
    private(set) var consecutiveIdenticalIterations: Int = 0
    
    // MARK: - Tool Loop Evaluation
    
    mutating func evaluateToolAttempt(toolName: String, paramsHash: Int) -> CircuitBreakerAction {
        let invocationKey = ToolInvocationKey(toolName: toolName, paramsHash: paramsHash)
        recentInvocations[invocationKey, default: 0] += 1
        
        if recentInvocations[invocationKey]! > maxToolRetries {
            logger.warning("🚫 Tool '\(toolName)' retried too many times. Intervening.")
            let msg = "🚫 Tool '\(toolName)' already failed \(maxToolRetries) times with identical parameters. Skipping. Return tool_name: null immediately."
            return .intervene(systemMessage: msg)
        }
        
        return .proceed
    }
    
    mutating func recordToolResult(isSuccess: Bool) -> CircuitBreakerAction {
        if isSuccess {
            consecutiveToolFailures = 0
            return .proceed
        }
        
        consecutiveToolFailures += 1
        
        // Capture local copies to avoid mutating 'self' escaping in OSLog autoclosure
        let currentFailures = consecutiveToolFailures
        let maxFailures = maxConsecutiveToolFailures
        
        if currentFailures >= maxFailures {
            logger.warning("🚫 Consecutive tool failure limit (\(maxFailures)) reached. Aborting.")
            return .abort(reason: "Reached \(maxFailures) consecutive tool failures without recovery.")
        }
        
        let totalAttempts = recentInvocations.values.reduce(0, +)
        let allFailed = recentInvocations.values.allSatisfy { $0 >= 1 } && totalAttempts >= 2 && !hallucinatedTools.isEmpty
        
        if allFailed {
            return .intervene(systemMessage: "All tool attempts have failed. Consider returning tool_name: null to explain what tools are needed.")
        }
        
        return .proceed
    }
    
    // MARK: - Repetitive Action Detection (Gap B)

    /// Evaluates whether the current iteration's observations are identical to previous iterations.
    /// Call this once per iteration AFTER all tool observations are collected.
    ///
    /// Builds a fingerprint from (toolName, argsHash, observationHash) for every tool in the iteration.
    /// If the same fingerprint repeats `maxRepetitiveActions` times consecutively, triggers abort.
    ///
    /// - Parameter observations: The tool observations from the current iteration.
    /// - Returns: `.proceed` to continue, `.abort` if stuck in a degenerate loop.
    mutating func evaluateRepetitiveActions(_ observations: [ToolObservation]) -> CircuitBreakerAction {
        // Build a deterministic fingerprint for this iteration's tool calls + results
        let components = observations
            .sorted(by: { $0.toolName < $1.toolName })
            .map { obs in
                let argsHash = obs.params.hashValue
                let resultHash = obs.output.prefix(200).hashValue
                return "\(obs.toolName)|\(argsHash)|\(resultHash)"
            }
        let fingerprint = components.joined(separator: ";;")

        if fingerprint == lastIterationFingerprint {
            consecutiveIdenticalIterations += 1
        } else {
            lastIterationFingerprint = fingerprint
            consecutiveIdenticalIterations = 1
        }

        let current = consecutiveIdenticalIterations
        let limit = maxRepetitiveActions

        if current >= limit {
            let toolNames = observations.map(\.toolName).joined(separator: ", ")
            logger.warning("🔁 Repetitive action loop detected: [\(toolNames)] repeated \(current) times. Aborting.")
            return .abort(reason: "Detected \(current) consecutive identical tool calls [\(toolNames)] with the same results. Breaking degenerate loop.")
        }

        if current == limit - 1 {
            let toolNames = observations.map(\.toolName).joined(separator: ", ")
            logger.info("⚠️ Repetitive action warning: [\(toolNames)] repeated \(current) times. One more will trigger abort.")
        }

        return .proceed
    }

    // MARK: - Ask User & Idle Step Evaluation
    
    mutating func evaluateAskUser() -> CircuitBreakerAction {
        consecutiveAskUserCalls += 1
        consecutiveIdleSteps += 1
        
        if consecutiveIdleSteps >= maxConsecutiveIdle {
            return .abort(reason: "Max idle steps reached during user clarification.")
        }
        
        if consecutiveAskUserCalls > maxConsecutiveAskUser {
            let msg = "SYSTEM INTERVENTION: You have asked the user \(consecutiveAskUserCalls) questions without making progress. You MUST now return tool_name: null. Do NOT call ask_user."
            return .intervene(systemMessage: msg)
        }
        
        return .proceed
    }
    
    mutating func evaluateMemoryHydration() -> CircuitBreakerAction {
        consecutiveIdleSteps += 1
        if consecutiveIdleSteps >= maxConsecutiveIdle {
            return .abort(reason: "Max idle steps reached during memory hydration.")
        }
        return .proceed
    }
    
    mutating func recordClarificationResponse(isVague: Bool) -> CircuitBreakerAction {
        if isVague {
            clarificationFriction += 1
            if clarificationFriction > 1 {
                return .intervene(systemMessage: "The user's response was vague. You MUST return tool_name: null explaining what specific data you are missing.")
            }
        } else {
            clarificationFriction = 0
        }
        return .proceed
    }
    
    // MARK: - Metrics & Reset
    
    mutating func recordHallucination(_ toolName: String) {
        hallucinatedTools.insert(toolName)
    }
    
    mutating func resetCountersOnSuccess() {
        consecutiveAskUserCalls = 0
        clarificationFriction = 0
        consecutiveIdleSteps = 0
    }
}
