// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
//
//  CognitiveCircuitBreaker.swift
//  Devgentic
//
//  Created by Raj Singh.
//

import Foundation
import OSLog

private let logger = DGLogger(category: "CircuitBreaker")

/// A concrete implementation of `CognitiveSafetyGuarding`.
/// Manages friction counters, loop prevention, and hallucination tracking.
/// By returning `CircuitBreakerAction`, it dictates the orchestrator's next move.
struct CognitiveCircuitBreaker: CognitiveSafetyGuarding {

    // MARK: - Limits (configurable via AgentConfig resilience overrides)

    let maxConsecutiveToolFailures: Int
    let maxRepetitiveActions: Int

    /// A dedicated counter with a tighter cap for user denials: a denial is a hard "do not retry" constraint that small
    /// models ignore, so this catches denial-retry loops before they waste iterations on rejected HITL round-trips.
    /// Clarification (ask_user) loops are not counter-governed: identical re-asks are answered from `RunInteractionMemory`.
    private let maxConsecutiveDenials: Int

    /// Whether a detected loop actually ends this run: true only when the profile's `ErrorRecovery.onToolFailure`
    /// is `.abort`. Code (`.fallbackPrompt`) and `.skipAndContinue` only warn and nudge. Decides the
    /// pre-warning's wording only.
    let repetitionEndsRun: Bool

    init(maxConsecutiveToolFailures: Int = 3,
         maxRepetitiveActions: Int = 3,
         maxConsecutiveDenials: Int = 2,
         repetitionEndsRun: Bool = true) {
        self.maxConsecutiveToolFailures = maxConsecutiveToolFailures
        self.maxRepetitiveActions = maxRepetitiveActions
        self.maxConsecutiveDenials = maxConsecutiveDenials
        self.repetitionEndsRun = repetitionEndsRun
    }

    /// What the next identical call leads to, for the user and for the model.
    private var nextRepeatConsequence: (ui: String, model: String) {
        repetitionEndsRun
            ? ("will abort this run", "will ABORT this session")
            : ("will be flagged as a loop (the run continues)",
               "will be flagged as a stuck loop and reported to the user")
    }

    // MARK: - State Tracking

    private(set) var consecutiveToolFailures = 0
    private(set) var consecutiveDenials = 0
    private(set) var hallucinatedTools: Set<String> = []

    /// Tracks consecutive iterations where every tool call in the iteration
    /// produces the same fingerprint (tool + args hash + observation hash).
    /// Reset whenever a different action pattern is observed.
    private(set) var lastIterationFingerprint: String? = nil
    private(set) var consecutiveIdenticalIterations: Int = 0

    /// Tracks per-tool invocation frequency across all iterations, regardless of what else ran in the iteration.
    /// Catches models that alternate tool combinations to evade the iteration-level fingerprint. Key:
    /// "toolName|argsHash|outputSignature"; value: total count.
    private(set) var globalToolFrequency: [String: Int] = [:]
    /// The global per-tool cap shares the repetition-tolerance knob (`maxRepetitiveActions`, configurable via
    /// `ResilienceOverrides`): both checks catch the same phenomenon at different granularities, so one setting governs both.
    private var maxGlobalToolRepetitions: Int { maxRepetitiveActions }
    
    // MARK: - Tool Loop Evaluation

    mutating func recordToolResult(isSuccess: Bool) -> CircuitBreakerAction {
        if isSuccess {
            consecutiveToolFailures = 0
            consecutiveDenials = 0
            return .proceed
        }

        consecutiveToolFailures += 1

        // Capture local copies to avoid mutating 'self' escaping in OSLog autoclosure
        let currentFailures = consecutiveToolFailures
        let maxFailures = maxConsecutiveToolFailures

        if currentFailures >= maxFailures {
            logger.warning("🚫 Consecutive tool failure limit (\(maxFailures)) reached — requesting abort. CONSEQUENCE: whether the run actually stops is the executor's call; `ErrorRecovery.onToolFailure` may downgrade this to a nudge.")
            return .abort(AbortTrigger(
                kind: .consecutiveToolFailures,
                reason: "Reached \(maxFailures) consecutive tool failures without recovery.",
                modelNarrative: "\(maxFailures) tool calls in a row have failed. Something about how you are calling them is wrong — change the arguments or the approach, or answer with what you already have."
            ))
        }

        return .proceed
    }

