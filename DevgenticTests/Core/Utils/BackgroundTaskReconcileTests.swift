// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
//
//  BackgroundTaskReconcileTests.swift
//  DevgenticTests
//
//  What a `running` row means after it comes back off disk.
//
//  ⚠️ A persisted row keeps whatever status was last flushed, and `BackgroundTaskCard` renders
//  `.running` as LIVE: a spinner, an elapsed clock counting up from `startedAt`, and an
//  auto-expanded output pane. After a relaunch that is always false — `terminateAll` kills every
//  task inside `applicationShouldTerminate`, and the registry does not survive the process — so
//  yesterday's build came back claiming to have been running for fourteen hours.
//
//  `.interrupted` existed in the wire format from the beginning and NOTHING EVER SET IT. The card
//  already had its icon, its colour, and a label written to claim no duration. Only the thing that
//  assigns it was missing.
//
//  ⚠️ The interesting case is not the relaunch. It is a task that finished while its conversation
//  was unloaded: `Tracked.message` is a WEAK reference on purpose, so the observer drops tracking
//  and the real ending never reaches the row. The registry still knows it — and the row should
//  adopt THAT, not be flattened to "interrupted".
//

import XCTest
@testable import devgentic

@MainActor
final class BackgroundTaskReconcileTests: XCTestCase {

    private var root: URL!
    private var registry: BackgroundProcessRegistry!
    private let conversation = UUID()

    override func setUpWithError() throws {
        try super.setUpWithError()
        root = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("bgreconcile-\(UUID().uuidString)", isDirectory: true)
        registry = BackgroundProcessRegistry(rootDirectory: root)
    }

    override func tearDownWithError() throws {
        registry?.terminateAll()
        if let root { try? FileManager.default.removeItem(at: root) }
        try super.tearDownWithError()
    }

    // MARK: - Helpers

    private func message(conversationID: UUID? = nil,
                         rows: [BackgroundTaskData],
                         extra: [TimelineEvent] = []) -> ChatMessage {
        let message = ChatMessage(conversationId: conversationID ?? conversation,
                                  sender: .agent, content: .markdownText(""))
        message.timelineEvents = rows.map { .backgroundTask($0) } + extra
        return message
    }

    private func row(taskID: String = "bg_1",
                     status: BackgroundTaskStatus = .running,
                     startedAt: Date = Date().addingTimeInterval(-3_600)) -> BackgroundTaskData {
        BackgroundTaskData(id: UUID(), taskID: taskID, name: "Build",
                           command: "xcodebuild", workingDirectory: "/tmp",
                           startedAt: startedAt, finishedAt: nil, status: status,
                           exitCode: nil, logPath: "/tmp/\(taskID).log",
                           outputTail: "", logCharacterCount: 0)
    }

    private func rows(of message: ChatMessage) -> [BackgroundTaskData] {
        message.timelineEvents.compactMap {
            if case .backgroundTask(let data) = $0 { return data }
            return nil
        }
    }

    private func waitForTerminal(_ taskID: String) -> BackgroundProcessRegistry.Snapshot? {
        let deadline = Date().addingTimeInterval(8)
        while Date() < deadline {
            if let snapshot = registry.snapshot(conversationID: conversation, taskID: taskID),
               snapshot.status.isTerminal { return snapshot }
            RunLoop.current.run(until: Date().addingTimeInterval(0.02))
        }
        return registry.snapshot(conversationID: conversation, taskID: taskID)
    }

    // MARK: - (3) Nothing knows the task

    func testARowLeftRunningByAQuitBecomesInterrupted() {
        let loaded = message(rows: [row()])

        XCTAssertEqual(BackgroundTaskObserver.reconcile([loaded], registry: registry), 1)
        XCTAssertEqual(rows(of: loaded).first?.status, .interrupted,
                       "the row still claims to be running; the card renders that as a spinner "
                       + "with a clock counting up from an hour ago")
    }

    /// ⚠️ We do not know WHEN it died. The card's `.interrupted` label is written to claim no
    /// duration for exactly this reason — stamping `now` would report an overnight quit as a task
    /// that ran for fourteen hours, which is the same false statement in a different font.
    func testAnInterruptedRowInventsNoFinishTime() {
        let loaded = message(rows: [row()])
        BackgroundTaskObserver.reconcile([loaded], registry: registry)
        XCTAssertNil(rows(of: loaded).first?.finishedAt,
                     "a finish time was invented for a task nobody watched end")
    }

