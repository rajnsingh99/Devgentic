//
//  ProviderConfigSwitchProviderTests.swift
//  DevgenticTests
//
//  Created on 06/07/26.
//
//  Unit tests for ProviderConfig.switchProvider(to:) — the provider-switch
//  re-baseline that prevents stale provider-scoped settings (endpoint, model,
//  analyzer artifacts, advanced params) from leaking into the new provider.
//

import XCTest
@testable import devgentic

final class ProviderConfigSwitchProviderTests: XCTestCase {

    /// A fully-populated local (Ollama) config, as it would look after the
    /// analyzers and advanced-config UI have all written into it.
    private func makeSeasonedOllamaConfig() -> ProviderConfig {
        ProviderConfig(
            apiProvider: .ollama,
            modelName: "llama3.1:8b",
            apiKey: nil,
            baseURL: "http://localhost:11434",
            advancedConfiguration: ["temperature": .number(0.2)],
            cognitiveCapability: .singleAction,
            modelDialect: .mistralXML,
            chatTemplateSource: .extracted("{{ jinja }}"),
            stopSequences: ["</s>"],
            thinkingEnabled: true,
            supportedModalities: .visionCapable
        )
    }

    // MARK: - The setup-breaking case: Ollama → OpenAI

    func testSwitchOllamaToOpenAI_ClearsStaleLocalhostBaseURL() {
        var config = makeSeasonedOllamaConfig()
        config.switchProvider(to: .openAI)

        XCTAssertEqual(config.apiProvider, .openAI)
        XCTAssertNil(config.baseURL,
                     "Stale Ollama localhost baseURL must not survive a switch to a cloud provider — runtime would POST chat/completions at Ollama")
    }

    func testSwitchOllamaToOpenAI_ResetsAllProviderScopedFields() {
        var config = makeSeasonedOllamaConfig()
        config.switchProvider(to: .openAI)

        XCTAssertEqual(config.modelName, "", "A local model name is meaningless on the new provider")
        XCTAssertNil(config.advancedConfiguration,
                     "Shared param keys (temperature etc.) from the old provider must not silently apply to the new one")
        XCTAssertEqual(config.cognitiveCapability, .none)
        XCTAssertEqual(config.modelDialect, .nativeJSON)
        XCTAssertNil(config.modelMetadata)
        XCTAssertEqual(config.chatTemplateSource, .embedded)
        XCTAssertEqual(config.stopSequences, [])
        XCTAssertFalse(config.thinkingEnabled)
        XCTAssertEqual(config.supportedModalities, .textOnly)
    }

    // MARK: - API key survival

    func testSwitchPreservesAPIKey() {
        var config = ProviderConfig(
            apiProvider: .openAI,
            modelName: "gpt-4o-mini",
            apiKey: "sk-test-123",
            baseURL: nil
        )
        config.switchProvider(to: .anthropic)

        XCTAssertEqual(config.apiKey, "sk-test-123",
                       "Switching providers must not destroy a pasted secret — a mismatched key fails visibly in the model-list fetch")
    }

    // MARK: - Cloud → cloud custom endpoint

    func testSwitchCloudToCloud_ClearsCustomEndpoint() {
        var config = ProviderConfig(
            apiProvider: .openAI,
            modelName: "gpt-4o",
            apiKey: "sk-test-123",
            baseURL: "https://my-litellm-gateway.example.com/v1/"
        )
        config.switchProvider(to: .google)

        XCTAssertNil(config.baseURL,
                     "A gateway URL configured for one provider must not be sent traffic for another")
        XCTAssertEqual(config.modelName, "")
    }

    // MARK: - Reset matches a fresh config (minus the key)

    func testSwitchedConfigMatchesFreshConfigExceptKey() {
        var switched = makeSeasonedOllamaConfig()
        switched.apiKey = "sk-test-123"
        switched.switchProvider(to: .openAI)

        var fresh = ProviderConfig(apiProvider: .openAI, modelName: "")
        fresh.apiKey = "sk-test-123"

        XCTAssertEqual(switched, fresh,
                       "switchProvider(to:) must equal a fresh config for the new provider plus the preserved key — if this fails, a new ProviderConfig field was added without deciding its switch behavior")
    }
}
