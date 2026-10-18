// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
//
//  BackgroundLogCapTests.swift
//  DevgenticTests
//
//  Created by Raj Singh.
//

import XCTest
@testable import devgentic

final class BackgroundLogCapTests: XCTestCase {

    private var root: URL!
    private let conversation = UUID()
    private var registry: BackgroundProcessRegistry!

    override func setUpWithError() throws {
        try super.setUpWithError()
        root = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("bgcap-tests-\(UUID().uuidString)", isDirectory: true)
    }

    override func tearDownWithError() throws {
        registry?.terminateAll()
        if let root { try? FileManager.default.removeItem(at: root) }
        try super.tearDownWithError()
    }

    private func size(of url: URL) -> UInt64 {
        let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
        return (attributes?[.size] as? NSNumber)?.uint64Value ?? 0
    }

    /// The cap is enforced on the descendant-refresh tick (1 s), so this polls rather than sleeping.
    private func waitUntil(within seconds: TimeInterval = 8, _ condition: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            if condition() { return true }
            usleep(50_000)
        }
        return condition()
    }

    private func text(of url: URL) -> String {
        (try? String(contentsOf: url, encoding: .utf8)) ?? ""
    }

    /// Waits until the log has EXCEEDED the cap and then actually been rotated.
    ///
    /// ⚠️⚠️ BOTH HALVES ARE REQUIRED, and leaving out the first is how two of these tests shipped
    /// green while asserting nothing. A fresh log is ZERO bytes, so `size < cap` is already true
    /// before the task has written a thing — a wait on that alone returns instantly and every
    /// assertion after it describes a task that has not started.
    ///
    /// The second half polls for the MARKER rather than for the size, because `truncate` and the
    /// marker write are two syscalls: a size-based wait can observe the instant between them and
    /// read an empty file.
    private func waitForRotation(_ task: BackgroundProcessRegistry.Snapshot, cap: UInt64) -> Bool {
        guard waitUntil({ self.size(of: task.logURL) > cap }) else {
            XCTFail("the fixture never exceeded the cap — there was nothing to rotate")
            return false
        }
        return waitUntil { self.text(of: task.logURL).contains("log rotated") }
    }

    // MARK: - Rotation

    /// ⚠️ THE ONE THAT MATTERS. Everything else here refines it.
    func testALogPastItsCapIsRotatedRatherThanLeftToGrow() throws {
        registry = BackgroundProcessRegistry(rootDirectory: root, maxLogBytes: 8_192)
        let task = try registry.launch(
            // Writes well past the cap, then stays alive — the cap only runs for live tasks.
            command: "head -c 60000 /dev/zero | tr '\\0' 'x'; echo; sleep 30",
            workingDirectory: NSTemporaryDirectory(),
            timeout: 60, conversationID: conversation)

        XCTAssertTrue(waitForRotation(task, cap: 8_192),
                      "the log was never rotated: it grew past its cap and stayed there, which is "
                      + "the unbounded growth this cap exists to stop")
        XCTAssertLessThan(size(of: task.logURL), 8_192 * 4,
                          "rotation left the file near its pre-rotation size")
    }

    /// A gap that announces itself is a very different object from a gap.
    func testARotatedLogSaysThatItWasRotated() throws {
        registry = BackgroundProcessRegistry(rootDirectory: root, maxLogBytes: 8_192)
        let task = try registry.launch(
            command: "head -c 60000 /dev/zero | tr '\\0' 'x'; echo; sleep 30",
            workingDirectory: NSTemporaryDirectory(),
            timeout: 60, conversationID: conversation)

        XCTAssertTrue(waitForRotation(task, cap: 8_192),
                      "the log silently lost its history: \(text(of: task.logURL).prefix(200))")
        XCTAssertTrue(text(of: task.logURL).contains("MB of earlier output discarded"),
                      "the marker must say what was lost, not merely that something was")
    }

    /// ⚠️ The drain runs BEFORE the truncation, so the card and `command_output` see no gap across
    /// a rotation. Truncating first would discard output that had never been read.
    func testTheInMemoryTailSurvivesARotation() throws {
        registry = BackgroundProcessRegistry(rootDirectory: root, maxLogBytes: 8_192)
        let task = try registry.launch(
            command: "echo NEEDLE; head -c 60000 /dev/zero | tr '\\0' 'x'; echo; sleep 30",
            workingDirectory: NSTemporaryDirectory(),
            timeout: 60, conversationID: conversation)

        XCTAssertTrue(waitForRotation(task, cap: 8_192), "never rotated")
        let snapshot = try XCTUnwrap(registry.snapshot(conversationID: conversation, taskID: task.id))
        XCTAssertFalse(snapshot.tail.isEmpty,
                       "the tail was emptied by the rotation — a running task would appear to have "
                       + "produced nothing at the exact moment it produced too much")
        XCTAssertGreaterThan(snapshot.logCharacterCount, 8_192,
                             "the character count was reset by the rotation; it describes how much "
                             + "the task has produced, which truncating the file does not undo")
    }

    /// ⚠️ THE O_APPEND PROPERTY. Without it the child keeps its own offset, so truncating leaves
    /// that offset untouched and the next write lands at the old position — a SPARSE file whose
    /// head reads back as NUL bytes. This is the test that fails if the handle is opened plainly.
    func testTheTaskKeepsWritingAfterARotationWithoutLeavingAHole() throws {
        registry = BackgroundProcessRegistry(rootDirectory: root, maxLogBytes: 8_192)
        let task = try registry.launch(
            command: "head -c 60000 /dev/zero | tr '\\0' 'x'; echo; "
                   + "for i in 1 2 3 4 5 6 7 8 9 10; do echo AFTER-$i; sleep 0.2; done; sleep 20",
            workingDirectory: NSTemporaryDirectory(),
            timeout: 60, conversationID: conversation)

        XCTAssertTrue(waitForRotation(task, cap: 8_192), "never rotated")
        XCTAssertTrue(waitUntil { self.text(of: task.logURL).contains("AFTER-") },
                      "nothing written after the rotation reached the file")

        let text = self.text(of: task.logURL)
        XCTAssertFalse(text.unicodeScalars.contains("\0"),
                       "the log contains NUL bytes — the child wrote at its old offset and left a "
                       + "sparse hole, which is what happens when the handle is not O_APPEND")
    }

    /// ⚠️ The reason `enforceLogCap` resets `consumed` to 0 itself.
    ///
    /// `drainTail` has a "the file shrank under us" branch that clears the tail and the count —
    /// correct when a file was REPLACED, catastrophic here, because a rotation shrinks the file on
    /// purpose. Leave `consumed` pointing past the new end and the very next drain takes that
    /// branch and erases the history the rotation was careful to preserve.
    ///
    /// Nothing else reaches this: after rotating, the tick returns early (the file is under the cap
    /// again), so the destructive drain only happens when a SURFACE asks — an open card, the panel.
    func testARefreshAfterARotationDoesNotWipeTheTail() throws {
        registry = BackgroundProcessRegistry(rootDirectory: root, maxLogBytes: 8_192)
        let task = try registry.launch(
            command: "echo NEEDLE; head -c 60000 /dev/zero | tr '\\0' 'x'; echo; sleep 30",
            workingDirectory: NSTemporaryDirectory(),
            timeout: 60, conversationID: conversation)

        XCTAssertTrue(waitForRotation(task, cap: 8_192), "never rotated")
        let afterRotation = try XCTUnwrap(registry.snapshot(conversationID: conversation, taskID: task.id))
        XCTAssertFalse(afterRotation.tail.isEmpty, "bad fixture — nothing was captured to preserve")

        // What an expanded card does, once a second.
        let refreshed = try XCTUnwrap(registry.refreshTail(conversationID: conversation, taskID: task.id))
        XCTAssertFalse(refreshed.tail.isEmpty,
                       "the first refresh after a rotation wiped the tail — the card would blank "
                       + "itself the moment anyone opened it on a rotated task")
        XCTAssertGreaterThanOrEqual(refreshed.logCharacterCount, afterRotation.logCharacterCount,
                                    "the count went BACKWARDS across a refresh")
    }

    func testALogUnderItsCapIsLeftAlone() throws {
        registry = BackgroundProcessRegistry(rootDirectory: root, maxLogBytes: 1_048_576)
        let task = try registry.launch(command: "echo small; sleep 3",
                                       workingDirectory: NSTemporaryDirectory(),
                                       timeout: 30, conversationID: conversation)

        XCTAssertTrue(waitUntil(within: 3) { self.size(of: task.logURL) > 0 })
        usleep(1_500_000)          // at least one tick
        XCTAssertTrue(text(of: task.logURL).contains("small"), "a log under its cap was rotated anyway")
        XCTAssertFalse(text(of: task.logURL).contains("log rotated"))
    }

    // MARK: - The retention sweep (7 days, 1 GB — user decision 2026-09-24)

    /// A log file of `bytes` bytes, last modified `age` seconds ago, in its own conversation folder
    /// unless one is given.
    @discardableResult
    private func makeLog(age: TimeInterval, bytes: Int = 10, name: String = "20260101-000000_bg_1_old.log",
                         in directory: URL? = nil) throws -> URL {
        let folder = directory ?? root.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let url = folder.appendingPathComponent(name)
        try Data(repeating: 0x61, count: bytes).write(to: url)
        try FileManager.default.setAttributes(
            [.modificationDate: Date().addingTimeInterval(-age)], ofItemAtPath: url.path)
        return url
    }

    private let day: TimeInterval = 24 * 60 * 60

    func testALogOlderThanSevenDaysIsSweptAtLaunch() throws {
        let stale = try makeLog(age: 8 * day)
        registry = BackgroundProcessRegistry(rootDirectory: root)

        XCTAssertTrue(waitUntil { !FileManager.default.fileExists(atPath: stale.path) },
                      "a log past the 7-day retention survived launch")
    }

    /// An emptied conversation folder goes on a LATER pass — never one that may have just been
    /// created by `launch`, which opens its log a moment after making the folder.
    func testAnEmptyFolderIsRemovedOnlyOnceItHasBeenEmptyAWhile() throws {
        registry = BackgroundProcessRegistry(rootDirectory: root)
        let justMade = root.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: justMade, withIntermediateDirectories: true)

        registry.sweepLogs()
        XCTAssertTrue(FileManager.default.fileExists(atPath: justMade.path),
                      "a just-created folder was removed — a launch between mkdir and open would fail")

        registry.sweepLogs(now: Date().addingTimeInterval(2 * 60 * 60))
        XCTAssertFalse(FileManager.default.fileExists(atPath: justMade.path),
                       "a long-empty conversation folder was left behind")
    }

    /// ⚠️ The old rule was 24 hours. A 2-day-old log is exactly what a 7-day retention promises to keep.
    func testALogYoungerThanSevenDaysIsKept() throws {
        let recent = try makeLog(age: 6 * day)
        registry = BackgroundProcessRegistry(rootDirectory: root)
        registry.sweepLogs()

        XCTAssertTrue(FileManager.default.fileExists(atPath: recent.path),
                      "a 6-day-old log was removed; the retention period is 7 days")
    }

    /// Per FILE, not per folder. A folder's own date moves when a file is added, so the old rule let
    /// one fresh command keep a stale sibling alive indefinitely.
    func testAStaleLogIsSweptEvenBesideAFreshOne() throws {
        let fresh = try makeLog(age: 60, name: "20260924-000000_bg_2_new.log")
        let folder = fresh.deletingLastPathComponent()
        let stale = try makeLog(age: 8 * day, in: folder)
        registry = BackgroundProcessRegistry(rootDirectory: root)
        registry.sweepLogs()

        XCTAssertFalse(FileManager.default.fileExists(atPath: stale.path), "the stale sibling survived")
        XCTAssertTrue(FileManager.default.fileExists(atPath: fresh.path), "the fresh log was removed")
    }

    /// Past the total cap, the OLDEST go first until what is left fits.
    func testPastTheTotalCapTheOldestLogsGoFirst() throws {
        let oldest = try makeLog(age: 3 * day, bytes: 4096, name: "a.log")
        let middle = try makeLog(age: 2 * day, bytes: 4096, name: "b.log")
        let newest = try makeLog(age: 1 * day, bytes: 4096, name: "c.log")
        registry = BackgroundProcessRegistry(rootDirectory: root, maxTotalLogBytes: 10_000)
        registry.sweepLogs()

        XCTAssertFalse(FileManager.default.fileExists(atPath: oldest.path), "the oldest log should go first")
        XCTAssertTrue(FileManager.default.fileExists(atPath: middle.path),
                      "removed more than needed — two 4 KB logs fit under a 10 KB cap")
        XCTAssertTrue(FileManager.default.fileExists(atPath: newest.path), "the newest log was removed")
    }

    /// A running task's log is never swept — not for age, not for the total cap. Deleting it would
    /// cut the card and `command_output` off from a live command.
    func testTheSweepLeavesALiveTasksLogAlone() throws {
        registry = BackgroundProcessRegistry(rootDirectory: root, logRetention: 0, maxTotalLogBytes: 0)
        let task = try registry.launch(command: "echo live; sleep 5",
                                       workingDirectory: NSTemporaryDirectory(),
                                       timeout: 30, conversationID: conversation)
        XCTAssertTrue(waitUntil { self.size(of: task.logURL) > 0 })
        registry.sweepLogs(now: Date().addingTimeInterval(30 * day))
        XCTAssertTrue(FileManager.default.fileExists(atPath: task.logURL.path),
                      "the sweep removed a live task's log")
    }

    /// "Clear finished" tidies the list; it must not destroy output the retention period keeps.
    func testClearingFinishedTasksKeepsTheirLogs() throws {
        registry = BackgroundProcessRegistry(rootDirectory: root)
        let task = try registry.launch(command: "echo kept", workingDirectory: NSTemporaryDirectory(),
                                       timeout: 30, conversationID: conversation)
        XCTAssertTrue(waitUntil { self.registry.snapshot(conversationID: self.conversation, taskID: task.id)?.status.isTerminal == true })
        registry.clearFinished(conversationID: conversation)

        XCTAssertTrue(registry.snapshots(conversationID: conversation).isEmpty, "the card was not cleared")
        XCTAssertTrue(FileManager.default.fileExists(atPath: task.logURL.path),
                      "clearing the list deleted the log file")
    }

    func testAMissingRootIsNotAFailure() {
        let absent = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("bgcap-never-created-\(UUID().uuidString)", isDirectory: true)
        registry = BackgroundProcessRegistry(rootDirectory: absent)
        usleep(300_000)
        XCTAssertFalse(FileManager.default.fileExists(atPath: absent.path),
                       "first launch has no root; the sweep must not create one")
    }

    // MARK: - The shipped numbers

    /// ⚠️ The init seam exists for tests. This is what stops a convenient test value from quietly
    /// becoming the shipped one — the defaults are what every production caller gets.
    func testTheShippedCapsAreTheOnesProductionUses() {
        XCTAssertEqual(BackgroundProcessRegistry.defaultMaxLogBytes, 32 * 1024 * 1024,
                       "the per-file cap changed; a smaller value silently discards build output "
                       + "and a much larger one stops being a cap")
        XCTAssertEqual(BackgroundProcessRegistry.defaultLogRetention, 7 * 24 * 60 * 60,
                       "user decision 2026-09-24: command logs are kept for 7 days")
        XCTAssertEqual(BackgroundProcessRegistry.defaultTotalLogBytes, 1024 * 1024 * 1024,
                       "user decision 2026-09-24: all command logs together are capped at 1 GB")
        XCTAssertEqual(BackgroundProcessRegistry.sweepInterval, 24 * 60 * 60,
                       "the sweep must repeat while the app stays open, not only at launch")
        XCTAssertGreaterThan(BackgroundProcessRegistry.defaultMaxLogBytes, 1 << 20,
                             "the per-file cap must exceed one drain's ceiling, or a rotation "
                             + "could discard bytes the tail has not read yet")
    }
}
