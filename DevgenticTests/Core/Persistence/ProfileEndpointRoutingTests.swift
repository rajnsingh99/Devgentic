// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
//
//  ProfileEndpointRoutingTests.swift
//  DevgenticTests
//
//  Created on 08/08/26.
//
//  Register B21 / B22 — a profile's configured API Endpoint must be the host its credential goes
//  to, on every path that carries the credential.
//
//  ⚠️ The whole cluster is one failure: a user points a profile at a corporate gateway, is issued a
//  key scoped to that gateway, and the app sends that key to the vendor anyway. It reached the
//  vendor three different ways — a hardcoded host in the imageGen provider, a hardcoded host in the
//  text-gen provider factory, and an endpoint string that failed to parse and silently degraded to
//  "not configured". Each is asserted separately below because each was a separate omission.
//
//  B22's guard (`ConfiguredEndpoint`) and its tests were deleted on 2026-10-09 with the per-provider
//  model pickers, its only callers. The model catalog that replaced them fetches from a typed
//  endpoint only for Ollama and OpenAI-compatible servers, and both loaders refuse one that fails
//  `ProviderDefaults.isUsableEndpoint` (asserted below); its cloud lists are built in — no fetch.
//

import XCTest
@testable import devgentic

// MARK: - B21: the configured host reaches the request builders

final class ImageGenEndpointRoutingTests: XCTestCase {

    private let gateway = "https://ai-gw.corp.example.com/v1beta/"

    /// The defect: `GeminiImageGenService` had no `baseURL` property at all, so the factory had
    /// nowhere to pass `config.baseURL` and both request builders hardcoded the vendor host.
    func testGeminiImageProviderCarriesTheConfiguredEndpoint() throws {
        let config = ProviderConfig(apiProvider: .google,
                                    modelName: "gemini-2.5-flash-image",
                                    apiKey: "gateway-scoped-key",
                                    baseURL: gateway)

        let provider = try ImageGenProviderFactory.create(for: config)
        let gemini = try XCTUnwrap(provider as? GeminiImageGenService,
                                   "a .google imageGen config must build the Gemini provider")

        XCTAssertEqual(gemini.baseURL, gateway,
                       "the profile's endpoint must reach the provider — hardcoding the vendor host "
                       + "sends a gateway-scoped key to Google")
    }

    /// An unset endpoint is the ordinary case and must still work: nil here means "the service
    /// applies its own ProviderDefaults value", not "no host".
    func testGeminiImageProviderWithoutAnEndpointUsesTheDefault() throws {
        let config = ProviderConfig(apiProvider: .google, modelName: "gemini-2.5-flash-image", apiKey: "k")
        let gemini = try XCTUnwrap(try ImageGenProviderFactory.create(for: config) as? GeminiImageGenService)
        XCTAssertNil(gemini.baseURL)
    }

    func testOpenAIImageProviderCarriesTheConfiguredEndpoint() throws {
        let config = ProviderConfig(apiProvider: .openAI,
                                    modelName: "gpt-image-1",
                                    apiKey: "gateway-scoped-key",
                                    baseURL: "https://ai-gw.corp.example.com/v1/")
        let openAI = try XCTUnwrap(try ImageGenProviderFactory.create(for: config) as? OpenAIImageGenService)
        XCTAssertEqual(openAI.baseURL, "https://ai-gw.corp.example.com/v1/")
    }
}

// MARK: - B21: the shared resolver

final class ResolvedBaseURLTests: XCTestCase {

    func testAConfiguredEndpointWins() {
        let resolved = ProviderDefaults.resolvedBaseURL(configured: "https://gw.example.com/v1/",
                                                        fallback: ProviderDefaults.geminiBaseURL)
        XCTAssertEqual(resolved.absoluteString, "https://gw.example.com/v1/")
    }

    func testNilAndBlankFallBack() {
        XCTAssertEqual(ProviderDefaults.resolvedBaseURL(configured: nil, fallback: ProviderDefaults.geminiBaseURL),
                       ProviderDefaults.geminiBaseURL)
        XCTAssertEqual(ProviderDefaults.resolvedBaseURL(configured: "   ", fallback: ProviderDefaults.geminiBaseURL),
                       ProviderDefaults.geminiBaseURL)
    }

    /// ⚠️ `OpenAIImageGenService` did `URL(string: base)!` on a free-text field. Anything a user
    /// could type into it that is not a URL was a crash on the first generate, not an error.
    func testAnUnusableEndpointFallsBackInsteadOfCrashing() {
        for junk in ["my gateway", "not a url at all", "/relative/only", "gw.example.com"] {
            let resolved = ProviderDefaults.resolvedBaseURL(configured: junk,
                                                            fallback: ProviderDefaults.openAIBaseURL)
            XCTAssertEqual(resolved, ProviderDefaults.openAIBaseURL,
                           "'\(junk)' must degrade to the default, not trap")
        }
    }

    /// A bare host with no scheme is the commonest paste error, and `URL(string:)` accepts it —
    /// producing a URL with no host that `URLSession` cannot use. It must be rejected here.
    func testASchemelessHostIsTreatedAsUnusable() {
        let resolved = ProviderDefaults.resolvedBaseURL(configured: "api.openai.com/v1",
                                                        fallback: ProviderDefaults.openAIBaseURL)
        XCTAssertEqual(resolved, ProviderDefaults.openAIBaseURL)
    }

    /// ⚠️ Written after the first version of this guard let two of these through. `URL(string:)`
    /// is far looser than "usable": `"://nope"` yields an EMPTY scheme with a host, and
    /// `"http:///v1"` yields a scheme with NO host — a `scheme != nil, host != nil` test passes
    /// both, and `URLSession` then fails on an endpoint the UI had accepted.
    func testTheUsabilityPredicateRejectsWhatURLStringAccepts() {
        XCTAssertFalse(ProviderDefaults.isUsableEndpoint(URL(string: "://nope")!),
                       "an empty scheme is not a scheme")
        XCTAssertFalse(ProviderDefaults.isUsableEndpoint(URL(string: "http:///v1")!),
                       "a scheme with no host cannot be dispatched")
        XCTAssertFalse(ProviderDefaults.isUsableEndpoint(URL(string: "file:///Users/me/keys.txt")!),
                       "a pasted file path is not an API endpoint")
        XCTAssertTrue(ProviderDefaults.isUsableEndpoint(URL(string: "https://gw.example.com/v1/")!))
        XCTAssertTrue(ProviderDefaults.isUsableEndpoint(URL(string: "HTTPS://GW.EXAMPLE.COM/v1/")!),
                      "scheme comparison is case-insensitive")
    }

    /// ⚠️ `http://localhost` is how Ollama and LM Studio work, and A52 chose to WARN about
    /// plaintext transport rather than block it. Rejecting http here would have quietly
    /// re-litigated that decision from a different file.
    func testPlainHTTPRemainsUsable() {
        XCTAssertTrue(ProviderDefaults.isUsableEndpoint(URL(string: "http://localhost:1234/v1")!))
        XCTAssertEqual(ProviderDefaults.resolvedBaseURL(configured: "http://localhost:1234/v1",
                                                        fallback: ProviderDefaults.openAIBaseURL).absoluteString,
                       "http://localhost:1234/v1")
    }
}
