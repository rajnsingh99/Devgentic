// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
//
//  ModelPriceList.swift
//  Devgentic
//
//  What a cloud call cost, priced when its usage is read — per call, at that call's own model.
//
//  1. A provider-reported cost wins (OpenRouter returns `usage.cost`; we request usage accounting).
//  2. Otherwise the bundled `ModelPrices.json` — generated from LiteLLM's price list by
//     `scripts/update-model-prices.py`, refreshed before each release, never fetched at runtime.
//  3. Otherwise no cost: local models, custom OpenAI-compatible endpoints, and models the list
//     does not name.
//
//  ⚠️ EXACT model lookup, never a family or substring match. The hand-kept table this replaced
//  matched `claude-opus` and `gemini-2`, so one row priced several generations — every Opus at the
//  oldest Opus price, Gemini 2.5 at 2.0 Flash's. An unknown model now shows no cost and says so once
//  in the log, which is honest; a near-miss price is not.
//

import Foundation

private let logger = DGLogger(category: "Pricing")

/// Which price source a provider's calls use.
enum PricingProvider: String, Sendable {
    case anthropic, openAI, gemini
    /// Reports its own cost per call; never looked up in the list.
    case openRouter
    /// Never priced: a custom OpenAI-compatible endpoint (often a local server) or a local model.
    case unpriced
}

/// The model a call ran on, as its provider names it.
struct PricingKey: Sendable, Hashable {
    let provider: PricingProvider
    let model: String
}

/// One model's rates, in USD per token. Absent cache rates fall back to the input rate.
struct ModelPrice: Decodable, Sendable, Equatable {
    let input: Double
    let output: Double
    let cacheRead: Double?
    let cacheWrite: Double?
    let inputAbove200k: Double?
    let outputAbove200k: Double?
    let cacheReadAbove200k: Double?
    let cacheWriteAbove200k: Double?

    private enum CodingKeys: String, CodingKey {
        case input = "input_cost_per_token"
        case output = "output_cost_per_token"
        case cacheRead = "cache_read_input_token_cost"
        case cacheWrite = "cache_creation_input_token_cost"
        case inputAbove200k = "input_cost_per_token_above_200k_tokens"
        case outputAbove200k = "output_cost_per_token_above_200k_tokens"
        case cacheReadAbove200k = "cache_read_input_token_cost_above_200k_tokens"
        case cacheWriteAbove200k = "cache_creation_input_token_cost_above_200k_tokens"
    }

    /// The prompt size above which the `…Above200k` rates apply — to ONE call's prompt, which is
    /// why pricing happens per call and never on a run's total.
    static let longContextThreshold = 200_000

    /// The cost of one call. Cached tokens are inside `usage.inputTokens`.
    func cost(of usage: TokenUsage) -> Double {
        let long = usage.inputTokens > Self.longContextThreshold
        let inputRate = long ? (inputAbove200k ?? input) : input
        let outputRate = long ? (outputAbove200k ?? output) : output
        let readRate = (long ? cacheReadAbove200k : nil) ?? cacheRead ?? inputRate
        let writeRate = (long ? cacheWriteAbove200k : nil) ?? cacheWrite ?? inputRate
        let plain = max(0, usage.inputTokens - usage.cacheReadTokens - usage.cacheWriteTokens)
        return Double(plain) * inputRate
            + Double(usage.cacheReadTokens) * readRate
            + Double(usage.cacheWriteTokens) * writeRate
            + Double(usage.outputTokens) * outputRate
    }
}

final class ModelPriceList: @unchecked Sendable {

    static let shared = ModelPriceList(bundle: .main)

    /// Keyed as LiteLLM keys them: Anthropic and OpenAI by bare model name, Gemini as `gemini/<name>`.
    let prices: [String: ModelPrice]
    /// The `_source` block of the bundled file — which LiteLLM commit it came from, and when.
    let source: [String: String]

    private let lock = NSLock()
    private var reportedUnknown = Set<PricingKey>()

    init(prices: [String: ModelPrice], source: [String: String] = [:]) {
        self.prices = prices
        self.source = source
    }

    private struct File: Decodable {
        let _source: [String: String]
        let models: [String: ModelPrice]
    }

    convenience init(bundle: Bundle) {
        guard let url = bundle.url(forResource: "ModelPrices", withExtension: "json") else {
            logger.error("[PRICING] ModelPrices.json is missing from the app bundle. CONSEQUENCE: no Anthropic, OpenAI or Gemini call shows a cost.")
            self.init(prices: [:])
            return
        }
        do {
            let file = try JSONDecoder().decode(File.self, from: Data(contentsOf: url))
            self.init(prices: file.models, source: file._source)
        } catch {
            logger.error("[PRICING] ModelPrices.json could not be read: \(error.localizedDescription). CONSEQUENCE: no Anthropic, OpenAI or Gemini call shows a cost.")
            self.init(prices: [:])
        }
    }

    /// The list's entry for `key`, or nil. Tries the name as given, then without a trailing date
    /// (`-20250929`, `-2024-08-06`) or `-latest` — nothing looser.
    func price(for key: PricingKey) -> ModelPrice? {
        let prefix: String
        switch key.provider {
        case .anthropic, .openAI: prefix = ""
        case .gemini: prefix = "gemini/"
        case .openRouter, .unpriced: return nil
        }
        var name = key.model.lowercased()
        if name.hasPrefix("models/") { name.removeFirst("models/".count) }   // Gemini's resource form
        for candidate in [name, Self.withoutVersionSuffix(name)].compactMap({ $0 }) {
            if let price = prices[prefix + candidate] { return price }
        }
        return nil
    }

    /// The cost of one call, or nil when the list has no price for it.
    func cost(of usage: TokenUsage, for key: PricingKey) -> Double? {
        if let price = price(for: key) { return price.cost(of: usage) }
        switch key.provider {
        case .anthropic, .openAI, .gemini:
            lock.lock()
            let first = reportedUnknown.insert(key).inserted
            lock.unlock()
            if first {
                logger.notice("[PRICING] No price for '\(key.model)' (\(key.provider.rawValue)) in the bundled list (LiteLLM \(self.source["commit"]?.prefix(12) ?? "?"), \(self.source["fetched"] ?? "?")). CONSEQUENCE: its calls show no cost; run scripts/update-model-prices.py if it is a new model.")
            }
        case .openRouter, .unpriced:
            break
        }
        return nil
    }

    static func withoutVersionSuffix(_ name: String) -> String? {
        for pattern in [#"-\d{8}$"#, #"-\d{4}-\d{2}-\d{2}$"#, #"-latest$"#] {
            if let range = name.range(of: pattern, options: .regularExpression) {
                return String(name[..<range.lowerBound])
            }
        }
        return nil
    }
}
