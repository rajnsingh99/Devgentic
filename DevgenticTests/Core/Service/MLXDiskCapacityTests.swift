// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2026 Raj Singh
//
//  MLXDiskCapacityTests.swift
//  DevgenticTests
//
//  Milestone M1 — "Don't fill the user's disk".
//
//    G1  The exact download size was already fetched and used only as an ETA denominator;
//        nothing compared it to free space. The store's own top-30 MLX listing includes a
//        657 GB repo, so on a 512 GB laptop the pull filled the startup volume.
//    G3  Installed models were mapped with `size: nil`, so the app could not report the
//        76 GB it was occupying, or which model was the large one.
//

import XCTest
@testable import devgentic

@MainActor
final class MLXDiskCapacityTests: XCTestCase {

    private var root: URL!

    override func setUp() async throws {
        try await super.setUp()
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("mlx-disk-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        if let root { try? FileManager.default.removeItem(at: root) }
        try await super.tearDown()
    }

    // MARK: - G1

    func testAvailableCapacityIsReadableForARealVolume() async throws {
        let free = try XCTUnwrap(
            MLXModelService.availableBytes(onVolumeContaining: root),
            "could not read free space for a temp directory on a real volume"
        )
        XCTAssertGreaterThan(free, 0)
    }

    /// A download that cannot fit must be refused. Uses a deliberately absurd size so the
    /// assertion holds regardless of the test machine's actual free space.
    func testAnImpossiblyLargeDownloadDoesNotFit() async throws {
        let service = MLXModelService(modelsRootOverride: root)
        let exabyte: Int64 = 1_000_000_000_000_000_000

        let room = try XCTUnwrap(service.hasRoomForDownload(ofBytes: exabyte))
        XCTAssertFalse(room.fits, "an exabyte download was reported as fitting")
        XCTAssertGreaterThan(room.free, 0)
    }

    /// A trivial download must not be refused — the guard has to stay out of the way of
    /// ordinary use, or users will hit false refusals on a healthy disk.
    func testASmallDownloadFits() async throws {
        let service = MLXModelService(modelsRootOverride: root)
        let oneMegabyte: Int64 = 1024 * 1024

        let room = try XCTUnwrap(service.hasRoomForDownload(ofBytes: oneMegabyte))
        XCTAssertTrue(room.fits, "a 1 MB download was refused — the headroom margin is wrong")
    }

    /// Unknown or nonsensical sizes must return nil so the caller PROCEEDS. A failed stat
    /// must never block a legitimate download.
    func testUnknownSizeYieldsNoVerdict() async {
        let service = MLXModelService(modelsRootOverride: root)
        XCTAssertNil(service.hasRoomForDownload(ofBytes: 0))
        XCTAssertNil(service.hasRoomForDownload(ofBytes: -1))
    }

    /// The headroom exists so a download cannot drive the startup volume to zero, where
    /// macOS degrades badly. It must be a real margin, not a token one.
    func testHeadroomIsAMeaningfulMargin() async {
        XCTAssertGreaterThanOrEqual(MLXModelService.diskHeadroomBytes, 1024 * 1024 * 1024)
    }

    // MARK: - G3

    /// Directory sizing must report real bytes — it backs both the storage summary and the
    /// "this reclaims N GB" delete confirmation.
    func testDirectorySizeSumsFileBytes() async throws {
        let folder = root.appendingPathComponent("models/mlx-community/Sized")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data(repeating: 0, count: 128 * 1024).write(to: folder.appendingPathComponent("model.safetensors"))
        try Data(repeating: 0, count: 8 * 1024).write(to: folder.appendingPathComponent("config.json"))

        let size = MLXModelService.directorySize(at: folder)
        XCTAssertGreaterThanOrEqual(size, 136 * 1024, "sizing under-reported the files on disk")
    }

    func testDirectorySizeOfAMissingPathIsZeroRatherThanACrash() async {
        XCTAssertEqual(MLXModelService.directorySize(at: root.appendingPathComponent("nope")), 0)
    }

    /// The sizing pass runs in the background, so it is absent immediately after a scan and
    /// appears once it lands. Both states must be well-defined: nil means "not known yet",
    /// never "zero bytes".
    func testTotalIsNilBeforeTheSizingPassCompletes() async throws {
        let service = MLXModelService(modelsRootOverride: root)
        XCTAssertNil(service.totalInstalledBytes,
                     "an empty library must report nil, not 0 — the UI hides the row on nil")
    }

    func testInstalledSizesArePublishedAfterAScan() async throws {
        let folder = root.appendingPathComponent("models/mlx-community/Sized")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data(repeating: 0, count: 64 * 1024).write(to: folder.appendingPathComponent("model.safetensors"))
        try Data("{}".utf8).write(to: folder.appendingPathComponent("config.json"))

        let service = MLXModelService(modelsRootOverride: root)
        await service.forceRefreshInstalledModelsAsync()
        XCTAssertEqual(service.installedModels.count, 1, "precondition: the model should be found")

        // The sizing pass is detached; poll briefly rather than assuming a fixed delay.
        var total: Int64?
        for _ in 0..<50 {
            if let t = service.totalInstalledBytes { total = t; break }
            try await Task.sleep(nanoseconds: 20_000_000)
        }

        let sized = try XCTUnwrap(total, "the background sizing pass never published a total")
        XCTAssertGreaterThanOrEqual(sized, 64 * 1024)
    }
}
