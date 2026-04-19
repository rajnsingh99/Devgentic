//
//  CognitiveCircuitBreaker.swift
//  Devgentic
//
//  Created for ReAct Executor Modularization.
//

import Foundation
import OSLog

private let logger = DGLogger(category: "CircuitBreaker")

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

    /// Tracks per-tool invocation frequency across ALL iterations (regardless of
    /// what other tools ran in the same iteration). Catches models that evade the
    /// iteration-level fingerprint by alternating tool combinations while
    /// repeating the same core action (e.g., read_file alone then read_file + list_directory).
    /// Key: "toolName|argsHash|outputSignature", Value: total count across all iterations.
    private(set) var globalToolFrequency: [String: Int] = [:]
    // G3: matches the iteration-level "three strikes" philosophy. A tool invoked
    // 3× with identical args + output across a session is stuck — no reason to
    // wait for 5 (which on a 25s/iter local model = ~50s of wasted work).
    private let maxGlobalToolRepetitions: Int = 3
    
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
        // Build a deterministic fingerprint for this iteration's tool calls + results.
        //
        // G3: Fixes to the fingerprint accuracy:
        //   Fix 1 — Hash the FULL normalized output, not just the first 200 chars.
        //           The old prefix sampled ≤2.5% of an 8KB tool output; a single
        //           volatile token near the start (timestamp in a shell stdout, file
        //           count in a tree header) would evade detection, and body-only
        //           drift would hash-collide as identical. String.hashValue is O(n)
        //           anyway, so hashing the full payload costs microseconds.
        //   Fix 2 — Compound signal: "length:hash". Two outputs of different
        //           lengths can never collide at this level regardless of hash.
        //
        // Normalization handles CRLF→LF and per-line trailing whitespace so that
        // meaningless editor/tool artifacts don't produce false "different" hashes.
        // Leading whitespace is preserved — code indentation still discriminates.
        let components = observations
            .sorted(by: { $0.toolName < $1.toolName })
            .map { obs in
                let argsHash = obs.params.hashValue
                let normalized = Self.normalizeForHashing(obs.output)
                let resultSignature = "\(normalized.count):\(normalized.hashValue)"
                return "\(obs.toolName)|\(argsHash)|\(resultSignature)"
            }
        let fingerprint = components.joined(separator: ";;")

        // --- Check 1: Iteration-level fingerprint (existing) ---
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

            // G2: Dual-channel warning.
            //   UI message  = terse chip/toast for the human.
            //   Model alert = directive injected into the next iteration's working
            //                 memory so the model sees the warning BEFORE it calls
            //                 the same tool a third time and gets killed.
            let uiMessage = "Repetitive tool pattern detected: [\(toolNames)]. One more identical call will abort this run."

            let modelAlert = """
            ⚠️ REPETITION DETECTED — SYSTEM INTERVENTION

            Tool(s) [\(toolNames)] just ran with identical arguments and produced identical output to the previous iteration. Running this exact call a third time will ABORT this session.

            You MUST choose one of these three paths now:

            1. SWITCH TOOLS. The previous output is already in your working memory above — re-reading it will not help. Use a DIFFERENT tool to make progress.

            2. FINALIZE. If you already have enough information to answer the user's request, call `final_answer(answer: "...")` with your response. Do not call any other tool in the same step.

            3. ASK. If you are genuinely blocked on something only the user can clarify, call `ask_user(question: "...")`. Do not use `final_answer` to ask questions.

            Do NOT call [\(toolNames)] with the same arguments again.
            """

            return .proceedWithWarning(uiMessage: uiMessage, modelAlert: modelAlert)
        }

        // --- Check 2: Per-tool global frequency (catches alternating combos) ---
        // Tracks individual tool+args+output across ALL iterations. A model that
        // alternates [read_file] and [read_file, list_directory] evades the
        // iteration fingerprint but each read_file call is still identical.
        for key in components {
            globalToolFrequency[key, default: 0] += 1
            let count = globalToolFrequency[key]!
            if count >= maxGlobalToolRepetitions {
                let toolName = key.components(separatedBy: "|").first ?? "unknown"
                logger.warning("🔁 Global repetition limit: '\(toolName)' executed \(count) times with identical args+output. Aborting.")
                return .abort(reason: "Tool '\(toolName)' has been called \(count) times with the same parameters and results across multiple iterations. Breaking stale loop.")
            }
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

    // MARK: - Output Normalization (G3)

    /// Normalizes tool output for deterministic hashing. Collapses CRLF → LF
    /// and strips trailing whitespace on each line. Leaves leading whitespace
    /// untouched so code indentation still discriminates different files.
    ///
    /// Why these specific operations: tool outputs regularly differ by pure
    /// artifact (shell `\r\n`, trailing spaces from a formatter, a blank line
    /// at the end) while being semantically identical. Collapsing these
    /// artifacts means identical runs hash identically, so repetition
    /// detection fires when it should. We do NOT strip timestamps / UUIDs —
    /// that gets fragile fast and risks false equals on legitimately different
    /// outputs.
    private static func normalizeForHashing(_ output: String) -> String {
        let unix = output
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")

        let trimmedLines = unix.split(separator: "\n", omittingEmptySubsequences: false).map { line -> String in
            var s = String(line)
            while let last = s.last, last.isWhitespace {
                s.removeLast()
            }
            return s
        }

        return trimmedLines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
