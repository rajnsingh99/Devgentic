//
//  TokenUsage.swift
//  Devgentic
//
//  Token usage tracking for LLM API calls.
//  Captures input/output token counts from provider responses.
//

import Foundation

/// Token usage metrics for a single LLM interaction.
/// Populated from provider API responses (Anthropic, OpenAI, Gemini, Ollama)
/// or estimated heuristically (MLX).
struct TokenUsage: Codable, Sendable, Hashable {
    /// Number of tokens in the prompt/input.
    var inputTokens: Int

    /// Number of tokens in the completion/output.
    var outputTokens: Int

    /// Total tokens (computed).
    var totalTokens: Int { inputTokens + outputTokens }

    /// `true` when counts are heuristic estimates (e.g. MLX where the framework
    /// doesn't expose token counts). `false` when reported by the provider API.
    var isEstimated: Bool

    init(inputTokens: Int = 0, outputTokens: Int = 0, isEstimated: Bool = false) {
        self.inputTokens = inputTokens
        self.outputTokens = outputTokens
        self.isEstimated = isEstimated
    }

    /// Accumulates another usage into this one (for multi-iteration loops).
    mutating func accumulate(_ other: TokenUsage) {
        inputTokens += other.inputTokens
        outputTokens += other.outputTokens
        // If any component is estimated, the total is estimated
        if other.isEstimated { isEstimated = true }
    }

    /// Returns a new usage combining this and another.
    func accumulated(with other: TokenUsage) -> TokenUsage {
        var copy = self
        copy.accumulate(other)
        return copy
    }

    // MARK: - Provider-Specific Extraction Helpers

    /// Extracts token usage from an Anthropic API response JSON.
    /// Path: `json["usage"]["input_tokens"]`, `json["usage"]["output_tokens"]`
    static func fromAnthropic(_ json: [String: Any]) -> TokenUsage? {
        guard let usage = json["usage"] as? [String: Any],
              let input = usage["input_tokens"] as? Int,
              let output = usage["output_tokens"] as? Int else { return nil }
        return TokenUsage(inputTokens: input, outputTokens: output)
    }

    /// Extracts token usage from an OpenAI API response JSON.
    /// Path: `json["usage"]["prompt_tokens"]`, `json["usage"]["completion_tokens"]`
    static func fromOpenAI(_ json: [String: Any]) -> TokenUsage? {
        guard let usage = json["usage"] as? [String: Any],
              let input = usage["prompt_tokens"] as? Int,
              let output = usage["completion_tokens"] as? Int else { return nil }
        return TokenUsage(inputTokens: input, outputTokens: output)
    }

    /// Extracts token usage from a Gemini API response JSON.
    /// Path: `json["usageMetadata"]["promptTokenCount"]`, `json["usageMetadata"]["candidatesTokenCount"]`
    static func fromGemini(_ json: [String: Any]) -> TokenUsage? {
        guard let usage = json["usageMetadata"] as? [String: Any],
              let input = usage["promptTokenCount"] as? Int else { return nil }
        let output = usage["candidatesTokenCount"] as? Int ?? 0
        return TokenUsage(inputTokens: input, outputTokens: output)
    }

    /// Extracts token usage from an Ollama API response JSON.
    /// Path: `json["prompt_eval_count"]`, `json["eval_count"]`
    static func fromOllama(_ json: [String: Any]) -> TokenUsage? {
        guard let input = json["prompt_eval_count"] as? Int else { return nil }
        let output = json["eval_count"] as? Int ?? 0
        return TokenUsage(inputTokens: input, outputTokens: output)
    }

    /// Heuristic estimation for providers that don't report token counts (MLX).
    /// Uses ~4 characters per token (BPE average for English prose).
    static func estimated(inputChars: Int, outputChars: Int) -> TokenUsage {
        TokenUsage(
            inputTokens: max(1, inputChars / 4),
            outputTokens: max(1, outputChars / 4),
            isEstimated: true
        )
    }
}
