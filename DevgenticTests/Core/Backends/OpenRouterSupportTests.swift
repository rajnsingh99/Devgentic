// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
//
//  OpenRouterSupportTests.swift
//  DevgenticTests
//
//  Created on 08/07/26.
//
//  Unit tests for OpenRouter provider support: catalog parsing/mapping,
//  402 out-of-credits classification, rate-limit bucketing, capability
//  defaults, and the validator's API-key requirement.
//

import XCTest
@testable import devgentic

final class OpenRouterSupportTests: XCTestCase {

    // MARK: - Catalog Parsing

    /// Mirrors the live /api/v1/models shape (verified 2026-07-08), including
    /// a model with null optional fields.
    private let catalogFixture = """
    {
      "data": [
        {
          "id": "zeta/minimal-model",
          "name": null,
          "context_length": null,
          "supported_parameters": null,
          "architecture": null
        },
        {
          "id": "anthropic/claude-sonnet-4.5",
          "name": "Anthropic: Claude Sonnet 4.5",
          "context_length": 1000000,
          "architecture": {
            "modality": "text+image->text",
            "input_modalities": ["text", "image"],
            "output_modalities": ["text"]
          },
          "supported_parameters": ["max_tokens", "temperature", "tools", "tool_choice"]
        },
        {
          "id": "aion-labs/aion-3.0-mini",
          "name": "AionLabs: Aion-3.0-Mini",
          "context_length": 131072,
          "architecture": {
            "modality": "text->text",
            "input_modalities": ["text"],
            "output_modalities": ["text"]
          },
          "supported_parameters": ["max_tokens", "temperature", "top_p"]
        }
      ]
    }
    """.data(using: .utf8)!

    func testParseModels_MapsCapabilityFields() throws {
        let models = try OpenRouterService.parseModels(catalogFixture)
        XCTAssertEqual(models.count, 3)

        let claude = try XCTUnwrap(models.first(where: { $0.id == "anthropic/claude-sonnet-4.5" }))
        XCTAssertTrue(claude.toolCapable, "supported_parameters contains 'tools'")
        XCTAssertTrue(claude.visionInput, "input_modalities contains 'image'")
        XCTAssertEqual(claude.contextLength, 1_000_000)
        XCTAssertEqual(claude.name, "Anthropic: Claude Sonnet 4.5")

        let aion = try XCTUnwrap(models.first(where: { $0.id == "aion-labs/aion-3.0-mini" }))
        XCTAssertFalse(aion.toolCapable, "no 'tools' in supported_parameters")
        XCTAssertFalse(aion.visionInput)
    }

    func testParseModels_NullFieldsDefaultSafely() throws {
        let models = try OpenRouterService.parseModels(catalogFixture)
        let minimal = try XCTUnwrap(models.first(where: { $0.id == "zeta/minimal-model" }))
        XCTAssertEqual(minimal.name, "zeta/minimal-model", "id is the display fallback")
        XCTAssertNil(minimal.contextLength)
        XCTAssertFalse(minimal.toolCapable)
        XCTAssertFalse(minimal.visionInput)
    }

    func testParseModels_SortedByID() throws {
        let models = try OpenRouterService.parseModels(catalogFixture)
        XCTAssertEqual(models.map(\.id), models.map(\.id).sorted())
    }

    // MARK: - 402 Out-of-Credits Classification

    func testClassifier_402_IsFatalQuotaExhausted() {
        let verdict = ProviderErrorClassifier.classify(
            statusCode: 402,
            rawBody: #"{"error":{"message":"Insufficient credits","code":402}}"#
        )
        guard case .fatal(let reason, let category) = verdict else {
            return XCTFail("402 must be fatal (deterministic until top-up), got \(verdict)")
        }
        XCTAssertEqual(category, .providerQuotaExhausted)
        XCTAssertTrue(reason.contains("credits"), "reason should point at credits: \(reason)")
    }

