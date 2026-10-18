// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
//
//  EndpointAndReasoningGatingTests.swift
//  DevgenticTests
//
//  Created by Raj Singh.
//

import XCTest
@testable import devgentic

// MARK: - A52: transport security

final class EndpointTransportSecurityTests: XCTestCase {

    private let key = "sk-secret"

    // MARK: The case that must NOT warn

    /// ⚠️ Ollama's default endpoint. A warning here would fire on the app's own out-of-the-box
    /// local setup, which is how a security warning becomes noise everyone learns to ignore.
    func testLocalhostIsNotAWarning() {
        XCTAssertEqual(EndpointTransportSecurity.evaluate(baseURL: "http://localhost:11434", apiKey: nil), .fine)
    }

    /// LM Studio's default. The whole 127/8 block is loopback, not just 127.0.0.1.
    func testTheLoopbackBlockIsNotAWarning() {
        for host in ["127.0.0.1", "127.0.1.1", "[::1]"] {
            XCTAssertEqual(
                EndpointTransportSecurity.evaluate(baseURL: "http://\(host):1234/v1", apiKey: key), .fine,
                "\(host) never leaves the machine")
        }
    }

    func testHTTPSIsNeverAWarning() {
        XCTAssertEqual(EndpointTransportSecurity.evaluate(baseURL: "https://api.openai.com/v1", apiKey: key), .fine)
    }

    func testNoEndpointIsNotAWarning() {
        XCTAssertEqual(EndpointTransportSecurity.evaluate(baseURL: nil, apiKey: key), .fine)
        XCTAssertEqual(EndpointTransportSecurity.evaluate(baseURL: "   ", apiKey: key), .fine)
    }

    // MARK: The A52 case

    /// The register's scenario: `Authorization: Bearer <key>` over unencrypted HTTP to a host that
    /// is not this machine.
    func testPlainHTTPToARemoteHostWithAKeyIsFlagged() {
        XCTAssertEqual(
            EndpointTransportSecurity.evaluate(baseURL: "http://gateway.internal/v1", apiKey: key),
            .credentialInClear(host: "gateway.internal"))
    }

    /// Without a key the credential is not at risk, but the prompts still are — a different, lesser
    /// warning rather than silence.
    func testPlainHTTPToARemoteHostWithoutAKeyIsStillFlagged() {
        XCTAssertEqual(
            EndpointTransportSecurity.evaluate(baseURL: "http://192.168.1.50:8080/v1", apiKey: nil),
            .trafficInClear(host: "192.168.1.50"))
        XCTAssertEqual(
            EndpointTransportSecurity.evaluate(baseURL: "http://192.168.1.50:8080/v1", apiKey: "   "),
            .trafficInClear(host: "192.168.1.50"),
            "whitespace is not a credential")
    }

    /// ⚠️ `.local` is mDNS: it resolves to a real LAN address and the traffic crosses the network
    /// like any other. It is deliberately not treated as loopback.
    func testAnMDNSHostIsNotTreatedAsLoopback() {
        XCTAssertEqual(
            EndpointTransportSecurity.evaluate(baseURL: "http://workstation.local:1234/v1", apiKey: key),
            .credentialInClear(host: "workstation.local"))
    }

    // MARK: The message

    func testTheWarningNamesTheHostAndOnlyAppearsWhenThereIsAProblem() throws {
        XCTAssertNil(EndpointTransportSecurity.warning(for: .fine))

        let message = try XCTUnwrap(EndpointTransportSecurity.warning(for: .credentialInClear(host: "gateway.internal")))
        XCTAssertTrue(message.contains("gateway.internal"),
                      "a warning the user cannot tie to a host is not actionable")
    }

    /// ⚠️ Advisory, never blocking — `http://localhost` is how the local providers work, so
    /// refusing the save would break the app's own defaults.
    func testTheValidatorTreatsItAsAdvisoryNotBlocking() {
        let profile = BackendProfileSnapshot(
            displayName: "Gateway",
            details: .bot(BotConfig(llmConfig: ProviderConfig(
                apiProvider: .openAICompatible,
                modelName: "llama3",
                apiKey: "sk-secret",
                baseURL: "http://gateway.internal/v1"))))

        // ⚠️ `strict: true` — provider details are only validated on an UPDATE
        // (`BackendProfileStore` passes `strict: isUpdate`), because a profile has no endpoint at
        // creation time. That is the right seam: the rule fires on every save of a configured
        // profile.
        let findings = ProfileValidator.validate(profile, strict: true)
        let transport = findings.filter { $0.field == "baseURL" && $0.severity == .advisory }

        XCTAssertEqual(transport.count, 1, "the rule must fire")
        XCTAssertFalse(findings.contains { $0.field == "baseURL" && $0.severity == .blocking },
                       "it must never refuse the save — a self-hosted LAN gateway is a legitimate choice")
    }

