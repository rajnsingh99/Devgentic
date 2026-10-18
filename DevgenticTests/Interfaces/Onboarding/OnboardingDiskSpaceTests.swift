// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
//
//  OnboardingDiskSpaceTests.swift
//  DevgenticTests
//
//  Created by Raj Singh.
//

import XCTest
@testable import devgentic

@MainActor
final class OnboardingDiskSpaceTests: XCTestCase {

    private let gb: Int64 = 1_000_000_000

    /// 16 GB of RAM → the recommended (pre-selected) model is Qwen3.5 9B on MLX (~6 GB).
    private func make(free: [ApiProvider: Int64]) -> (OnboardingViewModel, FakeOnboardingSystemSettings) {
        let settings = FakeOnboardingSystemSettings()
        settings.availableBytes = free
        let vm = OnboardingViewModel(physicalMemoryBytes: 16 * 1_073_741_824, checksInstallStatus: false, systemSettings: settings)
        vm.refreshDiskSpace()
        return (vm, settings)
    }

    func testTheRequirementIsTheDownloadPlusHeadroom() {
        let tiny = OnboardingStarterCatalog.mlxModels[0]          // ~1.7 GB → 1 GiB headroom wins
        XCTAssertEqual(OnboardingViewModel.requiredDiskBytes(for: tiny), tiny.downloadBytes + 1_073_741_824)
        let medium = OnboardingStarterCatalog.ollamaModels[4]     // ~17.8 GB → 10% wins
        XCTAssertEqual(OnboardingViewModel.requiredDiskBytes(for: medium), medium.downloadBytes + medium.downloadBytes / 10)
    }

    /// Free space that cannot be read must never block — a guess must not strand the user.
    func testUnknownFreeSpaceNeverBlocks() {
        let (vm, _) = make(free: [:])
        XCTAssertNil(vm.availableDiskBytes)
        XCTAssertTrue(vm.selectedModelFitsOnDisk)
        XCTAssertFalse(vm.noModelFitsOnDisk)
        XCTAssertFalse(vm.canSkipDownload)
    }

    /// Wiring: a model that does not fit is refused before anything is fetched, and the refusal
    /// does not use up a retry.
    func testADownloadThatDoesNotFitIsRefusedWithoutCountingAsAFailure() {
        let (vm, _) = make(free: [.mlx: 5 * gb])
        XCTAssertEqual(vm.selectedModel?.sizeClass, "Balanced")
        XCTAssertFalse(vm.selectedModelFitsOnDisk, "~6 GB + headroom must not fit in 5 GB")

        vm.startModelDownload()

        XCTAssertFalse(vm.isDownloading, "a download that cannot fit must not start")
        XCTAssertEqual(vm.failedDownloadAttempts, 0, "a refused start is not a failed attempt")
        XCTAssertFalse(vm.noModelFitsOnDisk, "smaller models still fit")
        XCTAssertFalse(vm.canSkipDownload, "with a smaller model available, the user picks it rather than skips")
    }

    func testWhenNothingFitsSkipIsOffered() {
        let (vm, _) = make(free: [.mlx: 1 * gb])
        XCTAssertTrue(vm.noModelFitsOnDisk)
        XCTAssertTrue(vm.canSkipDownload)

        vm.skipModelDownload()

        XCTAssertTrue(vm.didSkipDownload)
        XCTAssertEqual(vm.currentStep, .behavior)
    }

    /// Each engine downloads to its own place, so switching re-reads that engine's volume.
    func testSwitchingEngineChecksThatEnginesVolume() {
        let (vm, _) = make(free: [.mlx: 500 * gb, .ollama: 1 * gb])
        XCTAssertTrue(vm.selectedModelFitsOnDisk)

        vm.selectBackend(.ollama)

        XCTAssertEqual(vm.availableDiskBytes, 1 * gb)
        XCTAssertTrue(vm.noModelFitsOnDisk)
    }

    /// An already-downloaded selection needs no space at all.
    func testAnInstalledModelNeedsNoSpace() {
        let (vm, _) = make(free: [.mlx: 1 * gb])
        vm.isModelInstalled = true
        XCTAssertTrue(vm.selectedModelFitsOnDisk)
        XCTAssertFalse(vm.canSkipDownload, "nothing to skip — it is already downloaded")
    }

    /// The live reading is real and read-only: it must return a positive number for the local
    /// engines and nil for anything that does not download.
    func testTheLiveReadingReturnsFreeSpaceForLocalEngines() throws {
        let live = LiveOnboardingSystemSettings()
        let mlx = try XCTUnwrap(live.availableDiskBytes(for: .mlx), "could not read free space for MLX")
        XCTAssertGreaterThan(mlx, 0)
        XCTAssertNotNil(live.availableDiskBytes(for: .ollama))
        XCTAssertNil(live.availableDiskBytes(for: .openAI))
    }
}
