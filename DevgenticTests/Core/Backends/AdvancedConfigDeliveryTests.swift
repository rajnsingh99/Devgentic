// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
//
//  AdvancedConfigDeliveryTests.swift
//  DevgenticTests
//
//  Created on 07/08/26.
//
//  Regression tests for the "the panel says X, the request does Y" cluster (register A9, A19,
//  A24, A25).
//
//  ⚠️ The shared shape: a setting the Advanced panel presents as live, which no request ever
//  carried. None of these failed loudly — the user saw a configured value, got unconfigured
//  behaviour, and had nothing to correlate. A19 is the worst of them because the dead knob was a
//  SAFETY control.
//

import XCTest
@testable import devgentic

// MARK: - A19: Gemini safety settings must reach the request

final class GeminiSafetySettingsTests: XCTestCase {

    private func provider(safety: [[String: String]]?, extras: [String: JSONValue] = [:]) -> GeminiLLMProvider {
        var options = extras
        if let safety {
            options["safetySettings"] = .array(safety.map { entry in
                .object(entry.mapValues { JSONValue.string($0) })
            })
        }
        return GeminiLLMProvider(config: LLMProviderConfig(
            apiKey: "k",
            baseURL: URL(string: "https://generativelanguage.googleapis.com/v1beta/models/gemini")!,
            modelName: "gemini-2.0-flash",
            options: options
        ))
    }

    private func body(_ p: GeminiLLMProvider) -> [String: Any] {
        p.debugRequestBody(messages: [["role": "user", "content": "hi"]], tools: nil)
    }

    /// ⚠️ The defect: four pickers, no reader. A user setting every category to BLOCK_NONE to get
    /// past a refusal on legitimate work still had the account defaults applied.
    func testConfiguredThresholdsAreSentTopLevel() throws {
        let p = provider(safety: [
            ["category": "HARM_CATEGORY_HARASSMENT", "threshold": "BLOCK_NONE"],
            ["category": "HARM_CATEGORY_HATE_SPEECH", "threshold": "BLOCK_LOW_AND_ABOVE"],
        ])
        let sent = try XCTUnwrap(body(p)["safetySettings"] as? [[String: String]])

        XCTAssertEqual(sent.count, 2)
        XCTAssertEqual(sent.first { $0["category"] == "HARM_CATEGORY_HARASSMENT" }?["threshold"],
                       "BLOCK_NONE")
        XCTAssertEqual(sent.first { $0["category"] == "HARM_CATEGORY_HATE_SPEECH" }?["threshold"],
                       "BLOCK_LOW_AND_ABOVE")
    }

    /// ⚠️ `safetySettings` is a SIBLING of `generationConfig`, not a field inside it. Nesting it
    /// would be silently ignored by the API — the same class of failure as omitting it.
    func testSafetySettingsAreNotNestedInsideGenerationConfig() throws {
        let p = provider(safety: [["category": "HARM_CATEGORY_HARASSMENT", "threshold": "BLOCK_NONE"]],
                         extras: ["temperature": .number(0.5)])
        let sent = body(p)

        XCTAssertNotNil(sent["safetySettings"])
        let generationConfig = try XCTUnwrap(sent["generationConfig"] as? [String: Any])
        XCTAssertNil(generationConfig["safetySettings"])
        XCTAssertEqual(generationConfig["temperature"] as? Double, 0.5)
    }

    /// The app's "Default" option maps to the wire's UNSPECIFIED value; pinning that is not the
    /// same as leaving the category alone, so the entry is omitted instead.
    func testUnspecifiedThresholdsAreOmittedRatherThanPinned() {
        let p = provider(safety: [
            ["category": "HARM_CATEGORY_HARASSMENT", "threshold": "HARM_BLOCK_THRESHOLD_UNSPECIFIED"],
            ["category": "HARM_CATEGORY_HATE_SPEECH", "threshold": "BLOCK_ONLY_HIGH"],
        ])
        let sent = body(p)["safetySettings"] as? [[String: String]]

        XCTAssertEqual(sent?.count, 1)
        XCTAssertEqual(sent?.first?["category"], "HARM_CATEGORY_HATE_SPEECH")
    }

