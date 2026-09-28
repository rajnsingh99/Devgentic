// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
//
//  OpenRouterErrorPathTests.swift
//  DevgenticTests
//
//  The OpenRouter failure modes the first live test (2026-09-27) never reached: bad key, no
//  credits, rate limits (per-minute and daily), a withdrawn model, no eligible endpoint, upstream
//  5xx, an error delivered inside a 200 (body or stream), and a model that rejects tools. Bodies
//  mirror OpenRouter's documented `{"error": {"code", "message"}}` shape.
//
//  Plus the provider-hygiene fixes from the same pass: vendor-key mismatch, OpenRouter response
//  metadata, and the cloud metadata banner.
//

import XCTest
@testable import devgentic

final class OpenRouterErrorPathTests: XCTestCase {

    private func body(_ code: Int, _ message: String) -> String {
        #"{"error":{"code":\#(code),"message":"\#(message)"}}"#
    }

    private func verdict(_ status: Int, _ message: String, retryAfter: TimeInterval? = nil) -> ProviderErrorVerdict {
        ProviderErrorClassifier.classify(statusCode: status, rawBody: body(status, message), retryAfter: retryAfter)
    }

    private func assertFatal(_ v: ProviderErrorVerdict, _ category: AgentErrorCategory, contains text: String,
                             file: StaticString = #filePath, line: UInt = #line) {
        guard case .fatal(let reason, let got) = v else {
            return XCTFail("expected fatal, got \(v)", file: file, line: line)
        }
        XCTAssertEqual(got, category, file: file, line: line)
        XCTAssertTrue(reason.localizedCaseInsensitiveContains(text), "reason: \(reason)", file: file, line: line)
    }

    // MARK: - 401 / 402

    func test401_BadKey_IsFatalAuthAndNamesTheKey() {
        assertFatal(verdict(401, "No auth credentials found"), .providerAuth, contains: "API key")
    }

    func test402_OutOfCredits_IsFatalQuotaAndLinksCredits() {
        assertFatal(verdict(402, "Insufficient credits"), .providerQuotaExhausted, contains: "openrouter.ai/credits")
    }

    // MARK: - 429

    func test429_PerMinute_IsAThrottleHonouringRetryAfter() {
        guard case .throttle(let after) = verdict(429, "Rate limit exceeded: free-models-per-min.", retryAfter: 7) else {
            return XCTFail("per-minute limit must back off and retry")
        }
        XCTAssertEqual(after, 7)
    }

    /// The daily cap resets at midnight UTC — five backoff retries cannot succeed.
    func test429_DailyFreeCap_IsFatalNotRetried() {
        assertFatal(verdict(429, "Rate limit exceeded: free-models-per-day. Add 10 credits to unlock 1000 free model requests per day"),
                    .providerQuotaExhausted, contains: "daily limit")
    }

    // MARK: - Model gone / no eligible endpoint

    func test400_WithdrawnModel_IsModelNotFound() {
        assertFatal(verdict(400, "nvidia/nemotron-3-ultra-550b-a55b:free is not a valid model ID"),
                    .providerModelNotFound, contains: "no longer offers")
    }

    func test404_NoEndpointsForModel_IsModelNotFound() {
        assertFatal(verdict(404, "No endpoints found for some/model:free."), .providerModelNotFound, contains: "model name")
    }

    func test404_DataPolicy_PointsAtTheSwitchNotTheModelName() {
        let v = verdict(404, "No endpoints found matching your data policy (Free model publication). Configure: https://openrouter.ai/settings/privacy")
        assertFatal(v, .providerCapabilityMissing, contains: "Deny Data Collection")
    }

    func test404_NoToolEndpoints_IsToolsUnsupported() {
        assertFatal(verdict(404, "No endpoints found that support tool use. Try disabling \\\"list_directory\\\"."),
                    .providerCapabilityMissing, contains: "tool calling")
    }

    // MARK: - 5xx

    func test5xx_AreTransient() {
        for status in [500, 502, 503] {
            guard case .transient = verdict(status, "Upstream error") else { return XCTFail("\(status) must retry") }
        }
    }

