// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2026 Raj Singh
//
//  AdvancedConfigCodableTests.swift
//  DevgenticTests
//
//  Created on 07/08/26.
//
//  Round-trip and compatibility tests for the six persisted `AdvanceConfig` Codables (register A69).
//
//  ⚠️ WHY THESE MATTER MORE THAN THEIR SIZE SUGGESTS. These structs are serialised into
//  `ProviderConfig.advancedConfiguration` and stored inside the opaque `BackendProfile.configData`
//  blob — the layer `BackendProfile.swift` itself calls out as the one SwiftData cannot see into,
//  where "adding a field is not a schema change; the failure lands at READ time".
//
//  And the read-time failure is SILENT: `BackendProfileService.decodeConfig` returns nil on any
//  throw, and all seven arms of `ProviderAdvancedConfigManager.load` answer that nil with
//  `?? .default()`. So one unreadable field does not degrade one field — it replaces the user's
//  ENTIRE advanced configuration with app defaults, and the panel then shows those defaults as if
//  they were what the user chose.
//
//  Every struct here is therefore held to the same bar: a blob missing a key, carrying an extra
//  key, or carrying a legacy wrong-typed value must still decode, preserving whatever IS readable.
//

import XCTest
@testable import devgentic

final class AdvancedConfigCodableTests: XCTestCase {

    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    private func roundTrip<T: Codable>(_ value: T) throws -> T {
        try decoder.decode(T.self, from: encoder.encode(value))
    }

    private func decode<T: Decodable>(_ type: T.Type, _ json: String) throws -> T {
        try decoder.decode(type, from: Data(json.utf8))
    }

    // MARK: - Round-trip identity
    //
    // The floor: what the app writes, the app must read back unchanged. A default that cannot
    // survive its own encoder would corrupt every profile that never touched the panel.

    func testEveryDefaultSurvivesItsOwnRoundTrip() throws {
        XCTAssertEqual(try roundTrip(OllamaAdvancedConfig.default()), .default())
        XCTAssertEqual(try roundTrip(GeminiAdvancedConfig.default()), .default())
        XCTAssertEqual(try roundTrip(AnthropicAdvancedConfig.default()), .default())
        XCTAssertEqual(try roundTrip(OpenAIAdvancedConfig.default()), .default())
        XCTAssertEqual(try roundTrip(MLXAdvancedConfig.default()), .default())
        XCTAssertEqual(try roundTrip(ImageGenAdvancedConfig.default()), .default())
        XCTAssertEqual(try roundTrip(ImageGenAdvancedConfig.mlxDefault()), .mlxDefault())
    }

    /// The presets are what an unconfigured profile now RUNS (register A24/A25), so they have to
    /// survive the blob too — not just the `default()` values.
    func testOllamaPresetLaddersRoundTrip() throws {
        for tier in [OllamaAdvancedConfig.ModelTier.tiny, .smallMedium, .large] {
            XCTAssertEqual(try roundTrip(OllamaAdvancedConfig.preset(for: tier)), .preset(for: tier))
            XCTAssertEqual(try roundTrip(OllamaAdvancedConfig.botPreset(for: tier)), .botPreset(for: tier))
        }
    }

    // MARK: - Missing keys (a blob written by an OLDER build)
    //
    // ⚠️ Every one of these structs has gained fields over time — `repetitionContextSize`,
    // `reasoningEffort`, `thinkingEffort`. A decoder that hard-`decode`s a field added later will
    // throw on every blob written before it, and the user loses the whole panel to defaults.

    func testAnEmptyObjectDecodesForEveryConfig() throws {
        XCTAssertNoThrow(try decode(OllamaAdvancedConfig.self, "{}"))
        XCTAssertNoThrow(try decode(GeminiAdvancedConfig.self, "{}"))
        XCTAssertNoThrow(try decode(AnthropicAdvancedConfig.self, "{}"))
        XCTAssertNoThrow(try decode(OpenAIAdvancedConfig.self, "{}"))
        XCTAssertNoThrow(try decode(MLXAdvancedConfig.self, "{}"))
        XCTAssertNoThrow(try decode(ImageGenAdvancedConfig.self, "{}"))
    }

