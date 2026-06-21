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
    ///   - isNativeFlow: A flag indicating if the agent used Native tool calling (bypasses IC synthesis when `forceSynthesis` is false).
    ///   - forceSynthesis: When true, IC synthesis is always attempted even for native flows (user opted in for cloud models).
    /// - Returns: A non-empty user-facing string. Never throws.
    ///
    /// LLM synthesis is powered exclusively by IntelligenceCoreService.
    static func synthesize(
        summary: ExecutionSummary,
        personaInstructions: String? = nil,
        originalQuery: String,
        isNativeFlow: Bool = false,
        forceSynthesis: Bool = false,
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
        if isNativeFlow && !forceSynthesis {
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
        
        // --- FAST PATH 1: DETERMINISTIC FORMATTING (Single Tool) ---
        // If the agent used JSON mode but only executed 1 tool successfully,
        // we format the raw output deterministically without calling the LLM.
        if case .success = summary.completionStatus,
           summary.toolResults.count == 1,
           let result = summary.toolResults.first {
            logger.info("🏎️ [Synthesizer] Legacy Fast path — single success: '\(result.toolName)'.")
            return buildDeterministicResponse(for: result, goal: originalQuery)
        }

        // --- FAST PATH 2: STALLED WITH NO TOOLS ---
        // Nothing actually ran.
        if case .stalled = summary.completionStatus, summary.toolResults.isEmpty {
            logger.info("🏎️ [Synthesizer] Legacy Fast path — stalled with no tool results.")
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
                Task { await IntelligenceCoreService.shared.unload(caller: .responseSynthesis) }
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
    - If status is failed/stalled, explain what was attempted and what was missing.
    - Maximum 3 sentences for simple tasks.
    """

    // MARK: - LLM Synthesis Prompt

    private static func buildSynthesisPrompt(summary: ExecutionSummary, originalQuery: String) -> String {
        var lines: [String] = []
        lines.append("USER REQUEST: \"\(originalQuery)\"")
        lines.append("")
        
        if let thought = summary.finalAgentThought, !thought.isEmpty {
            lines.append("AGENT'S FINAL CONCLUSION / REASONING:")
            lines.append(thought)
            lines.append("")
        }

        lines.append("RESULTS:")

        if summary.toolResults.isEmpty {
            lines.append("No tools were executed.")
        } else {
            for result in summary.toolResults {
                let statusStr = result.isSuccess ? "Success" : "Failed"
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

    private static func buildDeterministicFallback(summary: ExecutionSummary) -> String {
        switch summary.completionStatus {

        case .success, .partialSuccess:
            let successes = summary.toolResults.filter(\.isSuccess)
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
            return "Here's what I found:\n" + outputs

        case .failed:
            let tools = summary.toolResults.map { String(describing: $0.toolName) }.joined(separator: ", ")
            return "I encountered errors while trying to complete your request. " +
                   "The following tools were attempted but did not succeed: " + tools + ". " +
                   "Please check that the required capabilities are enabled, or try rephrasing your request."

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
