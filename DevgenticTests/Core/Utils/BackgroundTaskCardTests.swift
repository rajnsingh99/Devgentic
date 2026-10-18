// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
//
//  BackgroundTaskCardTests.swift
//  DevgenticTests
//
//  Created by Raj Singh.
//

import XCTest
@testable import devgentic

// MARK: - Model and wire format

final class BackgroundTaskTimelineModelTests: XCTestCase {

    private func sample(status: BackgroundTaskStatus = .running, exitCode: Int32? = nil) -> BackgroundTaskData {
        BackgroundTaskData(
            id: UUID(), taskID: "bg_1",
            name: nil,
            command: "xcodebuild build-for-testing -scheme devgentic",
            workingDirectory: "/tmp", startedAt: Date(timeIntervalSince1970: 1_000),
            finishedAt: status.isTerminal ? Date(timeIntervalSince1970: 1_090) : nil,
            status: status, exitCode: exitCode,
            logPath: "/tmp/devgentic-bg/x/bg_1.log",
            outputTail: "** TEST BUILD SUCCEEDED **", logCharacterCount: 374_400)
    }

    /// ⚠️ The timeline's wire format is hand-pinned by `KnownTimelineEvent` precisely because a
    /// silent codec change once lost whole runs. A new case has to survive the round trip.
    func testTheRowRoundTripsThroughTheTimelineCodec() throws {
        let event = TimelineEvent.backgroundTask(sample(status: .exited, exitCode: 0))
        let data = try JSONEncoder().encode([event])
        let decoded = try JSONDecoder().decode([TimelineEvent].self, from: data)

        XCTAssertEqual(decoded.count, 1)
        guard case .backgroundTask(let back) = decoded[0] else {
            return XCTFail("decoded as \(decoded[0]) — the case did not survive the codec")
        }
        XCTAssertEqual(back.taskID, "bg_1")
        XCTAssertEqual(back.status, .exited)
        XCTAssertEqual(back.exitCode, 0)
        XCTAssertEqual(back.logCharacterCount, 374_400)
    }

    /// The row keys SwiftUI's `ForEach`; a changing id would churn the list on every update.
    func testTheEventIDIsTheRowsOwnID() {
        let data = sample()
        XCTAssertEqual(TimelineEvent.backgroundTask(data).id, data.id)
    }

    /// ⚠️ The row is the ONLY record of a live process — its id, its log path, the handle the UI
    /// polls. Evicting it while the task runs leaves a process nothing can name.
    func testTheRowSurvivesTimelineEviction() {
        XCTAssertTrue(TimelineEvent.backgroundTask(sample()).isCapabilityCard,
                      "a background task row is evictable, so a long run can drop a live task")
    }

    /// `interrupted` has to exist on the wire from day one: quit KILLS every background task, so a
    /// persisted `running` is false the moment the app restarts.
    func testInterruptedIsPartOfTheWireFormat() throws {
        let event = TimelineEvent.backgroundTask(sample(status: .interrupted))
        let decoded = try JSONDecoder().decode([TimelineEvent].self,
                                               from: try JSONEncoder().encode([event]))
        guard case .backgroundTask(let back) = decoded[0] else { return XCTFail("lost the case") }
        XCTAssertEqual(back.status, .interrupted)
    }

    /// ⚠️ BACKWARD COMPATIBILITY, asserted rather than assumed. `name` was added after rows were
    /// already being persisted, so a stored row without the key must still decode — the timeline
    /// codec's whole reason for existing is that one unreadable event used to destroy a run's
    /// entire history.
    func testARowStoredBeforeNameExistedStillDecodes() throws {
        let legacy = """
        [{"backgroundTask":{"_0":{"id":"\(UUID().uuidString)","taskID":"bg_1",        "command":"xcodebuild","workingDirectory":"/tmp",        "startedAt":0,"status":"running","logPath":"/tmp/bg_1.log",        "outputTail":"","logCharacterCount":0}}}]
        """
        let decoded = try JSONDecoder().decode([TimelineEvent].self, from: Data(legacy.utf8))
        guard case .backgroundTask(let row) = decoded[0] else {
            return XCTFail("a row without `name` fell back to .unknown: \(decoded[0])")
        }
        XCTAssertNil(row.name)
        XCTAssertEqual(row.taskID, "bg_1")
    }

