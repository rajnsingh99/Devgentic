// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2026 Raj Singh
//
//  MLXInstalledStateTests.swift
//  DevgenticTests
//
//  G11 — MLX cards never rendered the shared component's Installed state, so MLX was the only
//  backend without a Re-download affordance: to re-pull a model the user had to delete it and
//  find it again.
//
//  The subtle part is the interaction with A7. `ModelDownloadStatusView` lets a host intercept
//  the download via `onDownloadRequested` (MLX uses it for the RAM-fit advisory). Once MLX
//  supplies that hook, an unconditional interception would swallow the `force` flag and turn
//  Re-download back into the no-op A7 fixed.
//

import XCTest
@testable import devgentic

@MainActor
final class MLXInstalledStateTests: XCTestCase {

    private var root: URL!

    override func setUp() async throws {
        try await super.setUp()
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("mlx-installed-state-\(UUID().uuidString)")
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

    /// THE G11↔A7 interaction. Once MLX supplies `onDownloadRequested` (for its RAM-fit
    /// advisory), an unconditional interception would swallow the `force` flag: the host's
    /// closure calls the coordinator without it, the install check short-circuits, and
    /// Re-download becomes the no-op A7 existed to fix.
    func testAForcedRedownloadIsNeverDelegatedToTheHostHook() {
        XCTAssertFalse(
            ModelDownloadStatusView.shouldDelegateToHost(force: true, hasHook: true),
            "a forced re-download was diverted into the host's advisory hook, which drops `force`"
        )
    }

    /// A fresh pull still goes through the hook — that is how the fit advisory gets to warn
    /// before a multi-gigabyte download starts.
    func testAFreshPullIsDelegatedWhenAHookExists() {
        XCTAssertTrue(ModelDownloadStatusView.shouldDelegateToHost(force: false, hasHook: true))
    }

    /// Backends with no hook (Ollama, Whisper) always go straight to the coordinator.
    func testWithoutAHookNothingIsDelegated() {
        XCTAssertFalse(ModelDownloadStatusView.shouldDelegateToHost(force: false, hasHook: false))
        XCTAssertFalse(ModelDownloadStatusView.shouldDelegateToHost(force: true, hasHook: false))
    }

    /// The installed check itself is the coordinator's job and is covered by
    /// `MLXModelServiceIdentityTests`; here we only pin that the scan resolves the model.
    func testAnInstalledModelResolvesForTheCard() async throws {
        try installModel("mlx-community/already-here")
        let service = MLXModelService(modelsRootOverride: root)
        await service.ensureLoaded()

        XCTAssertTrue(service.isInstalled(repoId: "mlx-community/already-here"))
    }

    /// The IC selection is MLX-specific and belongs to the Installed tab only; the shared
    /// component owns everything else. Pin the tab semantics the card relies on.
    func testInstalledTabIsTheOnlyCategoryWithoutARemoteCapability() {
        XCTAssertNil(MLXModelStoreViewModel.StoreCategory.installed.clientCapability)
        XCTAssertNil(MLXModelStoreViewModel.StoreCategory.all.clientCapability)
        XCTAssertEqual(MLXModelStoreViewModel.StoreCategory.toolUse.clientCapability, .toolUse)
    }

    /// Every category remains reachable — the A18 guarantee the card's layout depends on.
    ///
    /// ⚠️ Rewritten 2026-08-03. This built a real `MLXModelStoreViewModel`, which binds to the
    /// process-wide `MLXModelService.shared` — so it walked the developer's actual model
    /// library, fired live HuggingFace requests from its `init`, and left an observer attached
    /// to the singleton for the rest of the run. It then asserted
    /// `Set(vm.availableCategories) == Set(StoreCategory.allCases)`, and since
    /// `availableCategories` IS `allCases`, that compared a value to itself. All of that cost,
    /// to assert nothing. Naming the expected members is what gives it content: dropping
    /// `.recommended` or `.installed` now fails.
    func testAllCategoriesRemainAvailable() {
        XCTAssertEqual(
            Set(MLXModelStoreViewModel.StoreCategory.allCases),
            [.installed, .recommended, .all, .reasoning, .toolUse, .coding, .vision],
            "a store category was added or removed — confirm the store's tab row still covers it"
        )
    }
}
