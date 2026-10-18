// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
//
//  ModelPriceListTests.swift
//  DevgenticTests
//
//  Created by Raj Singh.
//

import XCTest
@testable import devgentic

final class ModelPriceListTests: XCTestCase {

    private func rates(input: Double, output: Double, cacheRead: Double? = nil, cacheWrite: Double? = nil,
                       inputAbove200k: Double? = nil, outputAbove200k: Double? = nil) -> ModelPrice {
        ModelPrice(input: input, output: output, cacheRead: cacheRead, cacheWrite: cacheWrite,
                   inputAbove200k: inputAbove200k, outputAbove200k: outputAbove200k,
                   cacheReadAbove200k: nil, cacheWriteAbove200k: nil)
    }

    // MARK: - The bundled file

    func testTheBundledListLoadsWithItsSource() {
        let list = ModelPriceList.shared
        XCTAssertGreaterThan(list.prices.count, 50, "ModelPrices.json is missing or nearly empty")
        XCTAssertNotNil(list.source["commit"], "the file must record which LiteLLM commit it came from")
        for (name, price) in list.prices {
            XCTAssertGreaterThanOrEqual(price.input, 0, "\(name) has a negative input rate")
            XCTAssertGreaterThanOrEqual(price.output, 0, "\(name) has a negative output rate")
            // Zero is real only where the API is free (Gemini's Gemma and experimental models).
            // Anthropic and OpenAI have no free models, so a zero there is a broken entry.
            if !name.hasPrefix("gemini/") {
                XCTAssertGreaterThan(price.input, 0, "\(name) has no input rate")
                XCTAssertGreaterThan(price.output, 0, "\(name) has no output rate")
            }
        }
    }

    /// We mark Claude's cache breakpoints, so every Claude price must carry both cache rates.
    func testEveryClaudeEntryHasCacheRates() {
        let claude = ModelPriceList.shared.prices.filter { $0.key.hasPrefix("claude") }
        XCTAssertFalse(claude.isEmpty)
        for (name, price) in claude {
            XCTAssertNotNil(price.cacheRead, "\(name) has no cache read rate")
            XCTAssertNotNil(price.cacheWrite, "\(name) has no cache write rate")
        }
    }

    func testCurrentModelsOfEachProviderResolve() {
        let list = ModelPriceList.shared
        for key in [PricingKey(provider: .anthropic, model: "claude-sonnet-4-5"),
                    PricingKey(provider: .openAI, model: "gpt-4o"),
                    PricingKey(provider: .openAI, model: "gpt-5"),
                    PricingKey(provider: .gemini, model: "gemini-2.5-pro")] {
            XCTAssertNotNil(list.price(for: key), "\(key.model) has no price in the bundled list")
        }
    }

    // MARK: - Lookup

    private let fixture = ModelPriceList(prices: [
        "claude-sonnet-4-5": ModelPrice(input: 3e-6, output: 15e-6, cacheRead: nil, cacheWrite: nil,
                                        inputAbove200k: nil, outputAbove200k: nil, cacheReadAbove200k: nil, cacheWriteAbove200k: nil),
        "gpt-4o": ModelPrice(input: 2.5e-6, output: 10e-6, cacheRead: nil, cacheWrite: nil,
                             inputAbove200k: nil, outputAbove200k: nil, cacheReadAbove200k: nil, cacheWriteAbove200k: nil),
        "gemini/gemini-2.5-flash": ModelPrice(input: 0.3e-6, output: 2.5e-6, cacheRead: nil, cacheWrite: nil,
                                              inputAbove200k: nil, outputAbove200k: nil, cacheReadAbove200k: nil, cacheWriteAbove200k: nil),
    ])

    func testADatedOrLatestNameResolvesToItsBaseModel() {
        XCTAssertNotNil(fixture.price(for: PricingKey(provider: .anthropic, model: "claude-sonnet-4-5-20250929")))
        XCTAssertNotNil(fixture.price(for: PricingKey(provider: .anthropic, model: "claude-sonnet-4-5-latest")))
        XCTAssertNotNil(fixture.price(for: PricingKey(provider: .openAI, model: "gpt-4o-2024-08-06")))
    }

    func testGeminiIsLookedUpUnderItsPrefixInEitherNameForm() {
        XCTAssertNotNil(fixture.price(for: PricingKey(provider: .gemini, model: "gemini-2.5-flash")))
        XCTAssertNotNil(fixture.price(for: PricingKey(provider: .gemini, model: "models/gemini-2.5-flash")))
        XCTAssertNil(fixture.price(for: PricingKey(provider: .openAI, model: "gemini-2.5-flash")), "the provider decides the key")
    }

