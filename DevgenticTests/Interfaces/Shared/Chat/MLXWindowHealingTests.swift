// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
//
//  MLXWindowHealingTests.swift
//  DevgenticTests
//
//  `MLXContextWindowHealer.persistBackfill` guarded on
//  `cfg.llmConfig.modelMetadata?.contextWindow == nil`, which is ALSO true when
//  `modelMetadata` is entirely nil. In that case the optional-chained assignment silently did
//  nothing, yet `saveProfile` still ran and logged a success message.
//
//  So an MLX profile with no metadata was NEVER healed, while a sibling profile on the same
//  model that happened to have metadata was — a permanent 8K-vs-real divergence in every
//  window-derived budget, reported in the log as a successful backfill.
//
//  The healing helper is exercised through `ProviderConfig` directly; the store write is a
//  separate concern and is not what broke.
//

import XCTest
@testable import devgentic

@MainActor
final class MLXWindowHealingTests: XCTestCase {

    private func mlxConfig(metadata: ModelMetadata?) -> ProviderConfig {
        var config = ProviderConfig(apiProvider: .mlx, modelName: "qwen3-30b")
        config.modelMetadata = metadata
        return config
    }

    // MARK: - The no-op

    /// The case that was silently skipped: no metadata at all.
    func testProfileWithNoMetadataAtAllIsHealed() throws {
        let healed = try XCTUnwrap(
            MLXContextWindowHealer.healedConfigForTesting(mlxConfig(metadata: nil), window: 131_072),
            "a profile with absent metadata must be healed, not silently skipped"
        )
        XCTAssertEqual(healed.modelMetadata?.contextWindow, 131_072)
    }

    /// The tier must be the one every consumer already substitutes for nil, so healing the
    /// WINDOW cannot change tier-derived budgets as a side effect.
    /// (`AgentConnect`: `modelMetadata?.tier ?? .medium`.)
    func testCreatedMetadataUsesTheTierConsumersAlreadyAssume() throws {
        let healed = try XCTUnwrap(
            MLXContextWindowHealer.healedConfigForTesting(mlxConfig(metadata: nil), window: 32_768)
        )
        XCTAssertEqual(healed.modelMetadata?.tier, .medium)
    }

    // MARK: - The case that already worked must keep working

    func testMetadataPresentButWindowMissingIsHealedInPlace() throws {
        let existing = ModelMetadata(tier: .large, contextWindow: nil,
                                     quantization: "Q4", family: "qwen")
        let healed = try XCTUnwrap(
            MLXContextWindowHealer.healedConfigForTesting(mlxConfig(metadata: existing), window: 131_072)
        )
        XCTAssertEqual(healed.modelMetadata?.contextWindow, 131_072)
        XCTAssertEqual(healed.modelMetadata?.tier, .large, "existing metadata must be preserved")
        XCTAssertEqual(healed.modelMetadata?.quantization, "Q4")
        XCTAssertEqual(healed.modelMetadata?.family, "qwen")
    }

    // MARK: - Nothing to do

    /// Already healed — re-running must not rewrite, or every gauge recompute would churn
    /// the profile store.
    func testAlreadyHealedProfileIsLeftAlone() {
        let existing = ModelMetadata(tier: .small, contextWindow: 8_192)
        XCTAssertNil(
            MLXContextWindowHealer.healedConfigForTesting(mlxConfig(metadata: existing), window: 131_072),
            "a window that is already set must not be overwritten"
        )
    }

    func testNonMLXConfigIsNeverTouched() {
        var cloud = ProviderConfig(apiProvider: .anthropic, modelName: "claude-opus-5")
        cloud.modelMetadata = nil
        XCTAssertNil(MLXContextWindowHealer.healedConfigForTesting(cloud, window: 200_000))
    }
}