    /// Records a user-denied tool call. Denials get a tighter 2-strike cap than general failures (3-strike)
    /// because the user explicitly rejected the action. Each denial also counts toward the general failure
    /// counter, so mixed patterns still trip it.
    mutating func recordDenial() -> CircuitBreakerAction {
        consecutiveDenials += 1
        consecutiveToolFailures += 1

        let currentDenials = consecutiveDenials
        let denialLimit = maxConsecutiveDenials

        if currentDenials >= denialLimit {
            logger.warning("🚫 Consecutive user-denial limit (\(denialLimit)) reached — requesting abort. CONSEQUENCE: the executor decides; today the profile's tolerance can still downgrade this to a nudge, which is why `AbortTrigger.honoursToolFailurePolicy` names this the likeliest kind to change.")
            return .abort(AbortTrigger(
                kind: .consecutiveDenials,
                reason: "User denied \(currentDenials) consecutive tool calls. Halting to respect the denial constraint.",
                modelNarrative: "The user has declined \(currentDenials) tool calls in a row. They are not failures — the user does not want these actions taken. Stop proposing them and either answer with what you have or ask what they would prefer."
            ))
        }

        // Fall through to the general failure check — mixed denial+failure patterns
        // still hit the 3-strike limit from recordToolResult's perspective.
        if consecutiveToolFailures >= maxConsecutiveToolFailures {
            logger.warning("🚫 Consecutive tool failure limit (\(maxConsecutiveToolFailures)) reached including denials — requesting abort. CONSEQUENCE: the executor decides; the profile's tolerance may downgrade it.")
            return .abort(AbortTrigger(
                kind: .consecutiveToolFailures,
                reason: "Reached \(maxConsecutiveToolFailures) consecutive tool failures without recovery.",
                modelNarrative: "\(maxConsecutiveToolFailures) tool calls in a row have failed or been declined. Change the arguments or the approach, or answer with what you already have."
            ))
        }

        return .proceed
    }
    
    // MARK: - Repetitive Action Detection (Gap B)

    /// Evaluates whether this iteration's observations repeat earlier ones; call once per iteration. Aborts when
    /// the (toolName, argsHash, observationHash) fingerprint repeats `maxRepetitiveActions` times in a row.
    /// - Returns: `.proceed` or `.abort` (stuck in a loop).
    mutating func evaluateRepetitiveActions(_ observations: [ToolObservation]) -> CircuitBreakerAction {
        // Deterministic fingerprint of the iteration's calls and results: the full normalized output is hashed as
        // "length:hash" so a volatile token cannot evade detection; CRLF and trailing whitespace are folded.
        let components = Self.iterationComponents(observations)
        let fingerprint = components.joined(separator: ";;")

        // Increment the global per-tool tally unconditionally before any early return, so a warning iteration's count is never
        // skipped and a model returning to a warned pattern cannot escape the global cap.
        for key in components {
            globalToolFrequency[key, default: 0] += 1
        }

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
            logger.warning("🔁 Repetitive action loop detected: [\(toolNames)] repeated \(current) times — requesting abort. CONSEQUENCE: the executor decides; with the default tolerance the run CONTINUES with a corrective alert rather than stopping.")
            return .abort(AbortTrigger(
                kind: .repetitiveAction,
                reason: "Detected \(current) consecutive identical tool calls [\(toolNames)] with the same results. Breaking degenerate loop.",
                // Says SUCCEEDED explicitly: these calls worked and the loop is the problem; telling the model its tools failed
                // made one misread its own output as truncated.
                modelNarrative: "You called [\(toolNames)] \(current) times in a row with identical arguments and received identical results each time. Those calls SUCCEEDED — the results you already have are complete and correct. Repeating them will not produce anything new. Use what you have, or take a different approach."
            ))
        }

        // Check 2: per-tool global frequency (catches alternating combos). Runs before the limit-1 warning so aborts outrank
        // warnings. The increment already happened at the top of this method; here we only check whether any key hit the cap.
        for key in components {
            let count = globalToolFrequency[key, default: 0]
            if count >= maxGlobalToolRepetitions {
                let toolName = key.components(separatedBy: "|").first ?? "unknown"
                logger.warning("🔁 Global repetition limit: '\(toolName)' executed \(count) times with identical args+output — requesting abort. CONSEQUENCE: the executor decides; with the default tolerance the run CONTINUES with a corrective alert rather than stopping.")
                return .abort(AbortTrigger(
                    kind: .staleToolRepetition,
                    reason: "Tool '\(toolName)' has been called \(count) times with the same parameters and results across multiple iterations. Breaking stale loop.",
                    modelNarrative: "You have called '\(toolName)' \(count) times with identical arguments and received identical output every time. Those calls SUCCEEDED — the output you already have is complete. Calling it again will return the same thing. Work with the result you have, or change approach."
                ))
            }
        }