    /// ⚠️ THE POINT. The hand-kept table matched families by substring and priced one generation at
    /// another's rate. A model the list doesn't name gets no price — never a near miss.
    func testAModelTheListDoesNotNameGetsNoPriceNotANearMiss() {
        for name in ["claude-sonnet-9", "claude-sonnet", "claude-sonnet-4", "gpt-4o-mini-new", "gpt-4"] {
            let provider: PricingProvider = name.hasPrefix("claude") ? .anthropic : .openAI
            XCTAssertNil(fixture.price(for: PricingKey(provider: provider, model: name)), "'\(name)' borrowed another model's price")
        }
        XCTAssertNil(ModelPriceList.shared.price(for: PricingKey(provider: .anthropic, model: "claude-sonnet-9")))
    }

    func testOpenRouterAndCustomEndpointsAreNeverLookedUp() {
        XCTAssertNil(fixture.price(for: PricingKey(provider: .openRouter, model: "gpt-4o")), "OpenRouter's own reported cost is its price")
        XCTAssertNil(fixture.price(for: PricingKey(provider: .unpriced, model: "gpt-4o")), "a self-hosted 'gpt-4o' is not OpenAI's")
    }

    // MARK: - Per-call pricing

    /// The long-context rate applies to ONE call's prompt. Two 150k calls stay at the base rate even
    /// though the run's total crosses 200k — which is why calls are priced before they are summed.
    func testTheLongContextRateAppliesPerCallNotPerRun() {
        let price = rates(input: 3e-6, output: 15e-6, inputAbove200k: 6e-6, outputAbove200k: 22.5e-6)
        XCTAssertEqual(price.cost(of: TokenUsage(inputTokens: 250_000, outputTokens: 1_000)), 250_000 * 6e-6 + 1_000 * 22.5e-6, accuracy: 1e-12)

        var run = TokenUsage()
        for _ in 0..<2 {
            let call = TokenUsage(inputTokens: 150_000, outputTokens: 1_000)
            var priced = call
            priced.costUSD = price.cost(of: call)
            run.accumulate(priced)
        }
        XCTAssertEqual(run.costUSD ?? -1, 2 * (150_000 * 3e-6 + 1_000 * 15e-6), accuracy: 1e-12)
    }

    func testAMissingCacheRateFallsBackToTheInputRate() {
        let price = rates(input: 2e-6, output: 8e-6)
        XCTAssertEqual(price.cost(of: TokenUsage(inputTokens: 1_000, outputTokens: 0, cacheReadTokens: 1_000)), 1_000 * 2e-6, accuracy: 1e-12)
    }

    // MARK: - Reported cost and wiring

