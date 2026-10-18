// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
//
//  ResponseSynthesizer.swift
//  Devgentic
//
//  Created by Raj Singh.
//

import Foundation
import OSLog

private let logger = DGLogger(category: "ResponseSynthesizer")

// MARK: - Synthesizer

/// Converts a clean `ExecutionSummary` into a user-facing final response.
/// Native flows return the agent's own output; legacy runs use deterministic formatting or a secondary LLM call;
/// never empty.
struct ResponseSynthesizer {

    // MARK: - Entry Point

    /// Synthesizes a clean, user-friendly response from an `ExecutionSummary`; never throws or returns empty.
    /// `isNativeFlow` bypasses IC synthesis unless `synthesisOptedIn` is true (see `SynthesisOptIn`).
    /// `personaInstructions` keep the persona intact.
    static func synthesize(
        summary: ExecutionSummary,
        personaInstructions: String? = nil,
        originalQuery: String,
        isNativeFlow: Bool = false,
        synthesisOptedIn: Bool = false,
        // Wrapper-run inner loops (Planning, Reflexion) never pay for IC synthesis; this wins over `synthesisOptedIn`, as
        // the wrapper synthesizes.
        suppressLLM: Bool = false,
        // Called with an estimated token usage only when the LLM synthesis path runs; the native and deterministic paths
        // are free.
        onUsage: ((TokenUsage) -> Void)? = nil
    ) async -> String {

        // Path A, native API flow: native models answer conversationally, so trust them unless the user opted into IC
        // synthesis.
        if isNativeFlow && !synthesisOptedIn {
            if let rawAnswer = summary.finalAgentThought?.trimmingCharacters(in: .whitespacesAndNewlines), !rawAnswer.isEmpty {
                logger.info("🏎️ [Synthesizer] Native API flow detected. Returning agent's natural response directly.")
                let finalAnswer = OutputSanitizer.stripThinkBlocksAndTokens(rawAnswer)
                return finalAnswer.isEmpty ? rawAnswer : finalAnswer
            }

            // If the native loop crashed or stalled abruptly without generating a final thought:
            logger.info("⚠️ [Synthesizer] Native API flow ended without a final thought. Using deterministic fallback.")
            return buildDeterministicFallback(summary: summary)
        }

        // Path B, legacy JSON-mode flow (Ollama/MLX strict parsing).

        // Conclusion-only runs (no evidence tools): `final_answer` is a control signal, so return the agent's answer
        // without an IC call.
        if summary.toolResults.isEmpty,
           let thought = summary.finalAgentThought?.trimmingCharacters(in: .whitespacesAndNewlines),
           !thought.isEmpty {
            logger.info("🏎️ [Synthesizer] Conclusion-only fast path — no evidence tools; returning agent's answer directly.")
            let cleaned = OutputSanitizer.stripThinkBlocksAndTokens(thought)
            return cleaned.isEmpty ? thought : cleaned
        }

        // Single-tool deterministic formatting: one successful tool in JSON mode is formatted without calling the LLM.
        if case .success = summary.completionStatus,
           summary.toolResults.count == 1,
           let result = summary.toolResults.first {
            // An explicit final answer is the deliverable; a [tool, final_answer] run has one tool result, and the raw output
            // would discard the answer.
            if let thought = summary.finalAgentThought?.trimmingCharacters(in: .whitespacesAndNewlines),
               !thought.isEmpty {
                logger.info("🏎️ [Synthesizer] Legacy Fast path — single success with final answer: returning agent's answer.")
                let cleaned = OutputSanitizer.stripThinkBlocksAndTokens(thought)
                return cleaned.isEmpty ? thought : cleaned
            }
            logger.info("🏎️ [Synthesizer] Legacy Fast path — single success: '\(result.toolName)'.")
            return buildDeterministicResponse(for: result, goal: originalQuery)
        }

        // --- FAST PATH 2: STALLED WITH NO TOOLS ---
        // Nothing actually ran.
        if case .stalled = summary.completionStatus, summary.toolResults.isEmpty {
            logger.info("🏎️ [Synthesizer] Legacy Fast path — stalled with no tool results.")
            return buildDeterministicFallback(summary: summary)
        }

        // Suppressed for wrapper-run inner loops: everything below costs an IC load, and deterministic output suits the
        // wrapper's own synthesis.
        if suppressLLM {
            logger.info("⏭️ [Synthesizer] LLM synthesis suppressed (wrapper-run inner loop). Using deterministic builder.")
            return buildDeterministicFallback(summary: summary)
        }

        // Not opted in: raw passthrough. IC synthesis is strictly opt-in per provider family, and nothing below this line
        // may run un-opted.
        if !synthesisOptedIn {
            if let thought = summary.finalAgentThought?.trimmingCharacters(in: .whitespacesAndNewlines),
               !thought.isEmpty {
                // Called "the run's own output": for ReAct it is model prose, for Planning a composed digest; both are returned
                // as-is.
                logger.info("🏎️ [Synthesizer] Not opted in — returning the run's own output verbatim (tools: \(summary.toolResults.count), status: \(String(describing: summary.completionStatus)), chars: \(thought.count)).")
                let cleaned = OutputSanitizer.stripThinkBlocksAndTokens(thought)
                return cleaned.isEmpty ? thought : cleaned
            }
            // No usable model output (circuit-breaker abort mid-loop, stalled legacy
            // parse). The deterministic template is the never-empty floor.
            logger.info("⚠️ [Synthesizer] Not opted in and no final answer — using deterministic fallback (tools: \(summary.toolResults.count), status: \(String(describing: summary.completionStatus))).")
            return buildDeterministicFallback(summary: summary)
        }

        // LLM synthesis path (multi-tool or complex output); `failureReason` is logged beside the status, which reads
        // `.success` for forced terminations.
        let statusInfo: String = {
            if let reason = summary.failureReason {
                return "\(String(describing: summary.completionStatus)) (forced-termination: \(reason.prefix(80)))"
            }
            return String(describing: summary.completionStatus)
        }()
        logger.info("🧠 [Synthesizer] Legacy LLM path triggered. Status: \(statusInfo), tools: \(summary.toolResults.count).")

        let prompt = buildSynthesisPrompt(summary: summary, originalQuery: originalQuery)
        
        // Context trimming and persona injection.
        var systemPrompt = synthesizerSystemPrompt
        if let persona = personaInstructions {
            systemPrompt += "\n\nCRITICAL: Maintain the following persona:\n\(persona)"
        }

        let messages: [[String: String]] = [
            ["role": "system", "content": systemPrompt],
            ["role": "user",   "content": prompt]
        ]

        do {
            defer {
                Task { await IntelligenceCoreService.shared.releaseHold(caller: .responseSynthesis) }
            }

            // Bounded by `DeadlineRace` because this runs after the agent finished; a stalled IC load would leave the turn
            // spinning, so fall back to the deterministic answer.
            let raceMessages = UnsafeSendable(messages)
            let outcome = try await DeadlineRace.run(limit: Self.synthesisDeadlineSeconds, stopGrace: 1) {
                // The local lock: never waited for here (see `claimForInTurnIntelligence`).
                try await LocalInferenceCoordinator.inTurnIntelligence(
                    feature: "response synthesis", on: await Self.coordinator()
                ) {
                    try await IntelligenceCoreService.shared.generate(
                        messages: raceMessages.value,
                        maxTokens: 1024,
                        temperature: 0.6,
                        caller: .responseSynthesis
                    )
                }
            }
            let response: String
            switch outcome {
            case .finished(let result):
                response = try result.get()
            case .timedOut(let elapsed, _):
                logger.error("[Synthesizer] IC synthesis TIMED OUT after \(Int(elapsed))s (limit \(Int(Self.synthesisDeadlineSeconds))s) — tools: \(summary.toolResults.count). CONSEQUENCE: the turn ends with the deterministic answer instead of waiting on the Intelligence Core; the abandoned generation is cancelled.")
                return buildDeterministicFallback(summary: summary)
            }

            // Strips think blocks and special tokens with the scoped sanitizer, which leaves code fences and wrapper tags
            // alone.
            let cleaned = OutputSanitizer.stripThinkBlocksAndTokens(response)
            guard !cleaned.isEmpty else { throw SynthesizerError.emptyResponse }
            // Count this LLM synthesis call in the trace total (estimated; D1).
            onUsage?(.estimated(inputChars: systemPrompt.count + prompt.count, outputChars: response.count))
            logger.info("✅ [Synthesizer] IC synthesis succeeded.")
            return cleaned
        } catch let busy as LocalInferenceCoordinator.LocalSlotBusy {
            logger.notice("[Synthesizer] IC synthesis SKIPPED — the local model is busy (\(busy.holder)). CONSEQUENCE: the turn ends with the deterministic answer now, instead of waiting behind another run.")
            return buildDeterministicFallback(summary: summary)
        } catch is CancellationError {
            // A stop is not a synthesis failure: the IC does not return partial text as an answer, so it is discarded.
            logger.notice("[Synthesizer] IC synthesis was cancelled. CONSEQUENCE: its partial text is discarded; using the deterministic fallback.")
            return buildDeterministicFallback(summary: summary)
        } catch {
            logger.error("❌ [Synthesizer] IC synthesis failed (\(error.localizedDescription)). Using deterministic fallback.")
            return buildDeterministicFallback(summary: summary)
        }
    }