    // MARK: - (1) The task is genuinely live

    /// The case a blanket "running → interrupted" would break. Switching conversations away and
    /// back re-reads the blob while the build is still going.
    func testAGenuinelyRunningTaskIsLeftAlone() throws {
        let task = try registry.launch(command: "sleep 30", workingDirectory: NSTemporaryDirectory(),
                                       timeout: 60, conversationID: conversation)
        let loaded = message(rows: [row(taskID: task.id)])

        XCTAssertEqual(BackgroundTaskObserver.reconcile([loaded], registry: registry), 0,
                       "a live task was rewritten")
        XCTAssertEqual(rows(of: loaded).first?.status, .running,
                       "returning to a conversation declared its running build dead")
    }

    // MARK: - (2) The registry knows the real ending

    /// ⚠️ NOT exotic, and the reason this is not a two-way decision. The observer's message
    /// reference is WEAK, so a conversation unloaded mid-task drops the tracking and the ending
    /// never reaches the row — while the registry has known it all along.
    func testARowWhoseTaskEndedUnobservedAdoptsTheRealOutcome() throws {
        let task = try registry.launch(command: "echo VERDICT", workingDirectory: NSTemporaryDirectory(),
                                       timeout: 30, conversationID: conversation)
        XCTAssertNotNil(waitForTerminal(task.id))
        let loaded = message(rows: [row(taskID: task.id)])

        XCTAssertEqual(BackgroundTaskObserver.reconcile([loaded], registry: registry), 1)
        let reconciled = try XCTUnwrap(rows(of: loaded).first)
        XCTAssertEqual(reconciled.status, .exited,
                       "flattened to 'interrupted' when the real outcome was available")
        XCTAssertEqual(reconciled.exitCode, 0)
        XCTAssertNotNil(reconciled.finishedAt, "the registry knew when it ended")
        XCTAssertTrue(reconciled.outputTail.contains("VERDICT"),
                      "the output was available and not adopted: \(reconciled.outputTail)")
        XCTAssertGreaterThan(reconciled.logCharacterCount, 0)
    }

    /// ⚠️ A signal number is not an exit code — the same distinction the registry's `Status` keeps.
    func testAKilledTaskIsNotAdoptedAsAnOrdinaryExit() throws {
        let task = try registry.launch(command: "sleep 30", workingDirectory: NSTemporaryDirectory(),
                                       timeout: 1, conversationID: conversation)
        XCTAssertEqual(waitForTerminal(task.id)?.status, .timedOut)
        let loaded = message(rows: [row(taskID: task.id)])

        BackgroundTaskObserver.reconcile([loaded], registry: registry)
        let reconciled = try XCTUnwrap(rows(of: loaded).first)
        XCTAssertEqual(reconciled.status, .timedOut)
        XCTAssertNil(reconciled.exitCode, "a kill has no exit code the command chose")
    }

    func testAStoppedTaskIsAdoptedAsStopped() throws {
        let task = try registry.launch(command: "sleep 30", workingDirectory: NSTemporaryDirectory(),
                                       timeout: 60, conversationID: conversation)
        registry.stop(conversationID: conversation, taskID: task.id)
        XCTAssertEqual(waitForTerminal(task.id)?.status, .stopped)
        let loaded = message(rows: [row(taskID: task.id)])

        BackgroundTaskObserver.reconcile([loaded], registry: registry)
        XCTAssertEqual(rows(of: loaded).first?.status, .stopped)
    }

    // MARK: - What it must not touch

    func testAlreadyTerminalRowsAreLeftAlone() {
        let loaded = message(rows: [row(taskID: "bg_1", status: .exited),
                                    row(taskID: "bg_2", status: .timedOut),
                                    row(taskID: "bg_3", status: .stopped),
                                    row(taskID: "bg_4", status: .interrupted)])

        XCTAssertEqual(BackgroundTaskObserver.reconcile([loaded], registry: registry), 0)
        XCTAssertEqual(rows(of: loaded).map(\.status), [.exited, .timedOut, .stopped, .interrupted])
    }

