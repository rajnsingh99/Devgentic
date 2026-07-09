//
//  CognitiveCircuitBreaker.swift
//  Devgentic
//
//  Created for ReAct Executor Modularization.
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

    /// User denials are a HARD constraint ("do not retry") that small-capacity models
    /// routinely ignore even when the directive appears in scratchpad. A dedicated
    /// counter with a tighter cap catches denial-retry loops before they waste
    /// iterations on HITL round-trips the user already rejected.
    /// NOTE: clarification (ask_user) loops are no longer counter-governed — identical
    /// re-asks are answered from RunInteractionMemory (deterministic replay), which makes
    /// them visible to the repetition fingerprint below; distinct questions are legitimate
    /// and bounded by the human in the loop + the iteration budget.
    private let maxConsecutiveDenials: Int

    init(maxConsecutiveToolFailures: Int = 3,
         maxRepetitiveActions: Int = 3,
         maxConsecutiveDenials: Int = 2) {
        self.maxConsecutiveToolFailures = maxConsecutiveToolFailures
        self.maxRepetitiveActions = maxRepetitiveActions
        self.maxConsecutiveDenials = maxConsecutiveDenials
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

    /// Tracks per-tool invocation frequency across ALL iterations (regardless of
    /// what other tools ran in the same iteration). Catches models that evade the
    /// iteration-level fingerprint by alternating tool combinations while
    /// repeating the same core action (e.g., read_file alone then read_file + list_directory).
    /// Key: "toolName|argsHash|outputSignature", Value: total count across all iterations.
    private(set) var globalToolFrequency: [String: Int] = [:]
    /// The global per-tool cap shares the repetition-tolerance knob (`maxRepetitiveActions`,
    /// configurable via ResilienceOverrides) — both checks catch the same phenomenon at
    /// different granularities, and a separate hardcoded cap made this the only abort
    /// trigger the user couldn't govern.
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
            logger.warning("🚫 Consecutive tool failure limit (\(maxFailures)) reached. Aborting.")
            return .abort(reason: "Reached \(maxFailures) consecutive tool failures without recovery.")
        }

        return .proceed
    }

    /// Records a user-denied tool call. Unlike general failures (3-strike cap), denials
    /// get a tighter 2-strike cap because the user has explicitly rejected the action —
    /// a second consecutive denial is strong evidence the model is ignoring the constraint.
    /// Each denial also counts toward the general failure counter so the existing 3-strike
    /// path still fires for mixed denial+failure patterns.
    mutating func recordDenial() -> CircuitBreakerAction {
        consecutiveDenials += 1
        consecutiveToolFailures += 1

        let currentDenials = consecutiveDenials
        let denialLimit = maxConsecutiveDenials

        if currentDenials >= denialLimit {
            logger.warning("🚫 Consecutive user-denial limit (\(denialLimit)) reached. Aborting.")
            return .abort(reason: "User denied \(currentDenials) consecutive tool calls. Halting to respect the denial constraint.")
        }

        // Fall through to the general failure check — mixed denial+failure patterns
        // still hit the 3-strike limit from recordToolResult's perspective.
        if consecutiveToolFailures >= maxConsecutiveToolFailures {
            logger.warning("🚫 Consecutive tool failure limit (\(maxConsecutiveToolFailures)) reached (including denials). Aborting.")
            return .abort(reason: "Reached \(maxConsecutiveToolFailures) consecutive tool failures without recovery.")
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
        let components = Self.iterationComponents(observations)
        let fingerprint = components.joined(separator: ";;")

        // Increment the global per-tool frequency tally UNCONDITIONALLY before any
        // early-return paths run. Previously the increment lived after the
        // iteration-level checks, so when `.proceedWithWarning` returned (current
        // == limit - 1), this iteration's contribution to the global counter was
        // skipped. A model that alternated combos to evade the iteration-level
        // fingerprint, then returned to a previously-warned pattern, could escape
        // the global cap because the warning iteration's count was missing.
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
            logger.warning("🔁 Repetitive action loop detected: [\(toolNames)] repeated \(current) times. Aborting.")
            return .abort(reason: "Detected \(current) consecutive identical tool calls [\(toolNames)] with the same results. Breaking degenerate loop.")
        }

        // --- Check 2: Per-tool global frequency (catches alternating combos) ---
        // Runs BEFORE the limit-1 warning: aborts outrank warnings. With the old
        // order, an iteration whose fingerprint counter sat at limit-1 returned the
        // warning early and masked a global-cap abort until the next iteration.
        // Tracks individual tool+args+output across ALL iterations — a model that
        // alternates [read_file] and [read_file, list_directory] evades the
        // iteration fingerprint but each read_file call is still identical.
        // The increment already happened at the top of this method; here we
        // only check whether any key has hit the cap.
        for key in components {
            let count = globalToolFrequency[key, default: 0]
            if count >= maxGlobalToolRepetitions {
                let toolName = key.components(separatedBy: "|").first ?? "unknown"
                logger.warning("🔁 Global repetition limit: '\(toolName)' executed \(count) times with identical args+output. Aborting.")
                return .abort(reason: "Tool '\(toolName)' has been called \(count) times with the same parameters and results across multiple iterations. Breaking stale loop.")
            }
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

        // --- Check 2 warning (one strike before the global cap) ---
        // The global per-tool check previously aborted COLD — unlike Check 1, a model that
        // alternated tool combos never saw a warning before being killed. Give it the same
        // dual-channel "switch / finalize / ask" alert one identical call early.
        if maxGlobalToolRepetitions >= 2 {
            for key in components where globalToolFrequency[key, default: 0] == maxGlobalToolRepetitions - 1 {
                let toolName = key.components(separatedBy: "|").first ?? "unknown"
                let count = globalToolFrequency[key, default: 0]
                logger.info("⚠️ Global repetition warning: '\(toolName)' at \(count)/\(self.maxGlobalToolRepetitions) identical calls. One more will trigger abort.")

                let uiMessage = "Tool '\(toolName)' keeps producing the same result. One more identical call will end this run."

                let modelAlert = """
                ⚠️ REPETITION DETECTED — SYSTEM INTERVENTION

                Tool '\(toolName)' has now returned identical output for the same arguments \(count) times across this run. Calling it again with the same arguments will ABORT this session.

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

    /// Re-primes the repetition bookkeeping from a resumed run's replayed iterations so the
    /// fingerprint streak and per-tool global counts survive a park → resume cycle (the breaker
    /// itself is a per-run local and would otherwise start from zero). Silent: updates counters
    /// only, never returns an action — the original run already reacted to these iterations.
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
