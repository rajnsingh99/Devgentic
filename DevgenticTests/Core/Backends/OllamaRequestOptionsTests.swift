// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
//
//  OllamaRequestOptionsTests.swift
//  DevgenticTests
//
//  Created by Raj Singh.
//

import XCTest
@testable import devgentic

final class OllamaRequestOptionsTests: XCTestCase {

    private static let tiers: [ModelTier] = [.tiny, .small, .medium, .large, .ultra]
    private static let flavours: [OllamaConfigDefaultProfile] = [.agent, .chat]

    private func config(
        tier: ModelTier?,
        trainedWindow: Int? = nil,
        stored: [String: JSONValue]? = nil,
        modelName: String = "test-model-with-no-catalog-entry"
    ) -> ProviderConfig {
        var config = ProviderConfig(apiProvider: .ollama, modelName: modelName)
        config.advancedConfiguration = stored
        config.modelMetadata = tier.map { ModelMetadata(tier: $0, contextWindow: trainedWindow) }
        return config
    }

    /// What the request will actually be built with — the send path, in one line.
    private func sentNumCtx(_ config: ProviderConfig, flavour: OllamaConfigDefaultProfile) -> Int? {
        let resolved = OllamaRequestOptions.resolve(
            stored: config.advancedConfiguration,
            metadata: config.modelMetadata,
            modelName: config.modelName,
            flavour: flavour,
            numCtxOverride: config.numCtxOverride
        )
        return OllamaContextWindowPolicy.configuredNumCtx(in: resolved.options)
    }

    // MARK: - THE invariant

    func testAssumedWindowEqualsSentNumCtxForEveryTierAndFlavour() {
        // ⚠️ THE REGRESSION GUARD. Before the resolvers were unified this failed for every tier:
        // assumed 16384 (auto-default) vs sent 4096/8192/16384 (preset ladder).
        for tier in Self.tiers {
            for flavour in Self.flavours {
                let config = config(tier: tier, trainedWindow: 131_072)
                let assumed = EffectiveContextWindow.resolve(for: config, flavour: flavour)

                XCTAssertEqual(
                    assumed, sentNumCtx(config, flavour: flavour),
                    "tier \(tier), flavour \(flavour): the app assumes \(assumed) tokens but the "
                    + "request will carry \(sentNumCtx(config, flavour: flavour).map(String.init) ?? "no num_ctx"). "
                    + "Whichever is right, everything that prices against the assumed value — the "
                    + "gauge, compaction, the native-turn budget, the pre-send fit check — is wrong "
                    + "by the difference, and an overflow is HEAD-truncated with the system prompt "
                    + "going first."
                )
            }
        }
    }

    func testTheFieldObservedCaseAgrees() {
        // The exact shape from the incident: small-tier Ollama model, agent flow, nothing stored,
        // a large trained window. The gauge said 16384; the request said 8192.
        let config = config(tier: .small, trainedWindow: 131_072)

        XCTAssertEqual(
            EffectiveContextWindow.resolve(for: config, flavour: .agent),
            sentNumCtx(config, flavour: .agent),
            "A small-tier Ollama agent profile with no stored Advanced configuration is the DEFAULT "
            + "state of every Code session. If these disagree the gauge is lying on the most common "
            + "configuration the app has."
        )
    }

    func testAStoredConfigurationStillWins() {
        // A user who opens the Advanced panel and picks a window must get that window, and the
        // budgets must price against it — this path was always consistent and must stay so.
        let stored: [String: JSONValue] = ["numCtx": .number(32_768)]
        let config = config(tier: .small, trainedWindow: 131_072, stored: stored)

        XCTAssertEqual(sentNumCtx(config, flavour: .agent), 32_768)
        XCTAssertEqual(EffectiveContextWindow.resolve(for: config, flavour: .agent), 32_768,
                       "An explicitly configured num_ctx must reach the budgets unchanged.")
    }

