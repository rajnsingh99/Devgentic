// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2026 Raj Singh
//
//  ResponseSynthesizer.swift
//  Devgentic
//
//  Created by Raj Singh on 21/02/26.
//
//  Converts a clean ExecutionSummary into a user-facing final response.
//
//  Two-path design:
//  1. Native Fast-Path:
//       If the orchestrator signals a Native API flow, we unconditionally trust
//       the agent's natural conversational output. Zero latency cost.
//
//  2. Legacy JSON-Mode Path:
//       Used for legacy models that were forced into strict JSON. Uses deterministic
//       formatting for single tools, or a secondary LLM call to synthesize complex multi-tool runs.
//
//  Guarantees:
//  - Never produces "I don't have the tools" when tools actually ran.
//  - Never surfaces scratchpad entries, system escalations, or internal monologue.
//  - Always returns a non-empty string (fallback path is always safe).
//

import Foundation
import OSLog

private let logger = DGLogger(category: "ResponseSynthesizer")

// MARK: - Synthesizer

struct ResponseSynthesizer {

    // MARK: - Entry Point

    /// Synthesizes a clean, user-friendly response from an ExecutionSummary.
    ///
    /// - Parameters:
    ///   - summary: The clean record of what happened during execution.
    ///   - personaInstructions: Injected instructions to ensure the synthesis doesn't degrade base persona behavior.
    ///   - originalQuery: The user's original query to ensure contextual grounding.
    ///   - isNativeFlow: A flag indicating if the agent used Native tool calling (bypasses IC synthesis when `synthesisOptedIn` is false).
    ///   - synthesisOptedIn: Whether the user opted this run's provider family into IC
    ///     synthesis (see `SynthesisOptIn`). When false, the IC branch is UNREACHABLE —
    ///     the model's own output is returned verbatim. Nothing forces synthesis:
    ///     not tool failures, not a circuit-breaker abort.
    /// - Returns: A non-empty user-facing string. Never throws.
    ///
    /// LLM synthesis is powered exclusively by IntelligenceCoreService.
    static func synthesize(
        summary: ExecutionSummary,
        personaInstructions: String? = nil,
        originalQuery: String,
        isNativeFlow: Bool = false,
        synthesisOptedIn: Bool = false,
        // Wrapper-run inner loops (Planning subtasks, Reflexion trials): never pay
        // for IC synthesis — their output is intermediate; the wrapper composes the
        // user-facing answer. The free paths above the LLM branch still apply; only
        // the IC call degrades to the deterministic builder. Deliberately wins over
        // `synthesisOptedIn` (a subtask must not load IC even when the user opted
        // the family in — the wrapper's own synthesis is the one that counts).
        suppressLLM: Bool = false,
        // Called with an (estimated) token-usage figure ONLY when the LLM synthesis path
        // runs — the native fast-path and deterministic fallbacks are free (D1). Optional
        // so existing callers compile unchanged.
        onUsage: ((TokenUsage) -> Void)? = nil
    ) async -> String {

        // =====================================================================
        // PATH A: NATIVE API FLOW (Modern Models)
        // =====================================================================
        // Native models output conversational answers naturally when they finish.
        // We trust them 100% UNLESS the user has opted into IC synthesis.
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

        // =====================================================================
        // PATH B: LEGACY JSON-MODE FLOW (Ollama/MLX strict parsing)
        // =====================================================================

        // --- FAST PATH 0: CONCLUSION-ONLY (no evidence tools ran) ---
        // A final_answer-only run leaves toolResults empty (final_answer is a
        // control signal, not evidence). There is nothing to synthesize against —
        // return the agent's answer directly instead of paying an IC call.
        if summary.toolResults.isEmpty,
           let thought = summary.finalAgentThought?.trimmingCharacters(in: .whitespacesAndNewlines),
           !thought.isEmpty {
            logger.info("🏎️ [Synthesizer] Conclusion-only fast path — no evidence tools; returning agent's answer directly.")
            let cleaned = OutputSanitizer.stripThinkBlocksAndTokens(thought)
            return cleaned.isEmpty ? thought : cleaned
        }

        // --- FAST PATH 1: DETERMINISTIC FORMATTING (Single Tool) ---
        // If the agent used JSON mode but only executed 1 tool successfully,
        // we format the raw output deterministically without calling the LLM.
        if case .success = summary.completionStatus,
           summary.toolResults.count == 1,
           let result = summary.toolResults.first {
            // If the agent composed an explicit final answer (final_answer text →
            // finalAgentThought), that IS the deliverable. Since final_answer is
            // no longer recorded as a tool result, a [tool, final_answer] run
            // reaches here with count == 1 — returning the raw tool output would
            // silently discard the answer.
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

        // --- SUPPRESSED: WRAPPER-RUN INNER LOOP ---
        // Everything below costs an IC model load/generate/unload. Inner runs
        // under Planning/Reflexion skip it — deterministic output is a cleaner
        // intermediate artifact for the wrapper's own synthesis anyway.
        if suppressLLM {
            logger.info("⏭️ [Synthesizer] LLM synthesis suppressed (wrapper-run inner loop). Using deterministic builder.")
            return buildDeterministicFallback(summary: summary)
        }

        // --- NOT OPTED IN: RAW PASSTHROUGH ---
        // IC synthesis is strictly opt-in per provider family (`SynthesisOptIn`).
        // Without it the model's own answer IS the deliverable — returned verbatim
        // apart from sanitization. This is the gate that legacy (non-native) JSON
        // runs previously fell straight through: PATH A only ever covered native
        // flows, so a legacy multi-tool run reached IC even with the toggle off.
        //
        // Nothing below this line may run un-opted: the IC pass is a small-model
        // rewrite that demonstrably compresses a larger model's finished answer.
        if !synthesisOptedIn {
            if let thought = summary.finalAgentThought?.trimmingCharacters(in: .whitespacesAndNewlines),
               !thought.isEmpty {
                // "the run's own output" rather than "the model's answer": for ReAct
                // this IS model-authored prose, but the Planning wrapper passes a
                // composed digest of its subtask results. Both are returned as-is.
                logger.info("🏎️ [Synthesizer] Not opted in — returning the run's own output verbatim (tools: \(summary.toolResults.count), status: \(String(describing: summary.completionStatus)), chars: \(thought.count)).")
                let cleaned = OutputSanitizer.stripThinkBlocksAndTokens(thought)
                return cleaned.isEmpty ? thought : cleaned
            }
            // No usable model output (circuit-breaker abort mid-loop, stalled legacy
            // parse). The deterministic template is the never-empty floor.
            logger.info("⚠️ [Synthesizer] Not opted in and no final answer — using deterministic fallback (tools: \(summary.toolResults.count), status: \(String(describing: summary.completionStatus))).")
            return buildDeterministicFallback(summary: summary)
        }

        // --- LLM SYNTHESIS PATH (Multi-Tool / Complex Output) ---
        // `completionStatus` is derived purely from per-tool success flags, which
        // means a forced-termination run (circuit-breaker abort, iteration
        // exhaustion) where all tools technically succeeded reads as
        // `.success` here — misleading during triage. Surface `failureReason`
        // alongside it so the log honestly reflects forced-termination cases.
        let statusInfo: String = {
            if let reason = summary.failureReason {
                return "\(String(describing: summary.completionStatus)) (forced-termination: \(reason.prefix(80)))"
            }
            return String(describing: summary.completionStatus)
        }()
        logger.info("🧠 [Synthesizer] Legacy LLM path triggered. Status: \(statusInfo), tools: \(summary.toolResults.count).")

        let prompt = buildSynthesisPrompt(summary: summary, originalQuery: originalQuery)
        
        // Context Trimming & Persona Injection (Phase 4)
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

            let response = try await IntelligenceCoreService.shared.generate(
                messages: messages,
                maxTokens: 1024,
                temperature: 0.6,
                caller: .responseSynthesis
            )

            // Strip think blocks and special tokens that the IC model may emit.
            // Uses the scoped sanitizer — does NOT strip code fences or wrapper tags
            // which could destroy legitimate markdown in the response.
            let cleaned = OutputSanitizer.stripThinkBlocksAndTokens(response)
            guard !cleaned.isEmpty else { throw SynthesizerError.emptyResponse }
            // Count this LLM synthesis call in the trace total (estimated; D1).
            onUsage?(.estimated(inputChars: systemPrompt.count + prompt.count, outputChars: response.count))
            logger.info("✅ [Synthesizer] IC synthesis succeeded.")
            return cleaned
        } catch {
            logger.error("❌ [Synthesizer] IC synthesis failed (\(error.localizedDescription)). Using deterministic fallback.")
            return buildDeterministicFallback(summary: summary)
        }
    }

