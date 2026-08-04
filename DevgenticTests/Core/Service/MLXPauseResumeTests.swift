//
//  MLXPauseResumeTests.swift
//  DevgenticTests
//
//  G2 — pause/resume. swift-transformers already resumes from `.incomplete` files via a
//  `Range: bytes=N-` header; the only thing that made resume impossible was that the sole stop
//  control deleted the repo folder, and the `.incomplete` files live inside it at
//  `<repo>/.cache/huggingface/download/`.
//
//  The invariant these tests exist to protect: **Pause keeps the bytes, Cancel discards them.**
//

import XCTest
@testable import devgentic

@MainActor
final class MLXPauseResumeTests: XCTestCase {

    private var root: URL!

    override func setUp() async throws {
        try await super.setUp()
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("mlx-pause-resume-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        if let root { try? FileManager.default.removeItem(at: root) }
        try await super.tearDown()
    }

    /// Builds a partially-downloaded repo in HubApi's real layout: a completed file plus an
    /// `.incomplete` file under the hidden `.cache/huggingface/download/` subdirectory.
    @discardableResult
    private func makePartialDownload(_ repoId: String, incompleteBytes: Int) throws -> URL {
        let parts = repoId.components(separatedBy: "/")
        let repo = root
            .appendingPathComponent("models")
            .appendingPathComponent(parts[0])
            .appendingPathComponent(parts[1])
        let metadata = repo
            .appendingPathComponent(".cache")
            .appendingPathComponent("huggingface")
            .appendingPathComponent("download")
        try FileManager.default.createDirectory(at: metadata, withIntermediateDirectories: true)
        try Data("{}".utf8).write(to: repo.appendingPathComponent("config.json"))
        try Data(repeating: 0, count: incompleteBytes)
            .write(to: metadata.appendingPathComponent("model.safetensors.abc123.incomplete"))
        return repo
    }

    // MARK: - The core invariant

    /// Builds a *sharded* repo with only some of its shards present — exactly the shape
    /// HubApi leaves behind when a multi-shard pull is interrupted. It moves each finished
    /// shard to its FINAL path before fetching the next, so a half-done sharded download is
    /// a folder that genuinely contains weights.
    @discardableResult
    private func makeShardedDownload(_ repoId: String, present: Int, expected: Int) throws -> URL {
        let parts = repoId.components(separatedBy: "/")
        let repo = root
            .appendingPathComponent("models")
            .appendingPathComponent(parts[0])
            .appendingPathComponent(parts[1])
        try FileManager.default.createDirectory(at: repo, withIntermediateDirectories: true)
        try Data("{}".utf8).write(to: repo.appendingPathComponent("config.json"))

        let names = (1...expected).map {
            String(format: "model-%05d-of-%05d.safetensors", $0, expected)
        }
        // `weight_map` is tensor-name → shard-file; the shard set is its values.
        let weightMap = Dictionary(uniqueKeysWithValues: names.enumerated().map {
            ("layer.\($0.offset).weight", $0.element)
        })
        let index = try JSONSerialization.data(withJSONObject: ["weight_map": weightMap])
        try index.write(to: repo.appendingPathComponent("model.safetensors.index.json"))

        for name in names.prefix(present) {
            try Data(repeating: 0, count: 2048).write(to: repo.appendingPathComponent(name))
        }
        return repo
    }

    /// Pause must leave every byte in place. This is the entire feature: the bytes ARE the
    /// resume state, and HubApi reads them back via `incompleteFileSize(at:)`.
    ///
    /// ⚠️ This drives the real `pauseDownload()`. It previously only assigned state flags and
    /// asserted that a folder it had just created still existed — which stayed green even
    /// with `removePartialDownload` reinstated inside `pauseDownload`, i.e. it did not cover
    /// the invariant it was named for.
    func testPauseKeepsPartialFiles() throws {
        let service = MLXModelService(modelsRootOverride: root)
        let repoId = "mlx-community/half-done"
        let repo = try makePartialDownload(repoId, incompleteBytes: 64 * 1024)

        let inflight = Task<Void, Never> { try? await Task.sleep(nanoseconds: 30_000_000_000) }
        defer { inflight.cancel() }
        service.downloadTask = inflight
        service.isDownloading = true
        service.currentDownloadName = repoId

        XCTAssertTrue(service.pauseDownload(), "pause must succeed while a download is in flight")

        XCTAssertTrue(
            FileManager.default.fileExists(atPath: repo.path),
            "pausing must never remove the partial download — that is what Cancel is for"
        )
        XCTAssertGreaterThan(
            MLXModelService.resumableBytes(at: service.partialDownloadFolder(for: repoId)), 0
        )
        XCTAssertEqual(service.pausedRepoId, repoId, "the bridge classifies on this marker")
        XCTAssertFalse(service.isDownloading, "pause releases the slot")
    }

    // MARK: - Reclaiming a truncated sharded download

    /// The guard on the reclaim path must test COMPLETENESS, not "has weights". Gating on
    /// `containsWeights` made cleanup a no-op for every sharded repo — the interrupted state
    /// is precisely a folder holding some finished shards — so cancelling a large pull
    /// stranded gigabytes that no UI could reach.
    func testCancelReclaimsTruncatedShardedDownload() throws {
        let service = MLXModelService(modelsRootOverride: root)
        let repoId = "mlx-community/five-shards"
        let repo = try makeShardedDownload(repoId, present: 2, expected: 5)

        XCTAssertTrue(
            MLXModelService.containsWeights(at: repo),
            "precondition: finished shards are real weights files — this is why the old guard fired"
        )
        XCTAssertFalse(
            MLXModelService.isCompleteInstall(at: repo),
            "2 of 5 shards is not an install"
        )

        XCTAssertTrue(
            service.removePartialDownload(repoId: repoId),
            "a truncated sharded download is residue and its bytes must be reclaimed"
        )
        XCTAssertFalse(FileManager.default.fileExists(atPath: repo.path))
    }

    /// The counterpart, so the guard is not vacuously permissive: a COMPLETE install is still
    /// refused. It is visible in the installed list and reclaimed via its own Delete button.
    func testRemoveRefusesCompleteShardedInstall() throws {
        let service = MLXModelService(modelsRootOverride: root)
        let repoId = "mlx-community/all-five-shards"
        let repo = try makeShardedDownload(repoId, present: 5, expected: 5)

        XCTAssertTrue(MLXModelService.isCompleteInstall(at: repo))
        XCTAssertFalse(
            service.removePartialDownload(repoId: repoId),
            "a complete install must never be deleted by the partial-download cleanup path"
        )
        XCTAssertTrue(FileManager.default.fileExists(atPath: repo.path))
    }

    /// Discard reports whether the bytes actually went away. The sidebar deletes the history
    /// row on true only — that row is the last remaining handle on a hidden partial folder.
    func testDiscardReportsRefusalSoTheHistoryRowSurvives() throws {
        let service = MLXModelService(modelsRootOverride: root)
        let repoId = "mlx-community/complete-not-partial"
        try makeShardedDownload(repoId, present: 3, expected: 3)

        XCTAssertFalse(
            service.discardPartialDownload(repoId: repoId),
            "discard must report failure when it reclaimed nothing"
        )
    }

    /// The orphan scan and the cleanup guard must agree on what an install is. A truncated
    /// sharded folder is hidden from the installed list, so this scan is the only thing that
    /// can account for its bytes — gating it on `containsWeights` skipped exactly those.
    func testOrphanScanReportsTruncatedShardedDownload() throws {
        let repoId = "mlx-community/orphan-shards"
        try makeShardedDownload(repoId, present: 1, expected: 4)

        let orphans = MLXModelService.scanForOrphans(under: root)
        XCTAssertTrue(
            orphans.contains { $0.repoId == repoId },
            "a partially-sharded folder is reclaimable residue, not an install"
        )
        XCTAssertGreaterThan(orphans.first { $0.repoId == repoId }?.bytes ?? 0, 0)
    }

    func testOrphanScanIgnoresCompleteInstall() throws {
        let repoId = "mlx-community/complete-install"
        try makeShardedDownload(repoId, present: 4, expected: 4)

        let orphans = MLXModelService.scanForOrphans(under: root)
        XCTAssertFalse(orphans.contains { $0.repoId == repoId })
    }

    // MARK: - Download-slot ownership

    /// A paused task keeps unwinding after `pauseDownload` has released the slot, and
    /// `resumeDownload` calls straight back into `downloadModel` — so the new occupant can be
    /// installed before the old task's terminal handler ever runs. That handler must not
    /// clear the new download's handles.
    ///
    /// ⚠️ Deliberately uses the SAME repo id on both sides: Pause→Resume is the fast path into
    /// this window, which is why the guard cannot be a repo-name comparison.
    func testSupersededCancellationLeavesTheNewDownloadIntact() throws {
        let service = MLXModelService(modelsRootOverride: root)
        let repoId = "mlx-community/paused-then-resumed"

        let taskA = Task<Void, Never> { try? await Task.sleep(nanoseconds: 30_000_000_000) }
        defer { taskA.cancel() }
        service.downloadTask = taskA
        service.isDownloading = true
        service.currentDownloadName = repoId
        let generationA = service.downloadGeneration

        XCTAssertTrue(service.pauseDownload())

        // Resume installs a new occupant (what `downloadModel` does on entry).
        let taskB = Task<Void, Never> { try? await Task.sleep(nanoseconds: 30_000_000_000) }
        defer { taskB.cancel() }
        service.downloadGeneration &+= 1
        service.downloadTask = taskB
        service.isDownloading = true
        service.currentDownloadName = repoId

        // A's cancellation finally lands.
        service.finishCancelled(repoId: repoId, generation: generationA, reason: "late unwind")

        XCTAssertNotNil(service.downloadTask, "the new download must keep a working Cancel button")
        XCTAssertEqual(service.currentDownloadName, repoId, "its progress ticks key off this")
        XCTAssertTrue(
            service.isDownloading,
            "the slot must stay occupied — freeing it admits a second concurrent snapshot into the same folder"
        )
    }

    /// The counterpart: an owning handler still clears, so the guard cannot pass by refusing
    /// everything. Without this, a `return false` in `stillOwnsSlot` would leak the slot forever.
    func testOwningCancellationClearsTheSlot() throws {
        let service = MLXModelService(modelsRootOverride: root)
        let repoId = "mlx-community/cancelled-for-real"

        let task = Task<Void, Never> { try? await Task.sleep(nanoseconds: 30_000_000_000) }
        defer { task.cancel() }
        service.downloadTask = task
        service.isDownloading = true
        service.currentDownloadName = repoId

        service.finishCancelled(
            repoId: repoId, generation: service.downloadGeneration, reason: "user cancelled"
        )

        XCTAssertNil(service.downloadTask)
        XCTAssertEqual(service.currentDownloadName, "")
        XCTAssertFalse(service.isDownloading)
    }

    /// A superseded task's FAILURE must not write `errorMessage` either: the bridge reads it
    /// to classify the ACTIVE download, so a late failure would mark a healthy running pull
    /// as failed.
    func testSupersededTerminalDoesNotMarkTheNewDownloadFailed() throws {
        let service = MLXModelService(modelsRootOverride: root)
        let repoId = "mlx-community/superseded"

        let stale = service.downloadGeneration
        service.downloadGeneration &+= 1
        let task = Task<Void, Never> { try? await Task.sleep(nanoseconds: 30_000_000_000) }
        defer { task.cancel() }
        service.downloadTask = task
        service.isDownloading = true
        service.currentDownloadName = repoId

        XCTAssertFalse(
            service.stillOwnsSlot(stale, repoId: repoId, phase: "failure"),
            "a retired generation must not be allowed to mutate slot state"
        )
        service.finishTerminal(repoId: repoId, generation: stale, classification: "failed")

        XCTAssertTrue(service.isDownloading)
        XCTAssertNotNil(service.downloadTask)
    }

    /// The counterpart: discarding removes them. If these two ever behave the same, the
    /// feature is gone.
    func testDiscardRemovesPartialFiles() throws {
        let service = MLXModelService(modelsRootOverride: root)
        let repoId = "mlx-community/abandon-me"
        let repo = try makePartialDownload(repoId, incompleteBytes: 32 * 1024)

        service.discardPartialDownload(repoId: repoId)

        XCTAssertFalse(FileManager.default.fileExists(atPath: repo.path))
        XCTAssertEqual(MLXModelService.resumableBytes(at: service.partialDownloadFolder(for: repoId)), 0)
    }

    /// `.incomplete` files live INSIDE the repo folder, so the resumable total must count
    /// them — a resume that reported 0 bytes would silently restart from scratch.
    func testResumableBytesCountsTheIncompleteFiles() throws {
        let service = MLXModelService(modelsRootOverride: root)
        let repoId = "mlx-community/partial"
        try makePartialDownload(repoId, incompleteBytes: 128 * 1024)

        let bytes = MLXModelService.resumableBytes(at: service.partialDownloadFolder(for: repoId))
        XCTAssertGreaterThanOrEqual(bytes, 128 * 1024)
    }

    func testResumableBytesIsZeroForAnUntouchedRepo() {
        let service = MLXModelService(modelsRootOverride: root)
        XCTAssertEqual(
            MLXModelService.resumableBytes(at: service.partialDownloadFolder(for: "mlx-community/never-started")),
            0
        )
        XCTAssertEqual(MLXModelService.resumableBytes(at: nil), 0)
    }

    // MARK: - Pause gating

    func testPauseIsRefusedWhenNothingIsDownloading() {
        let service = MLXModelService(modelsRootOverride: root)
        XCTAssertFalse(service.pauseDownload())
        XCTAssertNil(service.pausedRepoId)
    }

    /// Starting a fresh download of the same repo must clear its paused marker, or the bridge
    /// would classify the new download's terminal state as `paused`.
    func testStartingADownloadClearsItsPausedMarker() async {
        let service = MLXModelService(modelsRootOverride: root)
        service.pausedRepoId = "mlx-community/was-paused"

        _ = service.downloadModel(repoId: "mlx-community/was-paused")
        XCTAssertNil(service.pausedRepoId)

        // ⚠️ Deterministic teardown. This used to call `cancelDownload()`, which schedules an
        // UNAWAITED cleanup Task — so the test returned while work was still queued against
        // `root`, which `tearDown` then deleted underneath it. Cancel the task before its body
        // ever runs (it is enqueued on this actor, so it cannot have started yet) and await it,
        // which also keeps the test off the network.
        let task = service.downloadTask
        task?.cancel()
        await task?.value
        service.downloadTask = nil
        service.isDownloading = false
    }

    // MARK: - Status semantics

    /// `.paused` must not sit in the active set: it holds no bandwidth, must not keep the
    /// sleep assertion alive, and must not be swept by `reconcileOrphans` (which only touches
    /// `.queued`/`.downloading`).
    func testPausedIsNotAnActiveState() {
        XCTAssertTrue(DownloadRecordStatus.paused.isTerminal)
        XCTAssertFalse(DownloadRecordStatus.queued.isTerminal)
        XCTAssertFalse(DownloadRecordStatus.downloading.isTerminal)
    }

    /// Resumability is a separate axis from terminality. ⚠️ `.cancelled` is deliberately NOT
    /// resumable — cancelling discards the partial, so offering Resume would promise bytes
    /// that no longer exist.
    func testOnlyStatesThatKeptTheirBytesAreResumable() {
        XCTAssertTrue(DownloadRecordStatus.paused.isResumable)
        XCTAssertTrue(DownloadRecordStatus.interrupted.isResumable)
        XCTAssertTrue(DownloadRecordStatus.failed.isResumable)

        XCTAssertFalse(DownloadRecordStatus.cancelled.isResumable,
                       "cancel discards the partial files, so Resume would promise bytes that are gone")
        XCTAssertFalse(DownloadRecordStatus.completed.isResumable)
        XCTAssertFalse(DownloadRecordStatus.downloading.isResumable)
        XCTAssertFalse(DownloadRecordStatus.queued.isResumable)
    }

    /// `rawValue` is persisted; every case needs a stable one and a display name.
    func testEveryStatusHasAStableRawValueAndALocalizedTitle() {
        for status in DownloadRecordStatus.allCases {
            XCTAssertFalse(status.rawValue.isEmpty)
            XCTAssertNotNil(status.localizedTitle)
            XCTAssertEqual(DownloadRecordStatus(rawValue: status.rawValue), status)
        }
        XCTAssertEqual(DownloadRecordStatus.paused.rawValue, "paused")
    }
}
