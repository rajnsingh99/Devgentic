// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
//
//  BackgroundLogCapTests.swift
//  DevgenticTests
//
//  "Uncapped logs" was two leaks wearing one name.
//
//  ── 1. One file, no ceiling ─────────────────────────────────────────────────────────────
//
//  A task's log grew for as long as the task ran. `start_background_task` recommends itself for a
//  dev server, and a dev server appends for hours. Nothing watched the size, and the incremental
//  tail rewrite had just removed the last periodic read that might have noticed.
//
//  ── 2. One directory per conversation, forever ──────────────────────────────────────────
//
//  Log directories were removed ONLY by `discard`, which fires on conversation deletion. A user who
//  never deletes a conversation kept one directory per conversation that ever ran a command — and
//  after a restart those directories are unreachable from every surface, because the list view
//  renders registry entries and the registry is empty.
//
//  ⚠️ These tests use SMALL caps via the init seam. Writing 32 MB to prove a 32 MB cap works would
//  add seconds of disk I/O for no extra confidence: rotation is the behaviour, the threshold is a
//  number, and `testTheShippedCapsAreTheOnesProductionUses` pins the number separately.
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

    // MARK: - The launch-time sweep

    private func makeStaleDirectory(age: TimeInterval) throws -> URL {
        let directory = root.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data("old output".utf8).write(to: directory.appendingPathComponent("bg_1.log"))
        try FileManager.default.setAttributes(
            [.modificationDate: Date().addingTimeInterval(-age)], ofItemAtPath: directory.path)
        return directory
    }

    func testLogDirectoriesFromEarlierRunsAreSweptAtLaunch() throws {
        let stale = try makeStaleDirectory(age: 48 * 60 * 60)
        registry = BackgroundProcessRegistry(rootDirectory: root)

        XCTAssertTrue(waitUntil { !FileManager.default.fileExists(atPath: stale.path) },
                      "a log directory from an earlier run survived launch. Nothing else ever "
                      + "removes it — `discard` only fires on conversation deletion — so one "
                      + "directory accumulates per conversation that ever ran a command")
    }

    func testARecentLogDirectoryIsNotSwept() throws {
        let recent = try makeStaleDirectory(age: 60)
        registry = BackgroundProcessRegistry(rootDirectory: root)

        usleep(1_000_000)
        XCTAssertTrue(FileManager.default.fileExists(atPath: recent.path),
                      "the sweep removed a directory from THIS session — a crash-and-relaunch "
                      + "would lose the logs it came back to read")
    }

    /// The sweep runs in `init`, before any task exists. A registry that swept its own root, or
    /// choked on a missing one, would break every launch.
    func testTheSweepLeavesALiveTasksLogAlone() throws {
        registry = BackgroundProcessRegistry(rootDirectory: root)
        let task = try registry.launch(command: "echo live; sleep 5",
                                       workingDirectory: NSTemporaryDirectory(),
                                       timeout: 30, conversationID: conversation)
        usleep(1_000_000)
        XCTAssertTrue(FileManager.default.fileExists(atPath: task.logURL.path),
                      "the sweep removed a live task's log")
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
        XCTAssertEqual(BackgroundProcessRegistry.defaultOrphanedLogMaxAge, 24 * 60 * 60)
        XCTAssertGreaterThan(BackgroundProcessRegistry.defaultMaxLogBytes, 1 << 20,
                             "the per-file cap must exceed one drain's ceiling, or a rotation "
                             + "could discard bytes the tail has not read yet")
    }
}