    /// A partial blob must preserve what IS present rather than discarding everything.
    func testAPartialBlobKeepsTheFieldsItDoesCarry() throws {
        let mlx = try decode(MLXAdvancedConfig.self, #"{"temperature": 0.42}"#)
        XCTAssertEqual(mlx.temperature, 0.42)
        XCTAssertEqual(mlx.maxTokens, MLXAdvancedConfig.default().maxTokens,
                       "an absent field falls back to the default, not to a total decode failure")

        let imageGen = try decode(ImageGenAdvancedConfig.self, #"{"steps": 30}"#)
        XCTAssertEqual(imageGen.steps, 30)
        XCTAssertEqual(imageGen.quality, ImageGenAdvancedConfig.default().quality)

        let ollama = try decode(OllamaAdvancedConfig.self, #"{"temperature": 0.33}"#)
        XCTAssertEqual(ollama.temperature, 0.33)
        XCTAssertNil(ollama.seed)
    }

    /// The documented case in `MLXAdvancedConfig`'s own comment: configs saved before
    /// `repetitionContextSize` existed.
    func testMLXDecodesABlobPredatingRepetitionContextSize() throws {
        let json = #"{"temperature":0.1,"topP":0.9,"repetitionPenalty":1.15,"maxTokens":2048}"#
        let config = try decode(MLXAdvancedConfig.self, json)
        XCTAssertEqual(config.repetitionContextSize, 20)
        XCTAssertEqual(config.maxTokens, 2048)
    }

    // MARK: - Unknown keys (a blob written by a NEWER build)
    //
    // The app is unsandboxed and its store lives in a shared directory, so running an earlier
    // build against a newer store is reachable — the profile blob's own `tooNew` refusal exists
    // for exactly that. These inner structs have no version stamp, so tolerance is all they have.

    func testUnknownKeysAreIgnoredByEveryConfig() throws {
        let extra = #"{"someFieldFromTheFuture": 7, "anotherOne": "hello"}"#
        XCTAssertNoThrow(try decode(OllamaAdvancedConfig.self, extra))
        XCTAssertNoThrow(try decode(GeminiAdvancedConfig.self, extra))
        XCTAssertNoThrow(try decode(AnthropicAdvancedConfig.self, extra))
        XCTAssertNoThrow(try decode(OpenAIAdvancedConfig.self, extra))
        XCTAssertNoThrow(try decode(MLXAdvancedConfig.self, extra))
        XCTAssertNoThrow(try decode(ImageGenAdvancedConfig.self, extra))
    }

    // MARK: - Legacy wrong-typed values
    //
    // Four of these decoders were hand-written specifically to repair numbers that an earlier
    // build persisted as Bools. That tolerance is load-bearing and easy to lose in a refactor,
    // so it is pinned here rather than left to the comment that describes it.

    // MARK: - A39: MLX parameter bounds
    //
    // ⚠️ These were `private var`s on `MLXSettingsView`, so the bounds that silently rewrote a
    // persisted user setting could not be asserted at all. Extracted onto the config for the same
    // reason `ModelSelectionPolicy` was lifted out of the pickers.

    func testMaxTokensCapIsHalfTheContextWindowWithAFloor() {
        XCTAssertEqual(MLXAdvancedConfig.maxTokensCap(forContextWindow: 8192), 4096)
        XCTAssertEqual(MLXAdvancedConfig.maxTokensCap(forContextWindow: 32768), 16384)
        XCTAssertEqual(MLXAdvancedConfig.maxTokensCap(forContextWindow: 512), 512,
                       "a pathologically small window must not make the field unusable")
    }

    func testRepetitionContextCapIsQuarteredAndBoundedBothWays() {
        XCTAssertEqual(MLXAdvancedConfig.repetitionContextCap(forContextWindow: 4096), 1024)
        XCTAssertEqual(MLXAdvancedConfig.repetitionContextCap(forContextWindow: 131072), 2048,
                       "past ~2K the sampler's scan cost outweighs the benefit")
        XCTAssertEqual(MLXAdvancedConfig.repetitionContextCap(forContextWindow: 128), 64)
    }

    /// ⚠️ The invariant that makes floor-only clamping safe: the floor can never sit above the
    /// cap. If it could, a value would be simultaneously below the floor (so clamped up) and above
    /// the cap (so warned about), and the panel would fight the user on every open.
    func testTheFloorNeverExceedsTheCapForAnyContextWindow() {
        for window in [0, 1, 64, 128, 512, 2048, 4096, 8192, 32768, 131072, 1_000_000] {
            XCTAssertLessThanOrEqual(
                MLXAdvancedConfig.maxTokensFloor,
                MLXAdvancedConfig.maxTokensCap(forContextWindow: window), "window \(window)")
            XCTAssertLessThanOrEqual(
                MLXAdvancedConfig.repetitionContextFloor,
                MLXAdvancedConfig.repetitionContextCap(forContextWindow: window), "window \(window)")
        }
    }

    /// ⚠️ The persistence half of A39. The panel no longer rewrites an over-cap value, so nothing
    /// downstream may quietly "repair" it either — `AgentConnect` hands the decoded blob straight
    /// to `MLXLLMProvider`, and a value the user deliberately kept must survive the round trip.
    func testAnOverCapMaxTokensSurvivesTheRoundTrip() throws {
        let tuned = MLXAdvancedConfig(temperature: 0.7, topP: 0.9, repetitionPenalty: 1.1,
                                      repetitionContextSize: 20, maxTokens: 8192)
        let decoded = try decode(MLXAdvancedConfig.self,
                                 String(data: try JSONEncoder().encode(tuned), encoding: .utf8)!)

        XCTAssertEqual(decoded.maxTokens, 8192,
                       "a value tuned for a larger-context model must not be silently reduced")
        XCTAssertGreaterThan(decoded.maxTokens,
                             MLXAdvancedConfig.maxTokensCap(forContextWindow: 4096),
                             "precondition: this value really is over the cap for a small model")
    }

    // MARK: - A54: the greedy-decoding default is repaired on read

    /// ⚠️ Changing `GeminiAdvancedConfig.default()` fixes new profiles only. Every profile that
    /// touched the Advanced panel under the old default persisted `topK: 1`, and the blob is the
    /// only place it lives — so the decoder repairs it. Blind repair is safe because the old
    /// stepper's floor was 1, making a stored 1 indistinguishable from "never touched".
    func testGeminiRepairsAStoredGreedyTopKOnDecode() throws {
        let greedy = try decode(GeminiAdvancedConfig.self, #"{"temperature": 0.9, "topK": 1}"#)
        XCTAssertNil(greedy.topK, "a stored 1 must not survive — it silences temperature and topP")
        XCTAssertEqual(greedy.temperature, 0.9, "the repair must not disturb neighbouring fields")
    }

    func testGeminiLeavesEveryOtherStoredTopKAlone() throws {
        for stored in [0, 2, 40, 64, 100] {
            let config = try decode(GeminiAdvancedConfig.self, #"{"topK": \#(stored)}"#)
            XCTAssertEqual(config.topK, stored, "only the greedy value is repaired")
        }
    }

    func testGeminiDefaultNoLongerShipsGreedyDecoding() {
        XCTAssertNil(GeminiAdvancedConfig.default().topK,
                     "omitting topK lets the model apply its own default (Google's is 64)")
    }

    func testNumericFieldsSurviveALegacyBoolean() throws {
        let ollama = try decode(OllamaAdvancedConfig.self, #"{"temperature": true, "topK": false}"#)
        XCTAssertEqual(ollama.temperature, 1.0)
        XCTAssertEqual(ollama.topK, 0)

        // ⚠️ This asserted `topK == 1` until register A54. The legacy bool `true` meant 1, and 1 is
        // the greedy value that silences Temperature and Top P — so the bool arm now lands on the
        // same repair as a stored literal 1 (see the A54 test below). The tolerance being pinned
        // here is that a Bool still decodes rather than throwing; the VALUE it lands on is A54's.
        let gemini = try decode(GeminiAdvancedConfig.self, #"{"topK": true, "maxOutputTokens": true}"#)
        XCTAssertNil(gemini.topK)
        XCTAssertEqual(gemini.maxOutputTokens, 2048)

        let anthropic = try decode(AnthropicAdvancedConfig.self, #"{"maxTokens": true, "topP": false}"#)
        XCTAssertEqual(anthropic.maxTokens, 4096)
        XCTAssertEqual(anthropic.topP, 0.0)
    }

    // MARK: - Field-level fidelity
    //
    // A round-trip that silently drops a field would pass an identity check only if the field were
    // also absent from the source. These pin the specific values the panels write.

    func testOllamaKeepsEveryFieldThroughTheBlob() throws {
        let original = OllamaAdvancedConfig(
            temperature: 0.35, topP: 0.85, topK: 33, numCtx: 12288,
            stop: ["\n\n", "END"], seed: 7, repeatPenalty: 1.07)
        let decoded = try roundTrip(original)

        XCTAssertEqual(decoded.temperature, 0.35)
        XCTAssertEqual(decoded.topP, 0.85)
        XCTAssertEqual(decoded.topK, 33)
        XCTAssertEqual(decoded.numCtx, 12288)
        XCTAssertEqual(decoded.stop, ["\n\n", "END"])
        XCTAssertEqual(decoded.seed, 7)
        XCTAssertEqual(decoded.repeatPenalty, 1.07)
    }

    func testGeminiKeepsItsSafetySettingsThroughTheBlob() throws {
        var original = GeminiAdvancedConfig.default()
        original.safetySettings = [
            .init(category: .harassment, threshold: .blockNone),
            .init(category: .dangerousContent, threshold: .blockLowAndAbove),
        ]
        let decoded = try roundTrip(original)

        XCTAssertEqual(decoded.safetySettings?.count, 2)
        XCTAssertEqual(decoded.safetySettings?.first(where: { $0.category == .harassment })?.threshold,
                       .blockNone)
    }

    /// ⚠️ `thinkingEffort` is the newest field on this struct (added with the adaptive-thinking
    /// fix). It is the one most likely to be absent from a stored blob.
    func testAnthropicKeepsThinkingFieldsThroughTheBlob() throws {
        var original = AnthropicAdvancedConfig.default()
        original.extendedThinking = true
        original.thinkingEffort = "xhigh"
        original.thinkingBudgetTokens = 12000

        let decoded = try roundTrip(original)
        XCTAssertTrue(decoded.extendedThinking)
        XCTAssertEqual(decoded.thinkingEffort, "xhigh")
        XCTAssertEqual(decoded.thinkingBudgetTokens, 12000)
    }

    func testOpenAIKeepsReasoningEffortThroughTheBlob() throws {
        var original = OpenAIAdvancedConfig.default()
        original.reasoningEffort = "high"
        original.stopSequences = ["STOP"]

        let decoded = try roundTrip(original)
        XCTAssertEqual(decoded.reasoningEffort, "high")
        XCTAssertEqual(decoded.stopSequences, ["STOP"])
    }

    func testImageGenKeepsQualityAndMLXFieldsThroughTheBlob() throws {
        let original = ImageGenAdvancedConfig(quality: .hd, steps: 40, guidance: 4.5)
        let decoded = try roundTrip(original)

        XCTAssertEqual(decoded.quality, .hd)
        XCTAssertEqual(decoded.steps, 40)
        XCTAssertEqual(decoded.guidance, 4.5)
    }

    /// An unrecognised enum value must not take the whole config down with it.
    func testAnUnknownImageQualityFallsBackInsteadOfThrowing() throws {
        let decoded = try decode(ImageGenAdvancedConfig.self, #"{"quality": "ultra-plus-max"}"#)
        XCTAssertEqual(decoded.quality, ImageGenAdvancedConfig.default().quality)
    }

    // MARK: - The encoder the executor uses
    //
    // `AdvancedConfigEncoder` is the seam between these structs and provider options (A24/A25).
    // A struct that encodes fine to Data but not to a `[String: JSONValue]` bag would deliver
    // nothing at request time while looking correct here.

    func testEveryConfigEncodesToTheProviderOptionsBag() {
        XCTAssertNotNil(AdvancedConfigEncoder.encode(OllamaAdvancedConfig.default()))
        XCTAssertNotNil(AdvancedConfigEncoder.encode(GeminiAdvancedConfig.default()))
        XCTAssertNotNil(AdvancedConfigEncoder.encode(AnthropicAdvancedConfig.default()))
        XCTAssertNotNil(AdvancedConfigEncoder.encode(OpenAIAdvancedConfig.default()))
        XCTAssertNotNil(AdvancedConfigEncoder.encode(MLXAdvancedConfig.default()))
        XCTAssertNotNil(AdvancedConfigEncoder.encode(ImageGenAdvancedConfig.default()))
    }

    /// Nil optionals must not encode as a value — a `seed` of `null` reaching Ollama is not the
    /// same as no seed, and this is how the chat ladder's "no fixed seed" reaches the provider.
    func testNilOptionalsAreOmittedFromTheOptionsBag() throws {
        let chat = OllamaAdvancedConfig.botPreset(for: .smallMedium)
        XCTAssertNil(chat.seed, "precondition: the chat ladder has no fixed seed")

        let encoded = try XCTUnwrap(AdvancedConfigEncoder.encode(chat))
        XCTAssertNil(encoded["seed"], "a nil seed must be absent, not present-as-null")
    }

    // MARK: - A56: the Quality control must only appear where it is read
    //
    // ⚠️ The picker was rendered for every provider but only two services read `options.quality`,
    // so switching to HD on a Gemini or Ollama profile produced byte-identical output while the
    // caption promised "higher detail at the cost of speed". This pins the CONSUMPTION side of that
    // claim — the UI gate is only correct while these two remain the readers.

    func testQualityIsHonouredByExactlyTheProvidersTheUIOffersItFor() throws {
        let sourceRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // Persistence
            .deletingLastPathComponent()   // Core
            .deletingLastPathComponent()   // DevgenticTests
            .deletingLastPathComponent()   // repo root
            .appendingPathComponent("Devgentic/Core/Backends/ImageGen/Providers")

        let readers = ["OpenAIImageGenService", "MLXImageGenService"]
        let nonReaders = ["GeminiImageGenService", "OllamaImageGenService"]

        for name in readers {
            let source = try String(
                contentsOf: sourceRoot.appendingPathComponent("\(name).swift"), encoding: .utf8)
            XCTAssertTrue(source.contains("options.quality"),
                          "\(name) is expected to honour quality — the UI offers the control for it")
        }
        for name in nonReaders {
            let source = try String(
                contentsOf: sourceRoot.appendingPathComponent("\(name).swift"), encoding: .utf8)
            XCTAssertFalse(source.contains("options.quality"),
                           "\(name) now reads quality — add it to `providerHonoursQuality` in "
                           + "ImageGenSettingsView so the control stops being hidden for it")
        }
    }

    /// A stored `.hd` on a provider that ignores it must still decode — hiding the control does not
    /// remove the value from existing blobs, and it must not become a decode hazard.
    func testAStoredQualityStillDecodesForProvidersThatIgnoreIt() throws {
        let decoded = try decode(ImageGenAdvancedConfig.self, #"{"quality":"hd"}"#)
        XCTAssertEqual(decoded.quality, .hd)
    }
}