    func testUnknownModelWithNoMetadataStillAgrees() {
        // No tier, no trained window, no catalog entry: the factory still materialises a preset,
        // so the budgets must see that preset's window rather than the `assumedServerDefault`
        // the old code returned. This is the second, quieter half of the same defect.
        let config = config(tier: nil)

        for flavour in Self.flavours {
            XCTAssertEqual(
                EffectiveContextWindow.resolve(for: config, flavour: flavour),
                sentNumCtx(config, flavour: flavour),
                "With no metadata at all the factory falls back to a preset, so the budgets must "
                + "not assume Ollama's server default — nothing ever lets the server default apply."
            )
        }
    }

    // MARK: - The resolver reports what it did

    func testPresetIsReportedOnlyWhenItWasActuallyApplied() {
        // `AgentConnect` logs "[PROFILE] No stored advanced configuration …" off this flag. A flag
        // that were always set would put a false line in every log; never set, the operator loses
        // the only signal that the UI's preset — not the user's choice — is in force.
        let unconfigured = OllamaRequestOptions.resolve(
            stored: nil, metadata: ModelMetadata(tier: .small), modelName: "m", flavour: .agent, numCtxOverride: nil)
        XCTAssertEqual(unconfigured.presetApplied, .agent)

        let configured = OllamaRequestOptions.resolve(
            stored: ["numCtx": .number(4_096)], metadata: ModelMetadata(tier: .small),
            modelName: "m", flavour: .agent, numCtxOverride: nil)
        XCTAssertNil(configured.presetApplied,
                     "A stored configuration was used; claiming a preset was applied would be false.")
    }

    func testFlavourSelectsItsOwnLadder() {
        // Not asserting the window (identical across ladders today) — asserting that the flavour
        // reaches the ladder at all. The agent preset pins a fixed seed; the chat preset must not,
        // or every repeated prompt in a Bot returns a byte-identical reply.
        let agent = OllamaRequestOptions.resolve(
            stored: nil, metadata: ModelMetadata(tier: .small), modelName: "m", flavour: .agent, numCtxOverride: nil)
        let chat = OllamaRequestOptions.resolve(
            stored: nil, metadata: ModelMetadata(tier: .small), modelName: "m", flavour: .chat, numCtxOverride: nil)

        XCTAssertNotNil(agent.options?["seed"])
        XCTAssertNotEqual(
            agent.options?["temperature"], chat.options?["temperature"],
            "Both ladders produced the same sampling configuration, so `flavour` is not reaching "
            + "`OllamaAdvancedConfig.recommended` — a Bot would be running the deterministic agent "
            + "preset."
        )
    }

    // MARK: - Profile type maps to exactly one ladder

    func testOnlyBotIsOnTheChatLadder() {
        // ⚠️ `.code` is the one worth stating: it is a tool-running profile that LOOKS like chat.
        // Putting it on the chat ladder would sample a coding agent at temperature 0.7 with no
        // fixed seed.
        XCTAssertEqual(OllamaConfigDefaultProfile.forProfileType(.bot), .chat)
        for type in [ProfileType.agent, .code, .workflow, .imageGen] {
            XCTAssertEqual(OllamaConfigDefaultProfile.forProfileType(type), .agent,
                           "\(type) runs a tool loop and must be on the deterministic agent ladder.")
        }
    }

    // MARK: - Other providers are untouched

    func testFlavourDoesNotPerturbNonOllamaProviders() {
        // The parameter is Ollama-only. If it ever changed an MLX or cloud answer, every call site
        // would suddenly have to be right about something it has no reason to know.
        for provider in [ApiProvider.mlx, .openAI, .anthropic] {
            var config = ProviderConfig(apiProvider: provider, modelName: "m")
            config.modelMetadata = ModelMetadata(tier: .small, contextWindow: 32_768)
            XCTAssertEqual(
                EffectiveContextWindow.resolve(for: config, flavour: .agent),
                EffectiveContextWindow.resolve(for: config, flavour: .chat),
                "\(provider) must resolve the same window regardless of the Ollama preset ladder."
            )
        }
    }
}
