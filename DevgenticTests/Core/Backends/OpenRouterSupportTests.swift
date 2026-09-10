// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2026 Raj Singh
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
