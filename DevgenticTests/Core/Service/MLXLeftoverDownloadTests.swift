// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
//
//  MLXLeftoverDownloadTests.swift
//  DevgenticTests
//
//  Created by Raj Singh.
//

import XCTest
@testable import devgentic

@MainActor
final class MLXLeftoverDownloadTests: XCTestCase {

    private var root: URL!

    override func setUp() async throws {
        try await super.setUp()
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("mlx-leftovers-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        if let root { try? FileManager.default.removeItem(at: root) }
        try await super.tearDown()
    }

    /// A partially downloaded repo in HubApi's real layout: a finished file plus an
    /// `.incomplete` one under the hidden `.cache/huggingface/download/`.
    @discardableResult
    private func makePartial(_ repoId: String, bytes: Int = 4096) throws -> URL {
        let parts = repoId.components(separatedBy: "/")
        let repo = root.appendingPathComponent("models")
            .appendingPathComponent(parts[0]).appendingPathComponent(parts[1])
        let metadata = repo.appendingPathComponent(".cache/huggingface/download")
        try FileManager.default.createDirectory(at: metadata, withIntermediateDirectories: true)
        try Data("{}".utf8).write(to: repo.appendingPathComponent("config.json"))
        try Data(repeating: 0, count: bytes)
            .write(to: metadata.appendingPathComponent("model.safetensors.abc.incomplete"))
        return repo
    }

    private func leftover(_ repoId: String, bytes: Int64) -> MLXModelService.OrphanedPartialDownload {
        .init(repoId: repoId, path: root.appendingPathComponent(repoId), bytes: bytes)
    }

    private let gigabyte: Int64 = 1_000_000_000

    // MARK: - 1. A failure keeps the bytes

    /// Mutation that must turn this red: put `removePartialDownload(repoId:)` back into
    /// `finishFailed`.
    func testAFailedDownloadKeepsWhatItAlreadyFetched() throws {
        let service = MLXModelService(modelsRootOverride: root)
        let repoId = "mlx-community/failing-model"
        let folder = try makePartial(repoId, bytes: 64 * 1024)

        service.finishFailed(repoId: repoId, generation: 0, error: URLError(.networkConnectionLost))

        XCTAssertTrue(FileManager.default.fileExists(atPath: folder.path),
                      "a failure deleted the partial download, so Resume on the failed row starts from zero")
        XCTAssertGreaterThan(MLXModelService.resumableBytes(at: folder), 0)
        XCTAssertNotNil(service.errorMessage, "the failure must still be reported as a failure")
    }

    /// The failed record must stay resumable, or keeping the bytes gives the user nothing to act on.
    func testAFailedRecordOffersResume() {
        XCTAssertTrue(DownloadRecordStatus.failed.isResumable)
    }

    // MARK: - 2. Untracked leftovers

    /// Mutation that must turn this red: drop the `trackedRepoIds` or `downloading` filter.
    func testOnlyLeftoversWithNoHistoryRowAreListedSeparately() {
        let all = [leftover("a/tracked", bytes: 10), leftover("b/untracked", bytes: 20), leftover("c/live", bytes: 30)]

        let untracked = MLXModelService.untracked(all, trackedRepoIds: ["a/tracked"], downloading: "c/live")

        XCTAssertEqual(untracked.map(\.repoId), ["b/untracked"],
                       "a row already shows its own bytes, and the live download is not a leftover")
    }

    // MARK: - 3. The launch notice

    /// Mutation that must turn this red: compare with `>` or drop the threshold.
    func testTheNoticeFiresOnlyPastTheThreshold() {
        XCTAssertNil(MLXModelService.leftoverNotice(for: [leftover("a/small", bytes: gigabyte - 1)], excluding: nil),
                     "under a gigabyte of leftovers is not worth interrupting anyone for")
        XCTAssertNil(MLXModelService.leftoverNotice(for: [], excluding: nil))

        let notice = MLXModelService.leftoverNotice(
            for: [leftover("a/one", bytes: gigabyte / 2), leftover("b/two", bytes: gigabyte / 2)],
            excluding: nil
        )
        XCTAssertEqual(notice, MLXModelService.LeftoverNotice(count: 2, bytes: gigabyte))
    }

    /// Mutation that must turn this red: drop the `downloading` exclusion in `leftoverNotice`.
    func testTheLiveDownloadIsNeverCountedAsALeftover() {
        let notice = MLXModelService.leftoverNotice(
            for: [leftover("a/live", bytes: 50 * gigabyte), leftover("b/old", bytes: 10)],
            excluding: "a/live"
        )
        XCTAssertNil(notice, "the download in progress was counted as leftover disk use")
    }

    /// The notice is raised once, by the launch scan, and never by the routine refreshes after it.
    /// Mutation that must turn this red: stop resetting `announceNextScan`, or announce on every scan.
    func testOnlyTheLaunchScanAnnouncesAndOnlyOnce() {
        let service = MLXModelService(modelsRootOverride: root)
        let big = [leftover("a/big", bytes: 2 * gigabyte)]

        service.applyPartialScan(big)
        XCTAssertNil(service.pendingLeftoverNotice, "a routine refresh must not announce")
        XCTAssertFalse(service.leftoverNeedsAttention)

        service.refreshPartialDownloads(announce: true)   // arms the notice; its own scan races us
        service.applyPartialScan(big)
        XCTAssertEqual(service.pendingLeftoverNotice?.count, 1)
        XCTAssertTrue(service.leftoverNeedsAttention, "the Downloads tab must be badged")

        service.pendingLeftoverNotice = nil               // the root view consumed it
        service.applyPartialScan(big)
        XCTAssertNil(service.pendingLeftoverNotice, "the notice fired twice in one launch")
    }

    /// Mutation that must turn this red: stop clearing `leftoverNeedsAttention` in
    /// `acknowledgeLeftovers`, or when the leftovers fall below the threshold.
    func testTheBadgeClearsWhenSeenOrWhenTheSpaceIsFreed() {
        let service = MLXModelService(modelsRootOverride: root)
        let big = [leftover("a/big", bytes: 2 * gigabyte)]

        service.refreshPartialDownloads(announce: true)
        service.applyPartialScan(big)
        XCTAssertTrue(service.leftoverNeedsAttention)
        service.acknowledgeLeftovers()
        XCTAssertFalse(service.leftoverNeedsAttention, "opening Downloads must clear the badge")

        service.refreshPartialDownloads(announce: true)
        service.applyPartialScan(big)
        XCTAssertTrue(service.leftoverNeedsAttention)
        service.applyPartialScan([])
        XCTAssertFalse(service.leftoverNeedsAttention, "the badge outlived the files it was about")
    }

    /// The published list is what rows read their size from.
    func testRowsReadTheirSizeFromTheLastScan() {
        let service = MLXModelService(modelsRootOverride: root)
        service.applyPartialScan([leftover("a/paused", bytes: 1234)])
        XCTAssertEqual(service.partialBytes(for: "a/paused"), 1234)
        XCTAssertNil(service.partialBytes(for: "b/unknown"))
    }

    /// The launch scan must reach the published list end to end (the wiring, not just the rule).
    /// Mutation that must turn this red: stop publishing in `applyPartialScan`, or stop
    /// `refreshPartialDownloads` from calling it.
    func testARefreshPublishesWhatIsOnDisk() async throws {
        let service = MLXModelService(modelsRootOverride: root)
        try makePartial("mlx-community/on-disk", bytes: 8192)

        service.refreshPartialDownloads()
        let deadline = Date().addingTimeInterval(10)
        while service.partialDownloads.isEmpty, Date() < deadline {
            try await Task.sleep(for: .milliseconds(50))
        }
        XCTAssertEqual(service.partialDownloads.map(\.repoId), ["mlx-community/on-disk"])
    }

    // MARK: - 4. Deleting a leftover

    func testDeletingALeftoverFreesItsBytes() throws {
        let service = MLXModelService(modelsRootOverride: root)
        let folder = try makePartial("mlx-community/leftover", bytes: 8192)
        let found = service.findOrphanedPartialDownloads()
        XCTAssertEqual(found.count, 1)

        let freed = service.discardLeftovers(found)

        XCTAssertFalse(FileManager.default.fileExists(atPath: folder.path))
        XCTAssertEqual(freed, found[0].bytes)
    }

    /// Mutation that must turn this red: drop the `currentDownloadName` guard in `discardLeftover`.
    func testTheDownloadInProgressCannotBeDeletedAsALeftover() throws {
        let service = MLXModelService(modelsRootOverride: root)
        let repoId = "mlx-community/live"
        let folder = try makePartial(repoId)
        service.isDownloading = true
        service.currentDownloadName = repoId

        let removed = service.discardLeftover(leftover(repoId, bytes: 4096))

        XCTAssertFalse(removed)
        XCTAssertTrue(FileManager.default.fileExists(atPath: folder.path),
                      "deleting a leftover deleted the bytes of the download still writing into it")
    }

    /// A complete install is never a leftover, even if a stale list names it.
    func testACompleteInstallIsNeverDeletedAsALeftover() throws {
        let service = MLXModelService(modelsRootOverride: root)
        let folder = root.appendingPathComponent("models/mlx-community/installed")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data("{}".utf8).write(to: folder.appendingPathComponent("config.json"))
        try Data("w".utf8).write(to: folder.appendingPathComponent("model.safetensors"))

        XCTAssertFalse(service.discardLeftover(leftover("mlx-community/installed", bytes: 1)))
        XCTAssertTrue(FileManager.default.fileExists(atPath: folder.path))
    }

    // MARK: - Wiring pins

    /// The UI must actually use these. Each pin is what a refactor would silently drop.
    func testTheUIIsWiredToTheLeftoverState() throws {
        let manager = try Self.source("Devgentic/Interfaces/Main/Views/DownloadManagerContainerView.swift")
        XCTAssertTrue(manager.contains("LeftoverDownloadsSection(leftovers: leftovers)"),
                      "the Download Manager no longer lists untracked leftovers")
        XCTAssertTrue(manager.contains("MLXModelService.shared.acknowledgeLeftovers()"))
        XCTAssertTrue(manager.contains("partialBytes(for: record.modelIdentifier)"),
                      "history cards no longer show their size on disk")

        let app = try Self.source("Devgentic/DevgenticApp.swift")
        XCTAssertTrue(app.contains("MLXModelService.scanPartialDownloadsAtLaunch()"),
                      "the launch scan is gone, so the user is never told")
        XCTAssertTrue(app.contains("LeftoverDownloadNoticeModifier(toastManager: toastManager)"),
                      "nothing turns the launch notice into a toast")

        let bar = try Self.source("Devgentic/Interfaces/Main/Views/Sidebar/ActivityBar.swift")
        XCTAssertTrue(bar.contains("MLXModelService.shared.leftoverNeedsAttention"),
                      "the Downloads tab is no longer badged for leftovers")
    }

    func testTheNoticeNamesTheCountAndSize() {
        let one = LeftoverDownloadNoticeModifier.message(for: .init(count: 1, bytes: 2 * gigabyte))
        let many = LeftoverDownloadNoticeModifier.message(for: .init(count: 3, bytes: 12 * gigabyte))
        XCTAssertTrue(one.hasPrefix("1 unfinished download is"), one)
        XCTAssertTrue(many.hasPrefix("3 unfinished downloads are"), many)
        XCTAssertTrue(many.contains(ByteCountFormatter.string(fromByteCount: 12 * gigabyte, countStyle: .file)), many)
    }

    private static func source(_ relativePath: String) throws -> String {
        let repoRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // Service
            .deletingLastPathComponent()   // Core
            .deletingLastPathComponent()   // DevgenticTests
            .deletingLastPathComponent()   // repo root
        let url = repoRoot.appendingPathComponent(relativePath)
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw XCTSkip("\(relativePath) not reachable from \(repoRoot.path) — running outside a checkout")
        }
        return try String(contentsOf: url, encoding: .utf8)
    }
}