    func testAllUnspecifiedOmitsTheKeyEntirely() {
        let p = provider(safety: [
            ["category": "HARM_CATEGORY_HARASSMENT", "threshold": "HARM_BLOCK_THRESHOLD_UNSPECIFIED"],
        ])
        XCTAssertNil(body(p)["safetySettings"])
    }

    func testNoSafetyConfigurationSendsNothing() {
        XCTAssertNil(body(provider(safety: nil))["safetySettings"])
    }

    /// Every builder must route through the shared helper — the streaming path is the one a Bot
    /// profile uses, and it is where a silently-dropped safety setting would matter most.
    func testTheStreamingBuilderCarriesSafetySettingsToo() throws {
        let p = provider(safety: [["category": "HARM_CATEGORY_HARASSMENT", "threshold": "BLOCK_NONE"]])
        let sent = p.debugStreamingRequestBody(messages: [["role": "user", "content": "hi"]])
        XCTAssertNotNil(sent["safetySettings"])
    }

    /// The default config the panel displays must survive the round-trip into wire shape —
    /// otherwise A24's fallback delivers an empty safety block.
    func testTheDisplayedDefaultEncodesToFourCategories() throws {
        let encoded = try XCTUnwrap(AdvancedConfigEncoder.encode(GeminiAdvancedConfig.default()))
        let p = GeminiLLMProvider(config: LLMProviderConfig(
            apiKey: "k",
            baseURL: URL(string: "https://generativelanguage.googleapis.com/v1beta/models/gemini")!,
            modelName: "gemini-2.0-flash",
            options: encoded
        ))
        let sent = try XCTUnwrap(body(p)["safetySettings"] as? [[String: String]])
        XCTAssertEqual(sent.count, 4)
        XCTAssertTrue(sent.allSatisfy { $0["threshold"] == "BLOCK_MEDIUM_AND_ABOVE" })
    }
}

// MARK: - A24 / A25: the preset the panel shows must be the preset that runs

final class UnconfiguredAdvancedDefaultsTests: XCTestCase {

    /// ⚠️ `OllamaAdvancedConfig.default()` is the AGENT ladder. Handing it to a Bot pins a
    /// conversational profile to temperature 0.1 with a FIXED SEED, so every repeated prompt
    /// returns a byte-identical answer — the exact opposite of what `botPreset` exists to provide.
    func testTheAgentAndChatLaddersActuallyDiffer() {
        let agent = OllamaAdvancedConfig.default()
        let chat = OllamaAdvancedConfig.botPreset(for: .smallMedium)

        XCTAssertEqual(agent.temperature, 0.1, "agent preset is tuned for deterministic tool calls")
        XCTAssertEqual(agent.seed, 42, "the fixed seed is the agent ladder's signature")
        XCTAssertEqual(chat.temperature, 0.7)
        XCTAssertNil(chat.seed, "a chat bot must not be pinned to one sampling seed")
    }

    /// Both ladders must survive encoding, since that is how the executor now receives them.
    func testBothLaddersEncodeToProviderOptions() throws {
        let agent = try XCTUnwrap(AdvancedConfigEncoder.encode(OllamaAdvancedConfig.default()))
        XCTAssertEqual(agent["temperature"], .number(0.1))
        XCTAssertEqual(agent["seed"], .number(42))

        let chat = try XCTUnwrap(AdvancedConfigEncoder.encode(
            OllamaAdvancedConfig.botPreset(for: .smallMedium)))
        XCTAssertEqual(chat["temperature"], .number(0.7))
        XCTAssertNil(chat["seed"], "nil seed must not encode as a value")
    }

    func testTheGeminiDefaultEncodesTheMaxTokensThePanelShows() throws {
        let encoded = try XCTUnwrap(AdvancedConfigEncoder.encode(GeminiAdvancedConfig.default()))
        XCTAssertEqual(encoded["maxOutputTokens"], .number(2048))
    }