        if current == limit - 1 {
            let toolNames = observations.map(\.toolName).joined(separator: ", ")
            logger.info("⚠️ Repetitive action warning: [\(toolNames)] repeated \(current) times. One more will trigger abort.")

            // Dual-channel warning: a terse chip/toast for the human, and a directive injected into the next iteration's working
            // memory so the model sees it before calling the same tool again and being aborted.
            let uiMessage = "Repetitive tool pattern detected: [\(toolNames)]. One more identical call \(nextRepeatConsequence.ui)."

            let modelAlert = """
            ⚠️ REPETITION DETECTED — SYSTEM INTERVENTION

            Tool(s) [\(toolNames)] just ran with identical arguments and produced identical output to the previous iteration. Running this exact call a third time \(nextRepeatConsequence.model).

            You MUST choose one of these three paths now:

            1. SWITCH TOOLS. The previous output is already in your working memory above — re-reading it will not help. Use a DIFFERENT tool to make progress.

            2. FINALIZE. If you already have enough information to answer the user's request, call `final_answer(answer: "...")` with your response. Do not call any other tool in the same step.

            3. ASK. If you are genuinely blocked on something only the user can clarify, call `ask_user(question: "...")`. Do not use `final_answer` to ask questions.

            Do NOT call [\(toolNames)] with the same arguments again.
            """

            return .proceedWithWarning(uiMessage: uiMessage, modelAlert: modelAlert)
        }

        // Check 2 warning, one strike before the global cap: the same dual-channel "switch / finalize / ask" alert,
        // one identical call early.
        if maxGlobalToolRepetitions >= 2 {
            for key in components where globalToolFrequency[key, default: 0] == maxGlobalToolRepetitions - 1 {
                let toolName = key.components(separatedBy: "|").first ?? "unknown"
                let count = globalToolFrequency[key, default: 0]
                logger.info("⚠️ Global repetition warning: '\(toolName)' at \(count)/\(self.maxGlobalToolRepetitions) identical calls. One more will trigger abort.")

                let uiMessage = "Tool '\(toolName)' keeps producing the same result. One more identical call \(nextRepeatConsequence.ui)."

                let modelAlert = """
                ⚠️ REPETITION DETECTED — SYSTEM INTERVENTION

                Tool '\(toolName)' has now returned identical output for the same arguments \(count) times across this run. Calling it again with the same arguments \(nextRepeatConsequence.model).

                You MUST choose one of these three paths now:

                1. SWITCH TOOLS. The previous output is already in your working memory above — re-reading it will not help. Use a DIFFERENT tool (or different arguments) to make progress.

                2. FINALIZE. If you already have enough information to answer the user's request, call `final_answer(answer: "...")` with your response. Do not call any other tool in the same step.

                3. ASK. If you are genuinely blocked on something only the user can clarify, call `ask_user(question: "...")`. Do not use `final_answer` to ask questions.

                Do NOT call '\(toolName)' with the same arguments again.
                """

                return .proceedWithWarning(uiMessage: uiMessage, modelAlert: modelAlert)
            }
        }

        return .proceed
    }

    // MARK: - Replay Priming (G1 resume)

    /// Re-primes the repetition bookkeeping from a resumed run's replayed iterations so the fingerprint streak and per-tool
    /// global counts survive a park → resume cycle. Silent: updates counters only and never returns an action.
    mutating func primeReplayedIteration(_ observations: [ToolObservation]) {
        guard !observations.isEmpty else { return }
        let components = Self.iterationComponents(observations)
        let fingerprint = components.joined(separator: ";;")
        for key in components {
            globalToolFrequency[key, default: 0] += 1
        }
        if fingerprint == lastIterationFingerprint {
            consecutiveIdenticalIterations += 1
        } else {
            lastIterationFingerprint = fingerprint
            consecutiveIdenticalIterations = 1
        }
    }

    /// Deterministic per-iteration fingerprint components: (tool, argsHash, output signature)
    /// per observation, tool-name-sorted. Shared by live evaluation and replay priming.
    private static func iterationComponents(_ observations: [ToolObservation]) -> [String] {
        observations
            .sorted(by: { $0.toolName < $1.toolName })
            .map { obs in
                let argsHash = obs.params.hashValue
                let normalized = normalizeForHashing(obs.output)
                let resultSignature = "\(normalized.count):\(normalized.hashValue)"
                return "\(obs.toolName)|\(argsHash)|\(resultSignature)"
            }
    }

    // MARK: - Metrics

    mutating func recordHallucination(_ toolName: String) {
        hallucinatedTools.insert(toolName)
    }

    // MARK: - Output Normalization (G3)

    // Why: identical outputs often differ by pure artifacts (shell `\r\n`, formatter spaces); timestamps and UUIDs are
    // not stripped, which is fragile and risks false equals on legitimately different outputs
    /// Normalizes tool output for deterministic hashing: collapses CRLF to LF and strips trailing whitespace per line.
    /// Leading whitespace is untouched so code indentation still discriminates different files.
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