    func testANamedRowRoundTrips() throws {
        var data = sample()
        data.name = "Build and test"
        let decoded = try JSONDecoder().decode([TimelineEvent].self,
                                               from: try JSONEncoder().encode([TimelineEvent.backgroundTask(data)]))
        guard case .backgroundTask(let row) = decoded[0] else { return XCTFail("lost the case") }
        XCTAssertEqual(row.name, "Build and test")
    }

    func testStatusTerminality() {
        XCTAssertFalse(BackgroundTaskStatus.running.isTerminal)
        for status: BackgroundTaskStatus in [.exited, .timedOut, .stopped, .interrupted] {
            XCTAssertTrue(status.isTerminal, "\(status) should be terminal")
        }
    }
}

// MARK: - The wiring: something must create and update the row

@MainActor
final class BackgroundTaskObserverTests: XCTestCase {

    private var root: URL!
    private var registry: BackgroundProcessRegistry!
    private var observer: BackgroundTaskObserver!
    private var message: ChatMessage!
    private let conversation = UUID()

    override func setUpWithError() throws {
        try super.setUpWithError()
        root = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("bgcard-\(UUID().uuidString)", isDirectory: true)
        registry = BackgroundProcessRegistry(rootDirectory: root)
        message = ChatMessage(conversationId: conversation, sender: .agent, content: .markdownText(""))
        observer = BackgroundTaskObserver(registry: registry)
        observer.start { [weak self] id in id == self?.conversation ? self?.message : nil }
    }

    override func tearDownWithError() throws {
        registry?.terminateAll()
        if let root { try? FileManager.default.removeItem(at: root) }
        try super.tearDownWithError()
    }

    private func rows() -> [BackgroundTaskData] {
        message.timelineEvents.compactMap {
            if case .backgroundTask(let data) = $0 { return data }
            return nil
        }
    }