    func testOtherTimelineEventsAreUntouched() {
        let thought = TimelineEvent.thought(id: UUID(), text: "thinking")
        let loaded = message(rows: [row()], extra: [thought])

        BackgroundTaskObserver.reconcile([loaded], registry: registry)
        XCTAssertEqual(loaded.timelineEvents.count, 2)
        if case .thought(_, let text) = loaded.timelineEvents[1] {
            XCTAssertEqual(text, "thinking")
        } else {
            XCTFail("a non-background event was rewritten or dropped")
        }
    }

    /// ⚠️ Ids are PER-CONVERSATION — `bg_1` exists in every conversation that ever ran a command.
    /// Keying the lookup on the task id alone would answer one conversation's row with another
    /// conversation's live build, and leave a dead row rendering as running forever.
    func testALookupUsesTheMessagesOwnConversation() throws {
        let other = UUID()
        let live = try registry.launch(command: "sleep 30", workingDirectory: NSTemporaryDirectory(),
                                       timeout: 60, conversationID: other)
        XCTAssertEqual(live.id, "bg_1", "fixture assumes the shared id")
        defer { registry.discard(conversationID: other) }

        // Same task id, different conversation, and THIS conversation has no such task.
        let loaded = message(rows: [row(taskID: "bg_1")])

        XCTAssertEqual(BackgroundTaskObserver.reconcile([loaded], registry: registry), 1,
                       "the row was matched against another conversation's live task")
        XCTAssertEqual(rows(of: loaded).first?.status, .interrupted)
    }

    func testItIsIdempotent() {
        let loaded = message(rows: [row()])
        XCTAssertEqual(BackgroundTaskObserver.reconcile([loaded], registry: registry), 1)
        XCTAssertEqual(BackgroundTaskObserver.reconcile([loaded], registry: registry), 0,
                       "a second pass rewrote rows it had already corrected — this runs on every "
                       + "conversation load")
    }

    func testItSpansEveryMessageAndEveryRow() {
        let first = message(rows: [row(taskID: "bg_1"), row(taskID: "bg_2")])
        let second = message(rows: [row(taskID: "bg_3")])

        XCTAssertEqual(BackgroundTaskObserver.reconcile([first, second], registry: registry), 3,
                       "only the first row or the first message was reconciled")
        XCTAssertTrue((rows(of: first) + rows(of: second)).allSatisfy { $0.status == .interrupted })
    }

    // MARK: - Wiring

    /// Without this the reconciliation is a function nothing calls, and every relaunch still shows
    /// yesterday's build spinning.
    func testTheConversationLoadReconciles() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let path = "Devgentic/Interfaces/Shared/Chat/ChatHistoryViewModel.swift"
        guard let source = try? String(contentsOf: root.appendingPathComponent(path), encoding: .utf8) else {
            throw XCTSkip("\(path) not reachable — running outside a checkout")
        }
        let lines = source.components(separatedBy: "\n")
        guard let start = lines.firstIndex(where: { $0.contains("func loadConversation(") }) else {
            return XCTFail("loadConversation not found — this guard is checking nothing")
        }
        let body = lines[start..<min(start + 120, lines.count)]
            .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
            .joined(separator: "\n")

        // `reconciledMessages` since 2026-09-23 — it also returns the corrected messages, which the
        // load now SAVES (see `BackgroundTaskEndingPersistenceTests.testTheLoadPathSavesWhatReconcileCorrected`).
        guard let call = body.range(of: "BackgroundTaskObserver.reconciledMessages(") else {
            return XCTFail("loadConversation does not reconcile — a relaunched conversation still "
                           + "renders yesterday's task as running")
        }
        guard let assign = body.range(of: "self.currentChatMessages =") else {
            return XCTFail("currentChatMessages assignment not found — this guard is checking nothing")
        }
        XCTAssertLessThan(call.lowerBound, assign.lowerBound,
                          "reconcile must run BEFORE the messages are published, or the card "
                          + "renders a spinner for the frame in between")
        XCTAssertTrue(body.contains("reconciledMessages(persistedMessages"),
                      "reconcile must take the PERSISTED messages — the live streaming ones are "
                      + "already being maintained by the observer")
    }
}
