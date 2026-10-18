// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
//
//  RemoteModelsGateTests.swift
//  DevgenticTests
//
//  Created by Raj Singh.
//

import XCTest
@testable import devgentic

final class RemoteModelsGateTests: XCTestCase {

    override func setUp() {
        super.setUp()
        UserDefaults.standard.removeObject(forKey: AppSettings.showRemoteModelsKey)
    }

    override func tearDown() {
        UserDefaults.standard.removeObject(forKey: AppSettings.showRemoteModelsKey)
        super.tearDown()
    }

    private func setShowRemoteModels(_ value: Bool) {
        UserDefaults.standard.set(value, forKey: AppSettings.showRemoteModelsKey)
    }

    // MARK: - Default state

    func testDefaultIsHidden() {
        XCTAssertFalse(AppSettings.showRemoteModels,
                       "Remote models ship hidden — the toggle is the way back in.")
    }

    // MARK: - allowedProviders (profile config pickers)

    func testAgentPickerHidesRemoteProvidersByDefault() {
        let providers = ProfileCapabilityFilter.allowedProviders(for: .agent)
        for gated in ApiProvider.allCases where ProfileCapabilityFilter.remoteModelProviders.contains(gated) {
            XCTAssertFalse(providers.contains(gated), "\(gated.rawValue) must be hidden by default")
        }
        XCTAssertTrue(providers.contains(.ollama))
        XCTAssertTrue(providers.contains(.mlx))
        XCTAssertTrue(providers.contains(.openRouter), "OpenRouter is not a gated provider")
        XCTAssertTrue(providers.contains(.openAICompatible), "OpenAI-compatible is not a gated provider")
    }

    func testToggleRevealsRemoteProvidersEverywhere() {
        setShowRemoteModels(true)
        XCTAssertTrue(AppSettings.showRemoteModels)

        for profileType in ProfileType.allCases {
            let providers = ProfileCapabilityFilter.allowedProviders(for: profileType)
            XCTAssertTrue(providers.contains(.openAI), "\(profileType.rawValue) picker must show OpenAI when revealed")
        }
    }

    func testImageGenPickerHidesOpenAIAndGoogleByDefault() {
        let providers = ProfileCapabilityFilter.allowedProviders(for: .imageGen)
        XCTAssertFalse(providers.contains(.openAI))
        XCTAssertFalse(providers.contains(.google))
        XCTAssertEqual(providers.contains(.mlx), MLXImageGenAvailability.isCompiledIn,
                       "MLX is an image provider only in a build that includes on-device generation")
        XCTAssertTrue(providers.contains(.ollama))
    }

    // MARK: - keepingCurrent (existing profiles stay editable)

    func testKeepingCurrentRestoresHiddenProviderForDisplay() {
        let providers = ProfileCapabilityFilter.allowedProviders(for: .agent, keepingCurrent: .anthropic)
        XCTAssertTrue(providers.contains(.anthropic),
                      "An existing profile configured for a hidden provider must keep it visible")
        XCTAssertFalse(providers.contains(.openAI),
                       "Providers that are NOT the profile's configured value stay hidden")
    }

    func testKeepingCurrentIgnoresVisibleProvider() {
        let providers = ProfileCapabilityFilter.allowedProviders(for: .agent, keepingCurrent: .ollama)
        XCTAssertEqual(providers.filter { $0 == .ollama }.count, 1, "Must not duplicate the current provider")
    }

    // MARK: - Code interface backend selector

    @MainActor
    func testCodeSelectorHidesRemoteProvidersButKeepsCurrentSessionProvider() {
        var segments = ProfileCapabilityFilter.filteringRemoteModels(CodeSessionManager.supportedProviders)
        XCTAssertFalse(segments.contains(.anthropic))
        XCTAssertFalse(segments.contains(.openAI))
        XCTAssertFalse(segments.contains(.google))
        XCTAssertTrue(segments.contains(.ollama))
        XCTAssertTrue(segments.contains(.mlx))

        // An existing Code session on a now-hidden provider keeps its segment.
        segments = ProfileCapabilityFilter.filteringRemoteModels(
            CodeSessionManager.supportedProviders,
            keepingCurrent: .openAI
        )
        XCTAssertTrue(segments.contains(.openAI))
    }

    // MARK: - New imageGen profile default

    func testImageGenDefaultFallsBackToALocalProviderWhileHidden() {
        XCTAssertEqual(ProfileCapabilityFilter.defaultImageGenProvider,
                       MLXImageGenAvailability.isCompiledIn ? .mlx : .ollama,
                       "A new image-gen profile must not open on a hidden provider")
        setShowRemoteModels(true)
        XCTAssertEqual(ProfileCapabilityFilter.defaultImageGenProvider, .openAI,
                       "Historic default returns when remote models are revealed")
    }
}