    // MARK: - System Prompt (Synthesis Context)

    /// Minimal system prompt for the synthesizer LLM call.
    /// Deliberately short to reduce cognitive load and prevent reasoning bleed-through.
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
            // Labeled unverified: the conclusion is the model's own claim, not
            // evidence. Without this label (and with final_answer formerly listed
            // as a "(Success)" tool result), hallucinated answers were framed as
            // confirmed fact by the synthesizer.
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

    // Internal (not private) so tests can pin the answer-preserving behavior —
    // the LLM-failure path that reaches this in production needs a live IC model
    // to exercise, which unit tests can't do.
    static func buildDeterministicFallback(summary: ExecutionSummary) -> String {
        switch summary.completionStatus {

        case .success, .partialSuccess:
            // The agent's own final answer (when present) is the primary
            // deliverable; the tool bullets are corroborating context. This
            // branch previously dropped the answer entirely whenever IC
            // synthesis was unavailable.
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
                    // Explicit String concatenation avoids any risk of GRDB's SQL
                    // StringInterpolation capturing values as SQL expressions when
                    // the GRDB module is linked in the same target.
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
                // No answer and no successful output — surface the failure reason
                // (e.g. Planning's all-subtasks-failed error digest) framed as a
                // failure, rather than a bare "no output" or raw error text.
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