    func testFormatHTTPError_402_MentionsCredits() {
        let message = LLMProviderError.formatHTTPError(status: 402, body: #"{"error":{"message":"Insufficient credits"}}"#)
        XCTAssertTrue(message.contains("credits"))
    }

    // MARK: - Provider Plumbing

    func testProviderClass_OpenRouterIsCloud() {
        XCTAssertEqual(ProviderClass(apiProvider: .openRouter), .cloud)
    }

    func testDeriveBucketKey_OpenRouterIsKeyScoped() {
        let key = RateLimitCategory.deriveBucketKey(provider: .openRouter, apiKey: "sk-or-abc", baseURL: nil)
        XCTAssertTrue(key.hasPrefix("openRouter:"), "own category bucket, key-scoped: \(key)")
        XCTAssertNotEqual(
            key,
            RateLimitCategory.deriveBucketKey(provider: .openRouter, apiKey: "sk-or-other", baseURL: nil),
            "different keys must not share a quota bucket"
        )
    }

    func testFreeModel_GetsItsOwnTighterCategory() {
        XCTAssertEqual(RateLimitCategory.from(provider: .openRouter, modelName: "nvidia/nemotron-3-ultra-550b-a55b:free"), .openRouterFree)
        XCTAssertEqual(RateLimitCategory.from(provider: .openRouter, modelName: "Some/Model:FREE "), .openRouterFree)
        XCTAssertEqual(RateLimitCategory.from(provider: .openRouter, modelName: "anthropic/claude-sonnet-5"), .openRouter)
        XCTAssertEqual(RateLimitCategory.from(provider: .openRouter), .openRouter, "no model name → paid defaults")
        XCTAssertEqual(RateLimitCategory.from(provider: .openAI, modelName: "x:free"), .openAI, ":free means nothing outside OpenRouter")
        XCTAssertEqual(RateLimitCategory.openRouterFree.defaultTokensPerSecond * 60, 20, accuracy: 0.001)
        XCTAssertLessThan(RateLimitCategory.openRouterFree.defaultMaxBurst, RateLimitCategory.openRouter.defaultMaxBurst)
    }

    func testFreeModel_DoesNotShareABucketWithPaidModelsOnTheSameKey() {
        let free = RateLimitCategory.deriveBucketKey(provider: .openRouter, apiKey: "sk-or-abc", baseURL: nil, modelName: "a/b:free")
        let paid = RateLimitCategory.deriveBucketKey(provider: .openRouter, apiKey: "sk-or-abc", baseURL: nil, modelName: "a/b")
        XCTAssertTrue(free.hasPrefix("openRouterFree:"), free)
        XCTAssertTrue(paid.hasPrefix("openRouter:"), paid)
        XCTAssertNotEqual(free, paid, "whichever call creates a bucket fixes its rate, so the two must never collide")
    }

    // MARK: - Deny Data Collection

    private func provider(_ category: RateLimitCategory, options: [String: JSONValue]?) -> OpenAILLMProvider {
        OpenAILLMProvider(
            config: LLMProviderConfig(apiKey: "k", baseURL: URL(string: "https://openrouter.ai/api/v1/")!,
                                      modelName: "a/b:free", options: options),
            providerCategory: category)
    }

    func testDenyDataCollection_OffByDefault() {
        var body: [String: Any] = [:]
        provider(.openRouterFree, options: nil).applyGenerationParams(to: &body)
        XCTAssertNil(body["provider"])
        XCTAssertNil(OpenAIAdvancedConfig.default().denyDataCollection)
    }

    func testDenyDataCollection_SentToOpenRouterPaidAndFree() {
        for category in [RateLimitCategory.openRouter, .openRouterFree] {
            var body: [String: Any] = [:]
            provider(category, options: ["denyDataCollection": .bool(true)]).applyGenerationParams(to: &body)
            XCTAssertEqual(body["provider"] as? [String: String], ["data_collection": "deny"], "\(category)")
        }
    }

    func testDenyDataCollection_NeverSentToOtherEndpoints() {
        for category in [RateLimitCategory.openAI, .openAICompatible] {
            var body: [String: Any] = [:]
            provider(category, options: ["denyDataCollection": .bool(true)]).applyGenerationParams(to: &body)
            XCTAssertNil(body["provider"], "\(category)")
        }
    }

    /// The panel's value must survive the encode path the profile actually uses (Codable →
    /// JSONSerialization → JSONValue) as `.bool`, or the provider's pattern match drops it.
    func testDenyDataCollection_SurvivesTheProfileEncodePath() throws {
        var config = OpenAIAdvancedConfig.default()
        config.denyDataCollection = true
        let data = try JSONEncoder().encode(config)
        let dict = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(JSONValue(dict["denyDataCollection"] as Any), .bool(true))
    }

    func testDenyDataCollection_OldConfigsDecodeAsOff() throws {
        let old = #"{"temperature":1.0,"reasoningEffort":"low"}"#.data(using: .utf8)!
        let decoded = try JSONDecoder().decode(OpenAIAdvancedConfig.self, from: old)
        XCTAssertNil(decoded.denyDataCollection)
        XCTAssertEqual(decoded.reasoningEffort, "low")
    }

    func testDataPolicy404_PointsAtTheSwitch() {
        let body = #"{"error":{"message":"No endpoints found matching your data policy (Free model publication). Configure: https://openrouter.ai/settings/privacy","code":404}}"#
        let message = LLMProviderError.formatHTTPError(status: 404, body: body)
        XCTAssertTrue(message.contains("Deny Data Collection"), message)
    }

    // MARK: - Secrets in logs

    func testProviderConfigDescription_NeverContainsTheKey() {
        let secret = "gw-live-7f3c9a1e22b04d6f8e5a" // no vendor prefix — TelemetrySanitizer would miss it
        let config = LLMProviderConfig(apiKey: secret, baseURL: URL(string: "https://openrouter.ai/api/v1/")!, modelName: "a/b:free")
        let provider = OpenAILLMProvider(config: config, providerCategory: .openRouterFree)
        for rendered in [String(describing: config), String(reflecting: config), String(describing: provider)] {
            XCTAssertFalse(rendered.contains(secret), "key leaked: \(rendered)")
            XCTAssertTrue(rendered.contains("set (\(secret.count) chars)"), rendered)
        }
    }

    func testDefaultCognitiveCapability_OpenRouterAgent() {
        XCTAssertEqual(
            ProfileCapabilityFilter.defaultCognitiveCapability(for: .agent, provider: .openRouter),
            .parallelActions
        )
        XCTAssertEqual(
            ProfileCapabilityFilter.defaultCognitiveCapability(for: .bot, provider: .openRouter),
            .none
        )
    }

    // MARK: - Validation

    func testValidator_OpenRouterRequiresAPIKey() {
        let missingKey = makeBot(provider: .openRouter, apiKey: nil)
        XCTAssertTrue(
            ProfileValidator.validate(missingKey, strict: true).contains(where: { $0.field == "apiKey" }),
            "openRouter without a key must fail strict validation"
        )

        let withKey = makeBot(provider: .openRouter, apiKey: "sk-or-abc")
        XCTAssertFalse(
            ProfileValidator.validate(withKey, strict: true).contains(where: { $0.field == "apiKey" })
        )
    }

    // MARK: - Helpers

    private func makeBot(provider: ApiProvider, apiKey: String?) -> BackendProfileSnapshot {
        let llmConfig = ProviderConfig(
            apiProvider: provider,
            modelName: "anthropic/claude-sonnet-4.5",
            apiKey: apiKey
        )
        var config = BotConfig(llmConfig: llmConfig)
        config.instructions = "You are a helpful assistant."
        return BackendProfileSnapshot(displayName: "OpenRouter Bot", details: .bot(config))
    }
}
