// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
//
//  ProcessTeardownOrderTests.swift
//  DevgenticTests
//
//  Timeout inventory D-29 — process teardown edge cases:
//  - `discard` killed without a verdict, so a waiting foreground call reported "Exit code: 15";
//  - a stop/timeout announced BEFORE the final drain, publishing a stale tail;
//  - a quit-time `.stopped` could wake an unattended run.
//

import XCTest
@testable import devgentic

final class ProcessTeardownOrderTests: XCTestCase {

    private var root: URL!
    private var registry: BackgroundProcessRegistry!
    private let conversation = UUID()
    private var observers: [NSObjectProtocol] = []

    override func setUpWithError() throws {
        try super.setUpWithError()
        root = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("teardown-order-\(UUID().uuidString)", isDirectory: true)
        registry = BackgroundProcessRegistry(rootDirectory: root)
    }

    override func tearDownWithError() throws {
        observers.forEach(NotificationCenter.default.removeObserver)
        registry?.terminateAll()
        if let root { try? FileManager.default.removeItem(at: root) }
        try super.tearDownWithError()
    }

    private func launch(_ command: String, foreground: Bool = false) throws -> BackgroundProcessRegistry.Snapshot {
        try registry.launch(command: command, workingDirectory: NSTemporaryDirectory(), timeout: 30,
                            conversationID: conversation, foreground: foreground)
    }

    /// Calls `body` with each snapshot the registry has at the moment an announcement for `taskID`
    /// arrives.
    private func onAnnouncement(of taskID: String, _ body: @escaping (BackgroundProcessRegistry.Snapshot?) -> Void) {
        let registry = registry!, conversation = conversation
        observers.append(NotificationCenter.default.addObserver(forName: .backgroundTaskChanged, object: nil, queue: nil) { note in
            guard note.userInfo?[BackgroundTaskNotificationKey.taskID] as? String == taskID else { return }
            body(registry.snapshot(conversationID: conversation, taskID: taskID))
        })
    }

    /// Mutation that must turn this red: remove the `finish(…, .stopped)` from `discard`.
    func testDiscardingAConversationRecordsAStopNotAnExitCode() async throws {
        let task = try launch("sleep 20", foreground: true)
        let waiter = Task { await registry.waitUntilEnded(conversationID: conversation, taskID: task.id) }
        try await Task.sleep(for: .milliseconds(200))
        registry.discard(conversationID: conversation)

        let ended = await waiter.value
        XCTAssertEqual(ended?.status, .stopped,
                       "the kill was recorded as the command's own exit code: \(String(describing: ended?.status))")
    }

    /// The terminal announcement must carry what the command printed WHILE being stopped.
    /// Mutation that must turn this red: pass `announce: true` in `stop`.
    func testAStopIsAnnouncedWithTheFinalOutput() throws {
        let task = try launch("echo FIRST; trap 'echo LAST-WORDS; exit 0' TERM; sleep 20 & wait")
        Thread.sleep(forTimeInterval: 0.4)

        let announced = expectation(description: "terminal announcement")
        // A regression announces TWICE (early, then after the drain). Over-fulfilling must fail
        // the assertion below, not crash the test host and take the next test down with it.
        announced.assertForOverFulfill = false
        let lock = NSLock()
        var terminalTails: [String] = []
        onAnnouncement(of: task.id) { snapshot in
            guard let snapshot, snapshot.status.isTerminal else { return }
            lock.withLock { terminalTails.append(snapshot.tail) }
            announced.fulfill()
        }
        registry.stop(conversationID: conversation, taskID: task.id)
        wait(for: [announced], timeout: 10)

        let first = lock.withLock { terminalTails.first } ?? ""
        XCTAssertTrue(first.contains("LAST-WORDS"),
                      "the ending was announced before the final drain — its tail is stale: \(first)")
    }

    /// Mutation that must turn this red: drop the `isQuitting` check in `announce`.
    func testNothingIsAnnouncedOnceQuitHasStarted() throws {
        let task = try launch("sleep 20")
        Thread.sleep(forTimeInterval: 0.3)

        let announced = expectation(description: "no announcement during quit")
        announced.isInverted = true
        onAnnouncement(of: task.id) { _ in announced.fulfill() }
        registry.terminateAll()
        wait(for: [announced], timeout: 1.5)
    }
}