    private func waitForRow(where predicate: @escaping (BackgroundTaskData) -> Bool,
                            within seconds: TimeInterval = 8) -> BackgroundTaskData? {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            if let row = rows().first(where: predicate) { return row }
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        }
        return rows().first(where: predicate)
    }

    /// THE WIRING. Launching a task must put a row on the message — without this the card exists
    /// and nothing ever creates one, which is the failure mode this file is split to catch.
    func testLaunchingATaskAddsARowToTheLiveMessage() throws {
        try registry.launch(command: "echo hello-card", workingDirectory: NSTemporaryDirectory(),
                            timeout: 30, conversationID: conversation)

        let row = waitForRow { $0.taskID == "bg_1" }
        XCTAssertNotNil(row, "no timeline row was created for the background task")
        XCTAssertEqual(row?.command, "echo hello-card")
    }

    /// ⚠️⚠️ THE ONE THAT MATTERS, and mutation is what found it missing.
    ///
    /// Every other test here runs a command that finishes in milliseconds, so the row appears
    /// either way — announced at launch, or created when the terminal status arrives. Deleting
    /// the LAUNCH announcement left all six of them green, while a real build would have shown
    /// nothing at all until it finished: precisely the defect this phase exists to remove.
    ///
    /// A row must exist, and read `running`, while the task is still running.
    func testARowAppearsWhileTheTaskIsStillRunning() throws {
        try registry.launch(command: "sleep 30", workingDirectory: NSTemporaryDirectory(),
                            timeout: 60, conversationID: conversation)

        let row = waitForRow(where: { $0.status == .running }, within: 3)
        XCTAssertNotNil(row, "no row until the task ended — a long build would be invisible while "
                        + "it ran, which is the whole problem this row was added to solve")
        XCTAssertEqual(row?.taskID, "bg_1")
        XCTAssertNil(row?.finishedAt)

        registry.stop(conversationID: conversation, taskID: "bg_1")
    }

    /// The row has to keep moving after the tool call returned — that is the entire point.
    func testTheRowIsUpdatedWhenTheTaskFinishes() throws {
        try registry.launch(command: "echo done-card", workingDirectory: NSTemporaryDirectory(),
                            timeout: 30, conversationID: conversation)

        let finished = waitForRow { $0.status == .exited }
        XCTAssertNotNil(finished, "the row never left `running` — updates are not reaching it")
        XCTAssertEqual(finished?.exitCode, 0)
        XCTAssertTrue(finished?.outputTail.contains("done-card") ?? false,
                      "the row carries no output: \(finished?.outputTail ?? "<nil>")")
        XCTAssertNotNil(finished?.finishedAt)
    }

    func testAKilledTaskIsNotReportedAsAnOrdinaryExit() throws {
        try registry.launch(command: "sleep 30", workingDirectory: NSTemporaryDirectory(),
                            timeout: 1, conversationID: conversation)

        let row = waitForRow { $0.status.isTerminal }
        XCTAssertEqual(row?.status, .timedOut,
                       "a kill rendered as an exit code the command chose is a false statement")
        XCTAssertNil(row?.exitCode, "a signal number is not an exit code")
    }

    /// The registry → row half of the name's path. Without this the label reaches the registry and
    /// stops there, and the card still shows a raw command.
    func testATaskNameReachesTheRow() throws {
        try registry.launch(command: "echo named-row", workingDirectory: NSTemporaryDirectory(),
                            timeout: 30, conversationID: conversation, name: "Build and test")

        let row = waitForRow { $0.taskID == "bg_1" }
        XCTAssertEqual(row?.name, "Build and test")
        XCTAssertEqual(row?.command, "echo named-row", "the command survives alongside the label")
    }

    /// Output is a BOUNDED tail, never the whole log — the message blob is re-encoded on every
    /// flush, and `ToolExecutionData` already documents what a megabyte there costs.
    func testTheRowCarriesABoundedTailAndSaysHowMuchIsMissing() throws {
        let big = "seq 1 20000"
        try registry.launch(command: big, workingDirectory: NSTemporaryDirectory(),
                            timeout: 30, conversationID: conversation)

        guard let row = waitForRow(where: { $0.status.isTerminal }) else { return XCTFail("never finished") }
        XCTAssertLessThanOrEqual(row.outputTail.count, BackgroundTaskData.maxOutputTail)
        XCTAssertGreaterThan(row.logCharacterCount, row.outputTail.count,
                             "the row must record the full size so the UI can say what it is hiding")
        XCTAssertTrue(row.outputTail.contains("20000"), "a TAIL must hold the END of the output")
    }

    /// A task started with no live stream gets no row. Not a defect — it still runs, is still
    /// bounded, and `command_status` still answers — but it must not crash or invent a message.
    func testATaskWithNoLiveMessageIsSkippedRatherThanCrashing() throws {
        try registry.launch(command: "echo orphan", workingDirectory: NSTemporaryDirectory(),
                            timeout: 30, conversationID: UUID())
        RunLoop.current.run(until: Date().addingTimeInterval(0.4))
        XCTAssertTrue(rows().isEmpty, "a row was attached to the wrong conversation's message")
    }

    /// Guards the app-launch call site. The observer can compile, be correct, and never be armed.
    func testTheObserverIsArmedAtAppLaunch() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        guard let source = try? String(contentsOf: root.appendingPathComponent("Devgentic/DevgenticApp.swift"),
                                       encoding: .utf8) else {
            throw XCTSkip("DevgenticApp.swift not reachable — running outside a checkout")
        }
        XCTAssertTrue(source.contains("BackgroundTaskObserver.shared.start"),
                      "nothing arms the observer at launch, so no background task ever gets a row")
    }
}
