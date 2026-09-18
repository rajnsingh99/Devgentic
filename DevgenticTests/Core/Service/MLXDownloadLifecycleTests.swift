// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
//
//  MLXDownloadLifecycleTests.swift
//  DevgenticTests
//
//  Regression cover for Batch 0 of the MLX Model Manager production-readiness audit
//  (2026-08-03). These four defects mask each other, so they were fixed together and are
//  pinned together:
//
//    A1  `partialDownloadFolder` rebuilt HubApi's destination by hand and omitted the
//        `models` path component, making `removePartialDownload` a permanent silent no-op.
//    A4  `downloadModel` pre-empted any in-flight pull instead of refusing.
//    A5  Cancellation was classified off `CancellationError`, which HubApi never throws.
//    A6  No terminal branch cleared `downloadTask` / `currentDownloadName`, so the next
//        download's cleanup targeted the previous — and once A1 was fixed, that cleanup
//        would have deleted a fully-installed multi-gigabyte model.
//
//  Every test runs against a temp directory via `MLXModelService(modelsRootOverride:)`.
//  ⚠️ Never point these at the real Application Support tree: `removePartialDownload` is a
//  recursive delete and the user's real models live there.
//

import XCTest
import Hub
@testable import devgentic

@MainActor
final class MLXDownloadLifecycleTests: XCTestCase {

    private var root: URL!