    /// Wall-clock bound on the whole IC synthesis call, model load included; synthesis is at most 1,024 tokens from a
    /// small local model.
    static let synthesisDeadlineSeconds: TimeInterval = 60

    /// The coordinator in-turn synthesis claims the local lock from. Tests point it at their own.
    nonisolated(unsafe) static var coordinatorOverride: LocalInferenceCoordinator?
    @MainActor static func coordinator() -> LocalInferenceCoordinator { coordinatorOverride ?? .shared }

    // MARK: - System Prompt (Synthesis Context)

    /// Minimal system prompt for the synthesizer call, kept short to reduce reasoning bleed-through.
    private static let synthesizerSystemPrompt = """
    You are a response formatter. Based on the provided tool execution results and the agent's final conclusion, write a clear, concise response to the user's original request.

    Rules:
    - Write in second person, natural language.
    - Do NOT mention internal steps, system messages, or reasoning.
    - Only state facts supported by successful tool results. If the claimed conclusion is unsupported by them, present it explicitly as unverified.
    - If status is failed/stalled, explain what was attempted and what was missing.
    - Maximum 3 sentences for simple tasks.
    """

    // MARK: - LLM Synthesis Prompt

    private static func buildSynthesisPrompt(summary: ExecutionSummary, originalQuery: String) -> String {
        var lines: [String] = []
        lines.append("USER REQUEST: \"\(originalQuery)\"")
        lines.append("")
        
        if let thought = summary.finalAgentThought, !thought.isEmpty {
            // Labeled unverified: the conclusion is the model's own claim, so hallucinated answers are not framed as confirmed
            // fact.
            lines.append("AGENT'S CLAIMED CONCLUSION (unverified — do not state claims as fact unless supported by a successful tool result below):")
            lines.append(thought)
            lines.append("")
        }

        lines.append("RESULTS:")

        if summary.toolResults.isEmpty {
            lines.append("No tools were executed.")
        } else {
            for result in summary.toolResults {
                // User decisions are labeled as such so the IC model doesn't
                // narrate a denial as a malfunction.
                let statusStr: String
                if result.isSuccess {
                    statusStr = "Success"
                } else if result.failureCategory == .userDenied {
                    statusStr = "Denied by user"
                } else if result.failureCategory == .cancelled {
                    statusStr = "Skipped by user"
                } else {
                    statusStr = "Failed"
                }
                let toolName = String(describing: result.toolName)
                let rawOutput = String(describing: result.output)
                // Cap output at 800 chars to stay well within context budget.
                let truncated = rawOutput.count > 800
                    ? String(rawOutput.prefix(800)) + "… [truncated]"
                    : rawOutput.trimmingCharacters(in: .whitespacesAndNewlines)

                lines.append("Tool: " + toolName + " → Output: " + truncated + " (" + statusStr + ")")
            }
        }

        lines.append("")
        lines.append("STATUS: \(summary.completionStatus)")
        
        if let failureReason = summary.failureReason {
            lines.append("FAILURE REASON: \(failureReason)")
        }

        return lines.joined(separator: "\n")
    }

