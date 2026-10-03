// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
//
//  SynthesisOptInTests.swift
//  DevgenticTests
//
//  Pins the per-provider-family opt-in decision.
//  Pure — no IntelligenceCoreService, no MLX model load.
//

import XCTest
@testable import devgentic

final class SynthesisOptInTests: XCTestCase {

    /// Isolated defaults per test — never touch the user's real domain.
    private var defaults: UserDefaults!
    private var suiteName: String!

    override func setUp() {
        super.setUp()
        suiteName = "SynthesisOptInTests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
        suiteName = nil
        super.tearDown()
    }

    // MARK: - Family Mapping

    func testFamilyMapping_LocalProviders() {
        XCTAssertEqual(SynthesisOptIn.ProviderFamily(apiProvider: .mlx), .mlx)
        XCTAssertEqual(SynthesisOptIn.ProviderFamily(apiProvider: .ollama), .ollama)
    }

    /// Every non-local provider is one bucket: the decision is about model class,
    /// not vendor. Enumerated explicitly so adding a provider fails loudly here.
    func testFamilyMapping_AllRemoteProvidersCollapseToRemote() {
        for provider: ApiProvider in [.openAI, .anthropic, .google, .openRouter, .openAICompatible] {
            XCTAssertEqual(SynthesisOptIn.ProviderFamily(apiProvider: provider), .remote,
                           "\(provider.rawValue) must resolve to .remote")
        }
    }

    /// Guards against a future provider being added to `ApiProvider` without a
    /// deliberate family decision — every case must map somewhere.
    func testFamilyMapping_CoversEveryApiProvider() {
        for provider in ApiProvider.allCases {
            let family = SynthesisOptIn.ProviderFamily(apiProvider: provider)
            XCTAssertFalse(family.defaultsKey.isEmpty, "\(provider.rawValue) has no opt-in key")
        }
    }

    func testDefaultsKeys_AreDistinctPerFamily() {
        let keys = Set(SynthesisOptIn.ProviderFamily.allCases.map(\.defaultsKey))
        XCTAssertEqual(keys.count, 3, "Each family needs its own key, got: \(keys)")
    }

    // MARK: - Resolution

    func testResolved_NothingSet_IsNotOptedIn() {
        let d = SynthesisOptIn.resolved(provider: .ollama, icModelSelected: true, icEnabled: true, defaults: defaults)
        XCTAssertFalse(d.optedIn)
        XCTAssertEqual(d.reason, "family-not-opted-in")
        XCTAssertEqual(d.family, .ollama)
    }

    func testResolved_FamilyOptedIn_IsOptedIn() {
        defaults.set(true, forKey: AppSettings.ciFeatureResponseSynthesisOllamaKey)
        let d = SynthesisOptIn.resolved(provider: .ollama, icModelSelected: true, icEnabled: true, defaults: defaults)
        XCTAssertTrue(d.optedIn)
        XCTAssertEqual(d.reason, "opted-in")
    }

    /// Family isolation — the acceptance case "MLX profile with only Ollama checked".
    func testResolved_OtherFamilyOptedIn_DoesNotLeakAcrossFamilies() {
        defaults.set(true, forKey: AppSettings.ciFeatureResponseSynthesisOllamaKey)
        let mlx = SynthesisOptIn.resolved(provider: .mlx, icModelSelected: true, icEnabled: true, defaults: defaults)
        XCTAssertFalse(mlx.optedIn, "An Ollama opt-in must not enable synthesis for an MLX run")
        XCTAssertEqual(mlx.family, .mlx)

        let remote = SynthesisOptIn.resolved(provider: .anthropic, icModelSelected: true, icEnabled: true, defaults: defaults)
        XCTAssertFalse(remote.optedIn, "An Ollama opt-in must not enable synthesis for a cloud run")
    }

    /// The master toggle wins — this is the bug the old code had, where
    /// `IntelligenceCoreService.generate` only checked `hasModelSelected` and the
    /// force paths ran IC for users who had Core Intelligence switched off.
    func testResolved_CoreIntelligenceDisabled_OverridesFamilyOptIn() {
        defaults.set(true, forKey: AppSettings.ciFeatureResponseSynthesisRemoteKey)
        let d = SynthesisOptIn.resolved(provider: .openAI, icModelSelected: true, icEnabled: false, defaults: defaults)
        XCTAssertFalse(d.optedIn)
        XCTAssertEqual(d.reason, "core-intelligence-disabled")
    }

    func testResolved_NoICModelSelected_OverridesFamilyOptIn() {
        defaults.set(true, forKey: AppSettings.ciFeatureResponseSynthesisRemoteKey)
        let d = SynthesisOptIn.resolved(provider: .openAI, icModelSelected: false, icEnabled: true, defaults: defaults)
        XCTAssertFalse(d.optedIn)
        XCTAssertEqual(d.reason, "no-ic-model-selected")
    }
}
