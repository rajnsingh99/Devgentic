// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
//
//  ImageGenProviderAvailabilityTests.swift
//  DevgenticTests
//
//  On-device MLX image generation is compiled out unless `MLX_IMAGE_GEN` is set (the
//  flux-2-swift-mlx package held the MLX stack back and was removed). These pin the invariant
//  that matters whichever way the flag is set: the image-generation picker offers only providers
//  the factory can build, and a saved profile on a provider this build lacks is explained, not
//  hidden or crashed.
//

import XCTest
@testable import devgentic

final class ImageGenProviderAvailabilityTests: XCTestCase {

    override func setUp() {
        super.setUp()
        UserDefaults.standard.removeObject(forKey: AppSettings.showRemoteModelsKey)
    }

    override func tearDown() {
        UserDefaults.standard.removeObject(forKey: AppSettings.showRemoteModelsKey)
        super.tearDown()
    }

    private func config(_ provider: ApiProvider) -> ProviderConfig {
        ProviderConfig(apiProvider: provider, modelName: "test-model", apiKey: "test-key")
    }

    /// The invariant. Checked with remote models hidden and revealed, since that toggle changes
    /// the list.
    func testEveryOfferedImageProviderCanBeBuilt() {
        for showRemote in [false, true] {
            UserDefaults.standard.set(showRemote, forKey: AppSettings.showRemoteModelsKey)
            let offered = ProfileCapabilityFilter.allowedProviders(for: .imageGen)
            XCTAssertFalse(offered.isEmpty)
            for provider in offered {
                XCTAssertNoThrow(try ImageGenProviderFactory.create(for: config(provider)),
                                 "the picker offers \(provider.rawValue) (showRemoteModels=\(showRemote)) "
                                 + "but the factory cannot build it")
            }
        }
    }

    /// A new profile opens on its default provider, so that must be buildable too.
    func testTheNewProfileDefaultIsOfferedAndBuildable() {
        for showRemote in [false, true] {
            UserDefaults.standard.set(showRemote, forKey: AppSettings.showRemoteModelsKey)
            let provider = ProfileCapabilityFilter.defaultImageGenProvider
            XCTAssertTrue(ProfileCapabilityFilter.allowedProviders(for: .imageGen).contains(provider),
                          "a new image profile must open on a provider its own picker lists")
            XCTAssertNoThrow(try ImageGenProviderFactory.create(for: config(provider)))
        }
    }

    /// MLX is offered exactly when the factory can build it.
    func testMLXIsOfferedOnlyWhenOnDeviceGenerationIsCompiledIn() {
        UserDefaults.standard.set(true, forKey: AppSettings.showRemoteModelsKey)
        let offered = ProfileCapabilityFilter.allowedProviders(for: .imageGen)
        XCTAssertEqual(offered.contains(.mlx), MLXImageGenAvailability.isCompiledIn)

        if MLXImageGenAvailability.isCompiledIn {
            XCTAssertNoThrow(try ImageGenProviderFactory.create(for: config(.mlx)))
        } else {
            XCTAssertThrowsError(try ImageGenProviderFactory.create(for: config(.mlx))) { error in
                XCTAssertEqual(error.localizedDescription.contains(MLXImageGenAvailability.unavailableMessage), true,
                               "the user must be told why, and what to switch to: \(error.localizedDescription)")
            }
        }
    }

    /// A profile saved while MLX image generation existed keeps MLX in its own picker, so the
    /// selection isn't blank. The editor shows why it can't run.
    func testASavedMLXProfileKeepsItsProviderVisible() {
        let providers = ProfileCapabilityFilter.allowedProviders(for: .imageGen, keepingCurrent: .mlx)
        XCTAssertTrue(providers.contains(.mlx))
        XCTAssertEqual(providers.filter { $0 == .mlx }.count, 1)
    }

    /// The capability badges must not advertise what the factory refuses.
    func testTheAnalyzerAgreesWithTheFactoryAboutMLX() {
        let support = ImageCapabilityAnalyzer.analyze(provider: .mlx, modelName: "flux.2-klein-4b")
        XCTAssertEqual(support.supportsTextToImage, MLXImageGenAvailability.isCompiledIn)
        XCTAssertEqual(support.supportsImageToImage, MLXImageGenAvailability.isCompiledIn)
    }
}