    // MARK: - Deterministic Fast Path

    /// Formats a single successful tool result without calling the LLM.
    private static func buildDeterministicResponse(for result: SynthesizedToolResult, goal: String) -> String {
        let output = result.output.trimmingCharacters(in: .whitespacesAndNewlines)

        // JSON array → bullet list (e.g., directory listings, search results).
        if let data = output.data(using: .utf8),
           let jsonArray = try? JSONSerialization.jsonObject(with: data) as? [Any] {
            let items = jsonArray.compactMap { "\($0)" }
            if !items.isEmpty {
                let list = items.map { "• \($0)" }.joined(separator: "\n")
                return "Here's what I found:\n\(list)"
            }
        }

        // JSON dict → key-value list.
        if let data = output.data(using: .utf8),
           let jsonDict = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            let pairs = jsonDict.map { "• \($0.key): \($0.value)" }.sorted()
            if !pairs.isEmpty {
                return "Here are the results:\n\(pairs.joined(separator: "\n"))"
            }
        }

        // Plain text: return as-is (the tool output is already human-readable).
        return output
    }

    // MARK: - Deterministic Fallback (when LLM is unavailable)

    // Internal so tests can pin the answer-preserving behaviour; the LLM-failure path that reaches it needs a live IC
    // model.
    static func buildDeterministicFallback(summary: ExecutionSummary) -> String {
        switch summary.completionStatus {

        case .success, .partialSuccess:
            // The agent's own final answer is the primary deliverable and the tool bullets are corroborating context.
            var sections: [String] = []
            if let thought = summary.finalAgentThought?.trimmingCharacters(in: .whitespacesAndNewlines),
               !thought.isEmpty {
                let cleaned = OutputSanitizer.stripThinkBlocksAndTokens(thought)
                sections.append(cleaned.isEmpty ? thought : cleaned)
            }
            let successes = summary.toolResults.filter(\.isSuccess)
            if !successes.isEmpty {
                let outputs = successes.map { r -> String in
                    let toolName = String(describing: r.toolName)
                    let output = String(describing: r.output)
                    let truncated = output.count > 200
                        ? String(output.prefix(200)) + "…"
                        : output
                    // Explicit string concatenation avoids GRDB's SQL string interpolation capturing values as SQL expressions.
                    return "• " + toolName + ": " + truncated
                }.joined(separator: "\n")
                sections.append("Here's what I found:\n" + outputs)
            }
            // Honest caveat on partial runs: name the evidence failures (user
            // denials/skips are decisions, not failures — excluded).
            let failures = summary.toolResults.filter {
                !$0.isSuccess && $0.failureCategory != .userDenied && $0.failureCategory != .cancelled
            }
            if case .partialSuccess = summary.completionStatus, !failures.isEmpty {
                let names = Set(failures.map(\.toolName)).sorted().joined(separator: ", ")
                sections.append("Note: \(failures.count) tool call(s) did not succeed (\(names)).")
            }
            if sections.isEmpty {
                // No answer and no successful output: surface the failure reason, framed as a failure, rather than a bare "no
                // output".
                if let reason = summary.failureReason?.trimmingCharacters(in: .whitespacesAndNewlines), !reason.isEmpty {
                    return "I couldn't complete the task:\n\(reason)"
                }
                return "The task ended without producing any output. Please try again or rephrase your request."
            }
            return sections.joined(separator: "\n\n")

        case .failed:
            let tools = summary.toolResults.map { String(describing: $0.toolName) }.joined(separator: ", ")
            var message = "I encountered errors while trying to complete your request. " +
                   "The following tools were attempted but did not succeed: " + tools + ". " +
                   "Please check that the required capabilities are enabled, or try rephrasing your request."
            // The agent's claim is occasionally right even when evidence tools
            // failed — surface it, but labeled so it can't read as a finding.
            if let claim = summary.finalAgentThought?.trimmingCharacters(in: .whitespacesAndNewlines), !claim.isEmpty {
                message += "\n\nUnverified conclusion from the agent: \"" + claim + "\""
            }
            return message

        case .stalled:
            return "I wasn't able to determine how to complete your request with the available tools. " +
                   "Please try rephrasing, or check that the required tools are enabled in your agent profile."
        }
    }
}

// MARK: - Errors

private enum SynthesizerError: Error {
    case emptyResponse
}
