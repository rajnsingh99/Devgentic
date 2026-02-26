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
    
    // MARK: - Limits
    // Converted to static to prevent escaping autoclosure errors during logging
    private static let maxConsecutiveAskUser = 3
    private static let maxConsecutiveIdle = 5
    private static let maxToolRetries = 2
    private static let maxConsecutiveToolFailures = 3
    
    // MARK: - State Tracking
    
    private(set) var consecutiveToolFailures = 0
    private(set) var clarificationFriction = 0
    private(set) var consecutiveAskUserCalls = 0
    private(set) var consecutiveIdleSteps = 0
    private(set) var hallucinatedTools: Set<String> = []
    private(set) var recentInvocations: [ToolInvocationKey: Int] = [:]
    
    // MARK: - Tool Loop Evaluation
    
    mutating func evaluateToolAttempt(toolName: String, paramsHash: Int) -> CircuitBreakerAction {
        let invocationKey = ToolInvocationKey(toolName: toolName, paramsHash: paramsHash)
        recentInvocations[invocationKey, default: 0] += 1
        
        if recentInvocations[invocationKey]! > Self.maxToolRetries {
            logger.warning("🚫 Tool '\(toolName)' retried too many times. Intervening.")
            let msg = "🚫 Tool '\(toolName)' already failed \(Self.maxToolRetries) times with identical parameters. Skipping. Return tool_name: null immediately."
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
        let maxFailures = Self.maxConsecutiveToolFailures
        
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
    
    // MARK: - Ask User & Idle Step Evaluation
    
    mutating func evaluateAskUser() -> CircuitBreakerAction {
        consecutiveAskUserCalls += 1
        consecutiveIdleSteps += 1
        
        if consecutiveIdleSteps >= Self.maxConsecutiveIdle {
            return .abort(reason: "Max idle steps reached during user clarification.")
        }
        
        if consecutiveAskUserCalls > Self.maxConsecutiveAskUser {
            let msg = "SYSTEM INTERVENTION: You have asked the user \(consecutiveAskUserCalls) questions without making progress. You MUST now return tool_name: null. Do NOT call ask_user."
            return .intervene(systemMessage: msg)
        }
        
        return .proceed
    }
    
    mutating func evaluateMemoryHydration() -> CircuitBreakerAction {
        consecutiveIdleSteps += 1
        if consecutiveIdleSteps >= Self.maxConsecutiveIdle {
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