    override func setUp() async throws {
        try await super.setUp()
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("mlx-download-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        if let root { try? FileManager.default.removeItem(at: root) }
        try await super.tearDown()
    }

    private func makeService() -> MLXModelService {
        MLXModelService(modelsRootOverride: root)
    }

    /// Creates `<root>/models/<author>/<name>/` — the layout HubApi actually writes —
    /// with the given files, and returns the repo folder.
    @discardableResult
    private func makeRepoFolder(_ repoId: String, files: [String]) throws -> URL {
        let parts = repoId.components(separatedBy: "/")
        let folder = root
            .appendingPathComponent("models")
            .appendingPathComponent(parts[0])
            .appendingPathComponent(parts[1])
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        for file in files {
            try Data("x".utf8).write(to: folder.appendingPathComponent(file))
        }
        return folder
    }

    // MARK: - A1: the path contract

    /// ⚠️ THE test for A1. `HubApi.localRepoLocation` is
    /// `downloadBase/<repo.type.rawValue>/<repo.id>` and `RepoType.models.rawValue` is
    /// `"models"`, so the real destination carries a DOUBLED component:
    /// `<base>/models/<author>/<name>`. Hand-rebuilding that path dropped the `models`
    /// component and broke cleanup silently for months.
    ///
    /// This asserts the vendored dependency's layout directly, so a swift-transformers
    /// upgrade that changes it fails here rather than silently resurrecting the leak.
    func testHubApiWritesUnderADoubledModelsComponent() async {
        let base = URL(fileURLWithPath: "/tmp/base")
        let resolved = HubApi(downloadBase: base)
            .localRepoLocation(Hub.Repo(id: "mlx-community/Qwen2.5-3B-Instruct-4bit"))

        XCTAssertEqual(
            resolved.path,
            "/tmp/base/models/mlx-community/Qwen2.5-3B-Instruct-4bit",
            "HubApi's on-disk layout changed. Anything that reasons about the download path must be updated."
        )
    }

    /// The service must delegate to the library rather than reconstruct, so the two
    /// cannot drift apart again.
    func testPartialDownloadFolderMatchesTheLibraryResolver() async throws {
        let service = makeService()
        let repoId = "mlx-community/Qwen2.5-3B-Instruct-4bit"

        let derived = try XCTUnwrap(service.partialDownloadFolder(for: repoId))
        let expected = service.hub.localRepoLocation(Hub.Repo(id: repoId))

        XCTAssertEqual(derived.standardizedFileURL, expected.standardizedFileURL)
        XCTAssertTrue(
            derived.pathComponents.contains("models"),
            "The `models` component is missing — this is exactly the A1 regression."
        )
    }

    func testPartialDownloadFolderRejectsMalformedRepoIds() async {
        let service = makeService()
        for bad in ["", "no-slash", "a/", "/b", "a/b/c", "/"] {
            XCTAssertNil(
                service.partialDownloadFolder(for: bad),
                "'\(bad)' is not a valid author/name repo id and must not resolve to a deletable path"
            )
        }
    }

    /// End-to-end regression: before the fix this deleted nothing because it looked at
    /// `<root>/<author>/<name>` while HubApi had written `<root>/models/<author>/<name>`.
    func testRemovePartialDownloadActuallyDeletesTheRealFolder() async throws {
        let service = makeService()
        let repoId = "mlx-community/aborted-pull"
        let folder = try makeRepoFolder(repoId, files: ["config.json"])
        XCTAssertTrue(FileManager.default.fileExists(atPath: folder.path))

        service.removePartialDownload(repoId: repoId)

        XCTAssertFalse(
            FileManager.default.fileExists(atPath: folder.path),
            "Partial folder survived cleanup — the A1 path bug is back."
        )
    }

    // MARK: - A6: never delete a completed install

    /// The cleanup path is reachable with a stale repo id. Since it is a recursive delete
    /// of a multi-gigabyte folder, it must refuse anything that is a completed install.
    func testRemovePartialDownloadRefusesAnInstalledModel() async throws {
        let service = makeService()
        let repoId = "mlx-community/fully-installed"
        let folder = try makeRepoFolder(repoId, files: ["config.json", "model.safetensors"])

        // ⚠️ `refreshInstalledModels()` is debounced for 30s and `init` already consumed
        // the window, so it would silently no-op here. Always force in tests.
        await service.forceRefreshInstalledModelsAsync()
        XCTAssertTrue(
            service.installedModels.contains { $0.localPath.standardizedFileURL == folder.standardizedFileURL },
            "precondition: the scan should have found this as installed"
        )

        service.removePartialDownload(repoId: repoId)

        XCTAssertTrue(
            FileManager.default.fileExists(atPath: folder.path),
            "A completed install was deleted by the partial-download cleanup — this is the A1+A6 destructive interaction."
        )
    }

    /// A6 proper: every terminal branch must clear the handles, so a later
    /// `cancelDownload()` cannot capture a stale repo id.
    func testCancelWithAStaleHandleClearsWithoutRunningCleanup() async throws {
        let service = makeService()
        let repoId = "mlx-community/previously-installed"
        let folder = try makeRepoFolder(repoId, files: ["config.json", "model.safetensors"])
        await service.forceRefreshInstalledModelsAsync()

        // Simulate the pre-fix state: a finished download that left its name behind
        // while `isDownloading` has already gone false.
        service.currentDownloadName = repoId
        service.isDownloading = false

        service.cancelDownload()

        XCTAssertTrue(
            FileManager.default.fileExists(atPath: folder.path),
            "cancelDownload ran cleanup against a stale repo id and deleted an installed model"
        )
        XCTAssertEqual(service.currentDownloadName, "", "the stale handle should have been cleared")
    }

    // MARK: - A4: refuse, don't pre-empt

    func testDownloadRefusesADifferentRepoWhileOneIsInFlight() async {
        let service = makeService()
        service.isDownloading = true
        service.currentDownloadName = "mlx-community/model-A"

        let accepted = service.downloadModel(repoId: "mlx-community/model-B")

        XCTAssertFalse(accepted, "a second concurrent MLX download must be refused, not pre-empt the first")
        XCTAssertEqual(
            service.currentDownloadName, "mlx-community/model-A",
            "the in-flight download's identity must survive the refused request"
        )
        XCTAssertTrue(service.isDownloading)
    }

    /// The refusal must NOT write `errorMessage`: DownloadManager reads that field to
    /// classify the ACTIVE download's terminal state, so a refusal message there would
    /// mark the still-running model as failed when it later completes.
    func testRefusalDoesNotPoisonTheActiveDownloadsErrorState() async {
        let service = makeService()
        service.isDownloading = true
        service.currentDownloadName = "mlx-community/model-A"
        service.errorMessage = nil

        _ = service.downloadModel(repoId: "mlx-community/model-B")

        XCTAssertNil(
            service.errorMessage,
            "a refused request set errorMessage, which would make the running download record as failed"
        )
    }

    func testDuplicateRequestForTheSameRepoIsRefused() async {
        let service = makeService()
        service.isDownloading = true
        service.currentDownloadName = "mlx-community/model-A"

        XCTAssertFalse(service.downloadModel(repoId: "mlx-community/model-A"))
    }

    // MARK: - A5: cancellation classification

    /// swift-transformers surfaces a cancel as `URLError(.cancelled)`, not
    /// `CancellationError` — which is why the old `catch where error is CancellationError`
    /// arm was dead and user cancels were persisted as "Failed: cancelled".
    func testCancellationRecognisesBothShapes() async {
        XCTAssertTrue(MLXModelService.isCancellation(CancellationError()))
        XCTAssertTrue(MLXModelService.isCancellation(URLError(.cancelled)))
    }

    func testGenuineFailuresAreNotMisreadAsCancellation() async {
        XCTAssertFalse(MLXModelService.isCancellation(URLError(.timedOut)))
        XCTAssertFalse(MLXModelService.isCancellation(URLError(.notConnectedToInternet)))
        XCTAssertFalse(MLXModelService.isCancellation(NSError(domain: "test", code: 1)))
    }

    // MARK: - Orphan detection

    func testOrphanScanFindsWeightlessFoldersAndSkipsRealInstalls() async throws {
        let service = makeService()
        try makeRepoFolder("mlx-community/partial-one", files: ["config.json"])
        try makeRepoFolder("lmstudio-community/partial-two", files: ["config.json", "tokenizer.json"])
        try makeRepoFolder("mlx-community/complete", files: ["config.json", "model.safetensors"])

        let orphans = service.findOrphanedPartialDownloads()
        let ids = Set(orphans.map(\.repoId))

        XCTAssertEqual(ids, ["mlx-community/partial-one", "lmstudio-community/partial-two"])
        XCTAssertFalse(ids.contains("mlx-community/complete"), "a folder with weights is an install, not residue")
    }

    /// Detection is read-only — the launch path calls it, so it must never delete.
    func testOrphanScanIsNonDestructive() async throws {
        let service = makeService()
        let folder = try makeRepoFolder("mlx-community/partial-one", files: ["config.json"])

        _ = service.findOrphanedPartialDownloads()

        XCTAssertTrue(FileManager.default.fileExists(atPath: folder.path))
    }

    func testExplicitReclaimRemovesOrphansAndReportsBytes() async throws {
        let service = makeService()
        let partial = try makeRepoFolder("mlx-community/partial-one", files: ["config.json"])
        let complete = try makeRepoFolder("mlx-community/complete", files: ["config.json", "model.safetensors"])

        let reclaimed = service.reclaimOrphanedPartialDownloads()

        XCTAssertFalse(FileManager.default.fileExists(atPath: partial.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: complete.path), "reclaim must not touch real installs")
        XCTAssertGreaterThan(reclaimed, 0)
    }
}