    /// ⚠️ register A54, and it is a wire assertion rather than a struct one on purpose. This same
    /// encoder output is what `AgentConnect.initializeModel` sends for an UNCONFIGURED Gemini
    /// profile, so a greedy default here reaches users who never opened the Advanced panel —
    /// which is how the A24 fix, correctly making the request match the panel, propagated it.
    func testTheGeminiDefaultDoesNotPutGreedyDecodingOnTheWire() throws {
        let encoded = try XCTUnwrap(AdvancedConfigEncoder.encode(GeminiAdvancedConfig.default()))
        XCTAssertNil(encoded["topK"],
                     "topK must be omitted so Google's own default applies; 1 is greedy decoding "
                     + "and makes the temperature and topP in this same payload inert")
        XCTAssertEqual(encoded["temperature"], .number(0.9),
                       "the controls topK was silencing must still be sent")
        XCTAssertEqual(encoded["topP"], .number(1.0))
    }

    /// ⚠️ Found by the assertion above, and it is the reason A54's fix delivers anything.
    /// `JSONSerialization` hands back an `NSNumber` for booleans and numbers alike, and an
    /// NSNumber holding 0 or 1 bridges to Swift `Bool` — so `JSONValue.init` classified those two
    /// values as `.bool`. Every provider reads options with `if case .number`, so a `1.0` arrived
    /// as `.bool(true)` and was DROPPED. Gemini's shipped `topP: 1.0` and Anthropic's shipped
    /// `temperature: 1.0` were never on the wire; un-silencing topK would have restored nothing.
    func testWholeNumberDoublesEncodeAsNumbersNotBooleans() throws {
        for value in [0.0, 1.0] {
            let encoded = try XCTUnwrap(AdvancedConfigEncoder.encode(
                GeminiAdvancedConfig(temperature: value, topP: value, topK: nil,
                                     maxOutputTokens: 2048, stopSequences: [], safetySettings: [])))
            XCTAssertEqual(encoded["temperature"], .number(value),
                           "\(value) must not be coerced to a Bool")
            XCTAssertEqual(encoded["topP"], .number(value), "\(value)")
        }
    }

    /// The other direction still has to work — a real boolean must stay a boolean.
    func testGenuineBooleansAreStillPreserved() {
        XCTAssertEqual(JSONValue(true), .bool(true))
        XCTAssertEqual(JSONValue(false), .bool(false))
        XCTAssertEqual(JSONValue(NSNumber(value: true)), .bool(true))
        XCTAssertEqual(JSONValue(NSNumber(value: 1)), .number(1.0))
        XCTAssertEqual(JSONValue(NSNumber(value: 0)), .number(0.0))
    }

    /// The encoder is the shared seam between the panel and the executor; a nil result is the
    /// documented "no options" degradation, so it must not be reached for a normal struct.
    func testEncodingAWellFormedConfigNeverReturnsNil() {
        XCTAssertNotNil(AdvancedConfigEncoder.encode(OllamaAdvancedConfig.default()))
        XCTAssertNotNil(AdvancedConfigEncoder.encode(GeminiAdvancedConfig.default()))
        XCTAssertNotNil(AdvancedConfigEncoder.encode(AnthropicAdvancedConfig.default()))
    }
}

// MARK: - A9: the load-time write-back guard

@MainActor
final class AdvancedConfigLoadGuardTests: XCTestCase {

    private final class NoopStore: BackendProfileStoreProtocol {
        func fetchProfiles() throws -> [BackendProfileSnapshot] { [] }
        func fetchProfile(byId id: UUID) throws -> BackendProfileSnapshot? { nil }
        func saveProfile(_ snapshot: BackendProfileSnapshot,
                         callerFile: String, callerFunction: String, callerLine: Int) throws -> [ProfileValidationError] { [] }  // A34: returns advisories; a double has none to report.
        func deleteProfile(withId id: UUID) throws {}
    }