    // MARK: - Tools rejected

    func test400_ToolsRejected_IsToolsUnsupported() {
        assertFatal(verdict(400, "tools is not supported by this model"), .providerCapabilityMissing, contains: "tool calling")
    }

    /// We never send `tool_choice` or `parallel_tool_calls`, so a rejection naming either would be
    /// a regression in the request builder, not a model limitation.
    func testRequestBodyNeverCarriesToolChoiceOrParallelFlags() {
        let provider = OpenAILLMProvider(
            config: LLMProviderConfig(apiKey: "k", baseURL: URL(string: "https://openrouter.ai/api/v1/")!, modelName: "a/b"),
            providerCategory: .openRouter)
        var body: [String: Any] = [:]
        provider.applyGenerationParams(to: &body)
        XCTAssertNil(body["tool_choice"])
        XCTAssertNil(body["parallel_tool_calls"])
    }

    // MARK: - Error inside a 200

    func testEmbeddedError_UsesItsCodeAndClassifiesLikeTheStatus() throws {
        let json: [String: Any] = ["id": "gen-1", "error": ["code": 502, "message": "Upstream died"]]
        let error = try XCTUnwrap(OpenAILLMProvider.embeddedError(in: json, provider: .openRouter))
        XCTAssertEqual(error.statusCode, 502)
        XCTAssertEqual(error.requestId, "gen-1")
        guard case .transient = ProviderErrorClassifier.classify(error) else { return XCTFail("502 must retry") }
    }

    func testEmbeddedError_StringOrMissingCodeFallsBackTo502() throws {
        XCTAssertEqual(OpenAILLMProvider.embeddedError(in: ["error": ["code": "429", "message": "x"]], provider: .openRouter)?.statusCode, 429)
        XCTAssertEqual(OpenAILLMProvider.embeddedError(in: ["error": ["message": "x"]], provider: .openRouter)?.statusCode, 502)
        XCTAssertEqual(OpenAILLMProvider.embeddedError(in: ["error": ["code": 1, "message": "x"]], provider: .openRouter)?.statusCode, 502)
    }

    func testEmbeddedError_NullOrAbsentIsNotAnError() {
        XCTAssertNil(OpenAILLMProvider.embeddedError(in: ["error": NSNull(), "choices": []], provider: .openAI))
        XCTAssertNil(OpenAILLMProvider.embeddedError(in: ["choices": []], provider: .openAI))
    }

    func testStream_ErrorChunkFailsTheStreamInsteadOfEndingCleanly() {
        let line = #"data: {"id":"gen-2","error":{"code":503,"message":"Provider returned error"},"choices":[{"delta":{"content":""},"finish_reason":"error"}]}"#
        guard case .fail(let error) = OpenAILLMProvider.streamLineDirective(line, provider: .openRouter) else {
            return XCTFail("a mid-stream error must fail the stream")
        }
        XCTAssertEqual((error as? CloudProviderError)?.statusCode, 503)
    }

    func testStream_NormalLinesStillDecode() {
        guard case .emit(let text) = OpenAILLMProvider.streamLineDirective(#"data: {"choices":[{"delta":{"content":"hi"}}]}"#, provider: .openRouter) else {
            return XCTFail("content delta must emit")
        }
        XCTAssertEqual(text, "hi")
        guard case .finish = OpenAILLMProvider.streamLineDirective("data: [DONE]", provider: .openRouter) else { return XCTFail() }
        guard case .skip = OpenAILLMProvider.streamLineDirective(": OPENROUTER PROCESSING", provider: .openRouter) else { return XCTFail() }
    }

    // MARK: - Vendor-key mismatch (item 8)

    func testKeyShape_RefusesAnotherVendorsKey() {
        XCTAssertEqual(ProviderKeyShape.mismatchedVendor(key: "sk-ant-api03-abc", provider: .openRouter), .anthropic)
        XCTAssertEqual(ProviderKeyShape.mismatchedVendor(key: "sk-or-v1-abc", provider: .anthropic), .openRouter)
        XCTAssertEqual(ProviderKeyShape.mismatchedVendor(key: "AIzaSyAbc", provider: .openAI), .google)
        XCTAssertEqual(ProviderKeyShape.mismatchedVendor(key: "sk-proj-abc", provider: .openRouter), .openAI)
    }