    /// OpenRouter's reported cost is exact and wins over anything the list could say.
    /// Parsed from JSON text, as a response is: `JSONSerialization` yields `NSNumber`s, while a Swift
    /// literal mixing `1_000` and `0.0123` would be typed `[String: Double]` and fail the `Int` reads.
    func testAReportedCostIsTheCallsCost() throws {
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(
            #"{"usage": {"prompt_tokens": 1000, "completion_tokens": 10, "cost": 0.0123}}"#.utf8)) as? [String: Any])
        let usage = TokenUsage.fromOpenAI(json, pricing: PricingKey(provider: .openAI, model: "gpt-4o"))
        XCTAssertEqual(usage?.inputTokens, 1_000)
        XCTAssertEqual(usage?.costUSD ?? -1, 0.0123, accuracy: 1e-12, "the reported cost, not the list's gpt-4o price")
    }

    func testEachProviderPricesFromTheBundledList() throws {
        let list = ModelPriceList.shared
        let claudeKey = PricingKey(provider: .anthropic, model: "claude-sonnet-4-5")
        let claude = try XCTUnwrap(TokenUsage.fromAnthropic(["usage": ["input_tokens": 1_000, "output_tokens": 100]], pricing: claudeKey))
        XCTAssertEqual(claude.costUSD ?? -1, list.price(for: claudeKey)!.cost(of: claude), accuracy: 1e-12)

        let openAIKey = PricingKey(provider: .openAI, model: "gpt-4o")
        let openAI = try XCTUnwrap(TokenUsage.fromOpenAI(["usage": ["prompt_tokens": 1_000, "completion_tokens": 100]], pricing: openAIKey))
        XCTAssertEqual(openAI.costUSD ?? -1, list.price(for: openAIKey)!.cost(of: openAI), accuracy: 1e-12)

        let geminiKey = PricingKey(provider: .gemini, model: "gemini-2.5-pro")
        let gemini = try XCTUnwrap(TokenUsage.fromGemini(["usageMetadata": ["promptTokenCount": 1_000, "candidatesTokenCount": 100]], pricing: geminiKey))
        XCTAssertEqual(gemini.costUSD ?? -1, list.price(for: geminiKey)!.cost(of: gemini), accuracy: 1e-12)
    }

    /// Which price source each provider's calls use — decided by the provider, not the model name.
    func testEachProviderNamesItsPriceSource() {
        let config = LLMProviderConfig(apiKey: "k", baseURL: URL(string: "https://example.invalid/v1")!, modelName: "gpt-4o")
        XCTAssertEqual(ClaudeLLMProvider(config: config).pricingKey.provider, .anthropic)
        XCTAssertEqual(GeminiLLMProvider(config: config).pricingKey.provider, .gemini)
        XCTAssertEqual(OpenAILLMProvider(config: config, providerCategory: .openAI).pricingKey.provider, .openAI)
        XCTAssertEqual(OpenAILLMProvider(config: config, providerCategory: .openRouter).pricingKey.provider, .openRouter)
        XCTAssertEqual(OpenAILLMProvider(config: config, providerCategory: .openRouterFree).pricingKey.provider, .openRouter)
        XCTAssertEqual(OpenAILLMProvider(config: config, providerCategory: .openAICompatible).pricingKey.provider, .unpriced)
    }

    /// Claude's stream reports usage in two partials. The call must be priced once, whole — a priced
    /// output partial would carry no prompt size and miss the long-context rate. A live stream needs
    /// a server, so this pins the wrapper.
    func testClaudesStreamIsPricedOnceAfterItsPartialsCombine() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        guard let source = try? String(contentsOf: root.appendingPathComponent("Devgentic/Core/Backends/ClaudeLLMProvider.swift"), encoding: .utf8) else {
            throw XCTSkip("ClaudeLLMProvider.swift not reachable — running outside a checkout")
        }
        XCTAssertTrue(source.contains("return { @Sendable usage in report(usage.priced(key)) }"),
                      "the Claude stream no longer prices its combined usage")
    }

    // MARK: - Adding up a run

    func testCostsAddUpAcrossCalls() {
        var run = TokenUsage()
        run.accumulate(TokenUsage(inputTokens: 100, outputTokens: 10, costUSD: 0.01))
        run.accumulate(TokenUsage(inputTokens: 200, outputTokens: 20, costUSD: 0.02))
        XCTAssertEqual(run.costUSD ?? -1, 0.03, accuracy: 1e-12)
        XCTAssertFalse(run.costIsPartial)
    }

    func testOneUnpricedCallMakesTheTotalPartial() {
        var run = TokenUsage()
        run.accumulate(TokenUsage(inputTokens: 100, outputTokens: 10, costUSD: 0.01))
        run.accumulate(TokenUsage(inputTokens: 50, outputTokens: 5))      // e.g. an estimated synthesis call
        XCTAssertEqual(run.costUSD ?? -1, 0.01, accuracy: 1e-12, "the priced calls' cost is kept")
        XCTAssertTrue(run.costIsPartial)

        var other = TokenUsage()
        other.accumulate(TokenUsage(inputTokens: 50, outputTokens: 5))
        other.accumulate(TokenUsage(inputTokens: 100, outputTokens: 10, costUSD: 0.01))
        XCTAssertTrue(other.costIsPartial, "order must not matter")
    }

    func testARunWithNoPricedCallHasNoCostAndIsNotPartial() {
        var run = TokenUsage()
        run.accumulate(TokenUsage(inputTokens: 100, outputTokens: 10))
        run.accumulate(TokenUsage(inputTokens: 100, outputTokens: 10))
        XCTAssertNil(run.costUSD, "a local run has no cost — not a partial one")
        XCTAssertFalse(run.costIsPartial)
    }

    func testCostRoundTripsAndOldUsageDecodesWithout() throws {
        let usage = TokenUsage(inputTokens: 5, outputTokens: 6, costUSD: 0.5, costIsPartial: true)
        XCTAssertEqual(try JSONDecoder().decode(TokenUsage.self, from: JSONEncoder().encode(usage)), usage)
        let old = try JSONDecoder().decode(TokenUsage.self, from: Data(#"{"inputTokens": 1, "outputTokens": 2, "isEstimated": false}"#.utf8))
        XCTAssertNil(old.costUSD)
        XCTAssertFalse(old.costIsPartial)
    }
}