    /// Creation does not validate provider details at all, so an endpoint typed in the New Profile
    /// sheet cannot trip this. Documented so the strict-only placement is not read as a miss.
    func testCreationValidationDoesNotEvaluateTheEndpoint() {
        let profile = BackendProfileSnapshot(
            displayName: "Gateway",
            details: .bot(BotConfig(llmConfig: ProviderConfig(
                apiProvider: .openAICompatible,
                modelName: "llama3",
                apiKey: "sk-secret",
                baseURL: "http://gateway.internal/v1"))))

        XCTAssertTrue(ProfileValidator.validate(profile, strict: false).isEmpty)
    }

    func testTheValidatorStaysQuietForALocalProfile() {
        let profile = BackendProfileSnapshot(
            displayName: "Local",
            details: .bot(BotConfig(
                llmConfig: ProviderConfig(
                    apiProvider: .ollama,
                    modelName: "llama3",
                    baseURL: "http://localhost:11434"),
                // ⚠️ Present so this stays a test about the TRANSPORT rule. Strict validation also
                // reports missing instructions now (register A35), and asserting an empty array
                // would quietly make this a test of two unrelated rules.
                instructions: "Be helpful.")))

        XCTAssertTrue(ProfileValidator.validate(profile, strict: true).isEmpty)
    }
}

// MARK: - A55: OpenAI request shape

final class OpenAIModelFamilyTests: XCTestCase {

    func testTheOSeriesIsReasoning() {
        for id in ["o1", "o1-mini", "o3", "o3-mini", "o3-mini-2025-01-31", "o4-mini"] {
            XCTAssertEqual(OpenAIModelFamily.classify(modelName: id), .reasoning, id)
        }
    }

    func testTheGPT5SeriesIsReasoning() {
        XCTAssertEqual(OpenAIModelFamily.classify(modelName: "gpt-5"), .reasoning)
        XCTAssertEqual(OpenAIModelFamily.classify(modelName: "gpt-5-mini"), .reasoning)
    }

    /// ⚠️ OpenRouter ids carry a vendor prefix. Matching the raw string would classify every
    /// OpenRouter reasoning model as standard and send it `max_tokens`.
    func testAVendorPrefixIsStripped() {
        XCTAssertEqual(OpenAIModelFamily.classify(modelName: "openai/o3-mini"), .reasoning)
    }

    func testOrdinaryModelsAreStandard() {
        for id in ["gpt-4o", "gpt-4o-mini", "gpt-4-turbo"] {
            XCTAssertEqual(OpenAIModelFamily.classify(modelName: id), .standard, id)
        }
    }

    /// ⚠️ The false positive that matters. This provider also serves LM Studio, vLLM and llama.cpp,
    /// where a model can be called anything — a bare `hasPrefix("o1")` would sweep these in and send
    /// them a request shape they reject.
    func testNameLookalikesAreNotMistakenForReasoningModels() {
        for id in ["orca-2-13b", "olmo-7b", "o1llama-fun", "openhermes-2.5"] {
            XCTAssertEqual(OpenAIModelFamily.classify(modelName: id), .standard, id)
        }
    }

    /// ⚠️ Deliberately the OPPOSITE of `AnthropicModelGeneration`, which treats an unknown id as the
    /// newest family. Anthropic ids come from a first-party model list, so unknown means newer; here
    /// an id can be anything at all, and `.standard` is the shape every endpoint accepts.
    func testAnUnknownModelIsStandardNotReasoning() {
        XCTAssertEqual(OpenAIModelFamily.classify(modelName: "some-local-finetune-v3"), .standard)
        XCTAssertEqual(OpenAIModelFamily.classify(modelName: ""), .standard)
    }

    // MARK: The contract each family implies

    func testReasoningModelsUseMaxCompletionTokensAndRejectSampling() {
        let family = OpenAIModelFamily.reasoning
        XCTAssertEqual(family.maxTokensParameterName, "max_completion_tokens")
        XCTAssertFalse(family.acceptsSamplingParameters)
        XCTAssertTrue(family.acceptsReasoningEffort)
    }

    func testStandardModelsUseMaxTokensAndRejectReasoningEffort() {
        let family = OpenAIModelFamily.standard
        XCTAssertEqual(family.maxTokensParameterName, "max_tokens")
        XCTAssertTrue(family.acceptsSamplingParameters)
        XCTAssertFalse(family.acceptsReasoningEffort,
                       "sending reasoning_effort to a normal model fails the whole request")
    }
}