    private var service: BackendProfileService!
    private var manager: ProviderAdvancedConfigManager!

    override func setUp() {
        service = BackendProfileService(store: NoopStore())
        manager = ProviderAdvancedConfigManager()
    }

    private func ollamaConfig(_ advanced: [String: JSONValue]?) -> ProviderConfig {
        ProviderConfig(apiProvider: .ollama, modelName: "llama3", advancedConfiguration: advanced)
    }

    /// ⚠️ The defect. `.onChange` runs on the NEXT update pass, after `load` has returned — so the
    /// old `isLoading` boolean was always false by the time the handler read it, and merely opening
    /// a profile wrote the decoded config straight back into the draft (phantom Save pill). The
    /// baseline is a value comparison, so it survives that deferral.
    func testEncodeReturnsNilWhenNothingChangedSinceLoad() {
        let stored = AdvancedConfigEncoder.encode(OllamaAdvancedConfig.botPreset(for: .smallMedium))
        manager.load(from: ollamaConfig(stored), using: service, defaultProfile: .chat)

        XCTAssertNil(manager.encode(for: .ollama, using: service),
                     "a deferred echo of the load must not be written back")
    }

    func testEncodeReturnsTheValueAfterARealUserEdit() {
        let stored = AdvancedConfigEncoder.encode(OllamaAdvancedConfig.botPreset(for: .smallMedium))
        manager.load(from: ollamaConfig(stored), using: service, defaultProfile: .chat)

        manager.localOllamaConfig.temperature = 0.42

        let written = manager.encode(for: .ollama, using: service)
        XCTAssertEqual(written?["temperature"], .number(0.42))
    }

    /// ⚠️ The data-loss half: switching from a profile with custom settings to one whose blob fails
    /// to decode used to fire `.onChange` (the local value genuinely changed) and overwrite the
    /// second profile's stored config with `.default()`.
    func testSwitchingToAnUndecodableProfileDoesNotWriteDefaultsOverIt() {
        let custom = AdvancedConfigEncoder.encode(
            OllamaAdvancedConfig(temperature: 0.95, topP: 0.5, topK: 7,
                                 numCtx: 2048, stop: [], seed: nil, repeatPenalty: 1.2))
        manager.load(from: ollamaConfig(custom), using: service, defaultProfile: .agent)

        // Second profile: a blob that cannot be decoded, so `load` falls back to the preset.
        manager.load(from: ollamaConfig(["garbage": .string("nope")]), using: service,
                     defaultProfile: .agent)

        XCTAssertNil(manager.encode(for: .ollama, using: service),
                     "the fallback preset must not be persisted over the second profile's blob")
    }

    /// A9 and A25 together: a Bot panel opened on an unconfigured profile must show the CHAT
    /// ladder, not the agent one — and still not write it back on open.
    func testAnUnconfiguredBotProfileLoadsTheChatLadderWithoutWritingIt() {
        manager.load(from: ollamaConfig(nil), using: service, defaultProfile: .chat)

        XCTAssertEqual(manager.localOllamaConfig.temperature, 0.7)
        XCTAssertNil(manager.localOllamaConfig.seed, "the fixed agent seed must not reach a bot")
        XCTAssertNil(manager.encode(for: .ollama, using: service))
    }

    func testAnUnconfiguredAgentProfileLoadsTheAgentLadder() {
        manager.load(from: ollamaConfig(nil), using: service, defaultProfile: .agent)

        XCTAssertEqual(manager.localOllamaConfig.temperature, 0.1)
        XCTAssertEqual(manager.localOllamaConfig.seed, 42)
    }

    /// Baselines are per provider: loading an Ollama profile must not silence a Gemini edit.
    func testBaselinesDoNotLeakAcrossProviders() {
        manager.load(from: ollamaConfig(nil), using: service, defaultProfile: .agent)
        manager.localGeminiConfig.temperature = 0.33

        XCTAssertEqual(manager.encode(for: .google, using: service)?["temperature"], .number(0.33))
    }
}
