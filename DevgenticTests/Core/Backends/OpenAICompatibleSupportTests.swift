// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2026 Raj Singh
//
//  OpenAICompatibleSupportTests.swift
//  DevgenticTests
//
//  Created on 09/07/26.
//
//  Unit tests for the custom OpenAI-compatible provider: unfiltered model-id
//  parsing, cloud resilience class, baseURL-scoped rate bucketing, capability
//  defaults, and the validator's baseURL-required / key-optional rules.
//

import XCTest
@testable import devgentic

final class OpenAICompatibleSupportTests: XCTestCase {

    // MARK: - Model-ID Parsing (unfiltered)

    /// Mirrors an LM Studio / vLLM `/v1/models` response — arbitrary ids that the
    /// OpenAI gpt/o1/o3 filter would wrongly drop.
    private let catalogFixture = """
    {
      "object": "list",
      "data": [
        { "id": "qwen2.5-coder-32b-instruct", "object": "model" },
        { "id": "deepseek-r1-distill-qwen-7b", "object": "model" },
        { "id": "llama-3.3-70b-instruct", "object": "model" }
      ]
    }
    """.data(using: .utf8)!

    func testParseModelIDs_KeepsArbitraryNames_Sorted() throws {
        let ids = try OpenAICompatibleService.parseModelIDs(catalogFixture)
        XCTAssertEqual(ids, [
            "deepseek-r1-distill-qwen-7b",
            "llama-3.3-70b-instruct",
            "qwen2.5-coder-32b-instruct"
        ], "no gpt/o1/o3 filter; ids returned sorted")
    }

    func testParseModelIDs_EmptyCatalog() throws {
        let empty = #"{"object":"list","data":[]}"#.data(using: .utf8)!
        XCTAssertEqual(try OpenAICompatibleService.parseModelIDs(empty), [])
    }

    // MARK: - Resilience / Rate Limiting

    func testProviderClass_CompatibleIsCloud() {
        XCTAssertEqual(ProviderClass(apiProvider: .openAICompatible), .cloud)
    }

    func testRateLimitCategory_MapsToOwnBucket() {
        XCTAssertEqual(RateLimitCategory.from(provider: .openAICompatible), .openAICompatible)
    }

    /// The endpoint is the quota boundary, and the key is often absent, so the
    /// bucket must be keyed by baseURL — two endpoints must not share a bucket,
    /// and a missing key must not collapse all endpoints into one.
    func testDeriveBucketKey_ScopedByBaseURL_NotKey() {
        let lmStudio = RateLimitCategory.deriveBucketKey(provider: .openAICompatible, apiKey: nil, baseURL: "http://localhost:1234/v1")
        let vllm = RateLimitCategory.deriveBucketKey(provider: .openAICompatible, apiKey: nil, baseURL: "http://localhost:8000/v1")

        XCTAssertTrue(lmStudio.hasPrefix("openAICompatible:"))
        XCTAssertNotEqual(lmStudio, vllm, "different endpoints (both keyless) must not share a bucket")

        // Same endpoint, with/without a key → same bucket (endpoint is the boundary).
        let lmStudioWithKey = RateLimitCategory.deriveBucketKey(provider: .openAICompatible, apiKey: "sk-local", baseURL: "http://localhost:1234/v1")
        XCTAssertEqual(lmStudio, lmStudioWithKey)
    }

    // MARK: - Capability Defaults

    func testDefaultCognitiveCapability_CompatibleAgent() {
        XCTAssertEqual(
            ProfileCapabilityFilter.defaultCognitiveCapability(for: .agent, provider: .openAICompatible),
            .parallelActions
        )
    }

    // MARK: - Validation (baseURL required, key optional)

    func testValidator_RequiresBaseURL() {
        let noURL = makeBot(baseURL: nil, apiKey: nil)
        XCTAssertTrue(
            ProfileValidator.validate(noURL, strict: true).contains(where: { $0.field == "baseURL" }),
            "openAICompatible without a base URL must fail"
        )
    }

    func testValidator_KeyIsOptional() {
        let urlNoKey = makeBot(baseURL: "http://localhost:1234/v1", apiKey: nil)
        let errors = ProfileValidator.validate(urlNoKey, strict: true)
        XCTAssertFalse(
            errors.contains(where: { $0.field == "apiKey" }),
            "a custom endpoint must NOT require an API key"
        )
        XCTAssertFalse(
            errors.contains(where: { $0.field == "baseURL" }),
            "a valid base URL should satisfy the baseURL rule"
        )
    }

    // MARK: - Helpers

    private func makeBot(baseURL: String?, apiKey: String?) -> BackendProfileSnapshot {
        let llmConfig = ProviderConfig(
            apiProvider: .openAICompatible,
            modelName: "qwen2.5-coder-32b-instruct",
            apiKey: apiKey,
            baseURL: baseURL
        )
        var config = BotConfig(llmConfig: llmConfig)
        config.instructions = "You are a helpful assistant."
        return BackendProfileSnapshot(displayName: "Local LM Studio", details: .bot(config))
    }
}
