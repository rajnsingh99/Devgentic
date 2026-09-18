// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
//
//  MLXStoreLifecycleTests.swift
//  DevgenticTests
//
//  Batch 2 (P2 sweep) of the MLX Model Manager readiness plan.
//
//    B10  The scan debounce was 30s, so every explicit Refresh was a no-op for half a
//         minute — while the code comment claimed the window was 2s.
//    B15  `applyFilterAndSort()` re-ran on every download progress tick.
//    B17  The fit verdict was encoded in colour alone.
//

import XCTest
@testable import devgentic

@MainActor
final class MLXScanDebounceTests: XCTestCase {

    private var root: URL!

    override func setUp() async throws {
        try await super.setUp()
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("mlx-debounce-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        if let root { try? FileManager.default.removeItem(at: root) }
        try await super.tearDown()
    }

    @discardableResult
    private func installModel(_ repoId: String) throws -> URL {
        var folder = root.appendingPathComponent("models")
        for part in repoId.components(separatedBy: "/") { folder = folder.appendingPathComponent(part) }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data("{}".utf8).write(to: folder.appendingPathComponent("config.json"))
        try Data("w".utf8).write(to: folder.appendingPathComponent("model.safetensors"))
        return folder
    }

    /// B10. The debounce exists only to absorb the init + onAppear double-fire. At 30s it
    /// swallowed genuine user refreshes: add a model in Finder, press Refresh, nothing.
    ///
    /// ⚠️ This deliberately does NOT assert that a debounced call leaves the list stale.
    /// Since the scan moved off the MainActor (A15), a non-forced call COALESCES onto any
    /// in-flight walk rather than returning early — which is the correct behaviour, because a
    /// caller that returns on an unpopulated list reads it as "nothing installed". The
    /// invariant that matters is the size of the window.
    func testDebounceIsShortEnoughNotToSwallowAUserRefresh() async throws {
        let service = MLXModelService(modelsRootOverride: root)

        // A user pressing Refresh must see their change. Anything on the order of 30s is a
        // bug, not a debounce — it made the button look broken for half a minute.
        XCTAssertLessThanOrEqual(
            service.scanDebounceIntervalForTesting, 5.0,
            "the scan debounce is long enough to make the Refresh button look broken"
        )
    }

    /// The complement: an explicit refresh must always observe a model added behind the
    /// app's back, regardless of when the last scan ran.
    func testAnExplicitRefreshAlwaysSeesAnExternallyAddedModel() async throws {
        let service = MLXModelService(modelsRootOverride: root)
        await service.ensureLoaded()

        try installModel("mlx-community/Added-Externally")
        await service.forceRefreshInstalledModelsAsync()

        XCTAssertTrue(service.isInstalled(repoId: "mlx-community/Added-Externally"))
    }

    /// Explicit refresh must always bypass the debounce.
    func testForceRefreshAlwaysRescans() async throws {
        let service = MLXModelService(modelsRootOverride: root)
        try installModel("mlx-community/Added-Externally")

        await service.forceRefreshInstalledModelsAsync()

        XCTAssertEqual(service.installedModels.map(\.displayName), ["mlx-community/Added-Externally"])
    }
}

// MARK: - B17: the verdict must survive without colour

final class ModelFitBadgeAccessibilityTests: XCTestCase {

    /// Every verdict needs a distinct symbol — the badge previously carried the verdict in
    /// the dot's colour alone, which is invisible to anyone who can't distinguish the hues.
    func testEveryVerdictHasADistinctSymbol() async {
        let verdicts: [ModelFitVerdict] = [.comfortable, .tight, .risky, .incompatible, .unknown]
        let symbols = verdicts.map(\.systemImage)
        XCTAssertEqual(Set(symbols).count, verdicts.count, "two verdicts share a symbol")
        XCTAssertFalse(symbols.contains(where: \.isEmpty), "a verdict has no symbol")
    }

    /// And a distinct name, since the badge renders `verdict.rawValue` as text.
    func testEveryVerdictHasADistinctLabel() async {
        let verdicts: [ModelFitVerdict] = [.comfortable, .tight, .risky, .incompatible, .unknown]
        let names = verdicts.map(\.rawValue)
        XCTAssertEqual(Set(names).count, verdicts.count)
        XCTAssertFalse(names.contains(where: \.isEmpty))
    }
}