    func testKeyShape_NeverBlocksAmbiguousOrMatchingKeys() {
        XCTAssertNil(ProviderKeyShape.mismatchedVendor(key: "sk-or-v1-abc", provider: .openRouter))
        XCTAssertNil(ProviderKeyShape.mismatchedVendor(key: "sk-abc123", provider: .anthropic), "bare sk- names no vendor")
        XCTAssertNil(ProviderKeyShape.mismatchedVendor(key: "sk-ant-abc", provider: .openAICompatible), "gateways accept any vendor's key")
        XCTAssertNil(ProviderKeyShape.mismatchedVendor(key: "sk-ant-abc", provider: .ollama))
        XCTAssertNil(ProviderKeyShape.mismatchedVendor(key: nil, provider: .openRouter))
    }

    // MARK: - OpenRouter response metadata (item 10)

    func testRouterMetadata_NamesGenerationUpstreamAndCost() throws {
        let json: [String: Any] = [
            "id": "gen-123", "provider": "Nvidia", "model": "nvidia/nemotron",
            "usage": ["prompt_tokens": 75290, "completion_tokens": 1392, "cost": 0.0123],
        ]
        let summary = try XCTUnwrap(OpenAILLMProvider.routerMetadataSummary(json))
        XCTAssertTrue(summary.contains("generation: gen-123"), summary)
        XCTAssertTrue(summary.contains("upstream: Nvidia"), summary)
        XCTAssertTrue(summary.contains("75290 in / 1392 out"), summary)
        XCTAssertTrue(summary.contains("cost: $0.012300"), summary)
    }

    func testRouterMetadata_NilWhenNothingToSay() {
        XCTAssertNil(OpenAILLMProvider.routerMetadataSummary(["choices": []]))
    }

    func testOpenRouterRequestsAskForUsageAccounting() {
        let provider = OpenAILLMProvider(
            config: LLMProviderConfig(apiKey: "k", baseURL: URL(string: "https://openrouter.ai/api/v1/")!, modelName: "a/b"),
            providerCategory: .openRouterFree)
        var body: [String: Any] = [:]
        provider.applyGenerationParams(to: &body)
        XCTAssertEqual(body["usage"] as? [String: Bool], ["include": true])

        let openAI = OpenAILLMProvider(
            config: LLMProviderConfig(apiKey: "k", baseURL: URL(string: "https://api.openai.com/v1/")!, modelName: "gpt-4o"),
            providerCategory: .openAI)
        var openAIBody: [String: Any] = [:]
        openAI.applyGenerationParams(to: &openAIBody)
        XCTAssertNil(openAIBody["usage"], "OpenAI rejects unknown top-level keys")
    }

    // MARK: - Cloud metadata banner (item 11)

    func testMetadataSummary_CloudModelIsNotDescribedAsAFailedLocalDetection() {
        let config = ProviderConfig(apiProvider: .openRouter, modelName: "a/b:free",
                                    modelMetadata: ModelMetadata(tier: .medium, contextWindow: 1_000_000))
        let summary = AgentConnect.metadataSummary(for: config)
        XCTAssertFalse(summary.contains("unknown quant"), summary)
        XCTAssertTrue(summary.contains("cloud model"), summary)
        XCTAssertTrue(summary.contains(1_000_000.formatted() + " token window"), summary)
    }

    func testMetadataSummary_LocalModelKeepsItsDetail() {
        let config = ProviderConfig(apiProvider: .mlx, modelName: "m",
                                    modelMetadata: ModelMetadata(tier: .small, contextWindow: 8192, quantization: "4bit", family: "llama"))
        let summary = AgentConnect.metadataSummary(for: config)
        XCTAssertTrue(summary.contains("Small tier, 4bit, llama"), summary)
    }
}
