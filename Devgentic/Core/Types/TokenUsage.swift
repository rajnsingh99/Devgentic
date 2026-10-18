// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
//
//  TokenUsage.swift
//  Devgentic
//
//  Created by Raj Singh.
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

    /// The part of `inputTokens` served from the provider's prompt cache (Anthropic `cache_read_input_tokens`,
    /// OpenAI `cached_tokens`, Gemini `cachedContentTokenCount`).
    /// Included in `inputTokens`, not beside it, so gauges that read `inputTokens` are unaffected; only cost reads the split.
    var cacheReadTokens: Int

    /// The part of `inputTokens` a provider wrote to its prompt cache (Anthropic
    /// `cache_creation_input_tokens`), priced above plain input. Also inside `inputTokens`.
    var cacheWriteTokens: Int

    /// What these tokens cost in USD, summed from each call's own price (`ModelPriceList`): the
    /// provider's reported cost, else the bundled list's. Nil when no call could be priced — a
    /// local model, a custom endpoint, a model the list doesn't name.
    var costUSD: Double?

    /// True when `costUSD` covers only some of the calls: at least one call with tokens had no
    /// price. The sum is still the true cost of the calls that were priced.
    var costIsPartial: Bool

    init(inputTokens: Int = 0, outputTokens: Int = 0, isEstimated: Bool = false,
         cacheReadTokens: Int = 0, cacheWriteTokens: Int = 0,
         costUSD: Double? = nil, costIsPartial: Bool = false) {
        self.inputTokens = inputTokens
        self.outputTokens = outputTokens
        self.isEstimated = isEstimated
        self.cacheReadTokens = cacheReadTokens
        self.cacheWriteTokens = cacheWriteTokens
        self.costUSD = costUSD
        self.costIsPartial = costIsPartial
    }

    private enum CodingKeys: String, CodingKey {
        case inputTokens, outputTokens, isEstimated, cacheReadTokens, cacheWriteTokens, costUSD, costIsPartial
    }

    /// Hand-written so missing cache keys decode as 0 (`decodeIfPresent`); the synthesized decoder would throw
    /// and drop the usage badge. Encoding stays synthesized: add a decode line here for every new field
    /// (`TokenUsageCodingTests` round-trips each).
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        inputTokens = try container.decode(Int.self, forKey: .inputTokens)
        outputTokens = try container.decode(Int.self, forKey: .outputTokens)
        isEstimated = try container.decode(Bool.self, forKey: .isEstimated)
        cacheReadTokens = try container.decodeIfPresent(Int.self, forKey: .cacheReadTokens) ?? 0
        cacheWriteTokens = try container.decodeIfPresent(Int.self, forKey: .cacheWriteTokens) ?? 0
        costUSD = try container.decodeIfPresent(Double.self, forKey: .costUSD)
        costIsPartial = try container.decodeIfPresent(Bool.self, forKey: .costIsPartial) ?? false
    }

    /// This usage as ONE call on `key`, priced from the bundled list. For a usage assembled from
    /// stream partials, priced once they are combined — never each partial, or a long-context
    /// call's output would be priced at the short-context rate.
    func priced(_ key: PricingKey) -> TokenUsage {
        var copy = self
        copy.costUSD = ModelPriceList.shared.cost(of: self, for: key)
        copy.costIsPartial = false
        return copy
    }

    /// Accumulates another usage into this one (for multi-iteration loops).
    mutating func accumulate(_ other: TokenUsage) {
        let totalTokensBefore = totalTokens
        inputTokens += other.inputTokens
        outputTokens += other.outputTokens
        cacheReadTokens += other.cacheReadTokens
        cacheWriteTokens += other.cacheWriteTokens
        // If any component is estimated, the total is estimated
        if other.isEstimated { isEstimated = true }

        // Costs add up per call. A side with tokens but no cost leaves the total partial — but only
        // once something WAS priced: an all-local run has no cost, not a partial one.
        let selfUnpriced = costUSD == nil && totalTokensBefore > 0
        let otherUnpriced = other.costUSD == nil && other.totalTokens > 0
        if costUSD != nil || other.costUSD != nil {
            costIsPartial = costIsPartial || other.costIsPartial || selfUnpriced || otherUnpriced
            costUSD = (costUSD ?? 0) + (other.costUSD ?? 0)
        }
    }

    /// Returns a new usage combining this and another.
    func accumulated(with other: TokenUsage) -> TokenUsage {
        var copy = self
        copy.accumulate(other)
        return copy
    }

    // MARK: - Provider-Specific Extraction Helpers

    /// Extracts token usage from an Anthropic API response JSON (`usage.input_tokens`, `usage.output_tokens`).
    /// `pricing` is required on every provider constructor: a call site must say which model it priced,
    /// or its run shows no cost.
    static func fromAnthropic(_ json: [String: Any], pricing: PricingKey) -> TokenUsage? {
        guard let usage = json["usage"] as? [String: Any],
              let output = usage["output_tokens"] as? Int,
              let input = anthropicInput(usage) else { return nil }
        return TokenUsage(inputTokens: input.total, outputTokens: output,
                          cacheReadTokens: input.read, cacheWriteTokens: input.written).priced(pricing)
    }

    // Why: `input_tokens` alone is only the part after the last cache breakpoint; cached parts are reported separately.
    /// The prompt side of an Anthropic `usage` object (a response's, or a stream's `message_start`).
    /// Returns the total, cache-read and cache-written token counts, or nil without `input_tokens`.
    static func anthropicInput(_ usage: [String: Any]) -> (total: Int, read: Int, written: Int)? {
        guard let uncached = usage["input_tokens"] as? Int else { return nil }
        let read = usage["cache_read_input_tokens"] as? Int ?? 0
        let written = usage["cache_creation_input_tokens"] as? Int ?? 0
        return (uncached + read + written, read, written)
    }

    /// Extracts token usage from an OpenAI API response JSON (`usage.prompt_tokens`, `usage.completion_tokens`).
    /// Cached prefix hits arrive in `prompt_tokens_details.cached_tokens`, already inside `prompt_tokens`.
    /// A reported `usage.cost` (OpenRouter usage accounting) is the call's exact cost and the only price it gets.
    static func fromOpenAI(_ json: [String: Any], pricing: PricingKey) -> TokenUsage? {
        guard let usage = json["usage"] as? [String: Any],
              let input = usage["prompt_tokens"] as? Int,
              let output = usage["completion_tokens"] as? Int else { return nil }
        let cached = (usage["prompt_tokens_details"] as? [String: Any])?["cached_tokens"] as? Int ?? 0
        let call = TokenUsage(inputTokens: input, outputTokens: output, cacheReadTokens: min(max(0, cached), input))
        if let reported = (usage["cost"] as? NSNumber)?.doubleValue {
            var copy = call
            copy.costUSD = reported
            return copy
        }
        return call.priced(pricing)
    }

    // Why: thinking tokens arrive in `thoughtsTokenCount`, outside `candidatesTokenCount`; add them so "output"
    // means the same on all three providers.
    /// Extracts token usage from a Gemini API response JSON (`usageMetadata.promptTokenCount`, `candidatesTokenCount`).
    /// Implicit cache hits arrive in `cachedContentTokenCount`, already inside `promptTokenCount`, as with OpenAI.
    static func fromGemini(_ json: [String: Any], pricing: PricingKey) -> TokenUsage? {
        guard let usage = json["usageMetadata"] as? [String: Any],
              let input = usage["promptTokenCount"] as? Int else { return nil }
        let output = (usage["candidatesTokenCount"] as? Int ?? 0) + (usage["thoughtsTokenCount"] as? Int ?? 0)
        let cached = usage["cachedContentTokenCount"] as? Int ?? 0
        return TokenUsage(inputTokens: input, outputTokens: output, cacheReadTokens: min(max(0, cached), input)).priced(pricing)
    }

    /// Extracts token usage from an Ollama API response JSON.
    /// Path: `json["prompt_eval_count"]`, `json["eval_count"]`
    static func fromOllama(_ json: [String: Any]) -> TokenUsage? {
        guard let input = json["prompt_eval_count"] as? Int else { return nil }
        let output = json["eval_count"] as? Int ?? 0
        return TokenUsage(inputTokens: input, outputTokens: output)
    }

    // Why: estimates are accumulated with real data and only `isEstimated` is OR'd, so one estimate makes a total read "~".
    /// Heuristic fallback for a specific call that has no provider-reported usage.
    /// Used for `ResponseSynthesizer`, stop-sequence or circuit-breaker breaks that skip MLX's `.info`, and sub-calls.
    /// Uses 4.0 chars per token, not `PromptFitCheck.charsPerToken` (3.0): over-estimating inflates a cost figure.
    static func estimated(inputChars: Int, outputChars: Int) -> TokenUsage {
        TokenUsage(
            inputTokens: max(1, inputChars / 4),
            outputTokens: max(1, outputChars / 4),
            isEstimated: true
        )
    }
}
