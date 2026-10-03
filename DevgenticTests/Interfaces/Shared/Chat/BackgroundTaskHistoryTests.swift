// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
//
//  BackgroundTaskHistoryTests.swift
//  DevgenticTests
//
//  The task list after a relaunch (2026-09-26). It read only the in-memory registry, so it came
//  back EMPTY — and its pill hid — while every run was saved in the conversation's task cards.
//

import XCTest
import SwiftData
@testable import devgentic

@MainActor
final class BackgroundTaskHistoryTests: XCTestCase {

    private let conversationID = UUID()
    private let t0 = Date(timeIntervalSince1970: 1_700_000_000)

    private func row(_ taskID: String, log: String, status: BackgroundTaskStatus = .exited,
                     startedAt: Date? = nil, finishedAt: Date? = nil, tail: String = "done") -> BackgroundTaskData {
        BackgroundTaskData(id: UUID(), taskID: taskID, name: nil, command: "swift build",
                           workingDirectory: "/tmp", startedAt: startedAt ?? t0,
                           finishedAt: finishedAt ?? (status == .running ? nil : (startedAt ?? t0).addingTimeInterval(5)),
                           status: status, exitCode: status == .exited ? 0 : nil,
                           logPath: log, outputTail: tail, logCharacterCount: tail.count)
    }

    // MARK: - The merge

    /// ⚠️ THE REPORTED DEFECT: nothing live (a relaunch), yet the saved runs must be listed.
    func testSavedRunsAreListedWithNothingLive() {
        let items = BackgroundTaskHistory.items(live: [], saved: [row("bg_1", log: "/l/a.log")], clearedBefore: nil)
        XCTAssertEqual(items.map(\.taskID), ["bg_1"], "the list is empty after a relaunch again")
        XCTAssertFalse(items[0].isLive)
    }

    /// A card saved as `running` whose task is not live died with an earlier launch.
    func testASavedRunningRowThatIsNotLiveIsInterrupted() {
        let items = BackgroundTaskHistory.items(
            live: [], saved: [row("bg_1", log: "/l/a.log", status: .running)], clearedBefore: nil)
        XCTAssertEqual(items.first?.status, .interrupted)
        XCTAssertFalse(items.first?.isRunning ?? true, "a dead task must not render as running")
        XCTAssertNil(items.first?.finishedAt, "no finish time is invented for a task nobody saw end")
    }

    /// `bg_1` restarts every launch — two runs sharing it are two rows, told apart by log file.
    func testTheSameTaskIDFromTwoLaunchesIsTwoRows() {
        let items = BackgroundTaskHistory.items(live: [], saved: [
            row("bg_1", log: "/l/20260101-000000_bg_1_a.log", startedAt: t0),
            row("bg_1", log: "/l/20260102-000000_bg_1_b.log", startedAt: t0.addingTimeInterval(86_400)),
        ], clearedBefore: nil)
        XCTAssertEqual(items.count, 2, "two runs collapsed into one because they shared a task id")
        XCTAssertLessThan(items[0].startedAt, items[1].startedAt, "oldest first")
    }

    /// A task of this launch has BOTH a live entry and (once its turn is saved) a card: one row,
    /// and the live one wins — it is current and stoppable.
    func testALiveTaskAndItsOwnCardAreOneRow() throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("bghist-\(UUID())")
        let registry = BackgroundProcessRegistry(rootDirectory: root)
        defer { registry.terminateAll(); try? FileManager.default.removeItem(at: root) }
        let live = try registry.launch(command: "sleep 5", workingDirectory: "/tmp", timeout: 30, conversationID: conversationID)

        let items = BackgroundTaskHistory.items(
            live: registry.snapshots(conversationID: conversationID),
            saved: [row(live.id, log: live.logURL.path, status: .running)], clearedBefore: nil)
        XCTAssertEqual(items.count, 1, "a live task was listed twice")
        XCTAssertTrue(items[0].isLive)
        XCTAssertEqual(items[0].status, .running, "the live status must win over the saved card's")
    }

    /// "Clear finished" hides finished rows — saved ones too — but never a running task.
    func testClearingHidesFinishedRowsButNeverARunningOne() throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("bghist-\(UUID())")
        let registry = BackgroundProcessRegistry(rootDirectory: root)
        defer { registry.terminateAll(); try? FileManager.default.removeItem(at: root) }
        _ = try registry.launch(command: "sleep 5", workingDirectory: "/tmp", timeout: 30, conversationID: conversationID)

        let items = BackgroundTaskHistory.items(
            live: registry.snapshots(conversationID: conversationID),
            saved: [row("bg_9", log: "/l/old.log", startedAt: t0)],
            clearedBefore: Date())
        XCTAssertEqual(items.map(\.isRunning), [true], "cleared rows came back, or a running task was hidden")
    }

    func testTheClearCutoffIsPerConversation() {
        let defaults = UserDefaults(suiteName: "bghist-\(UUID())")!
        let other = UUID()
        BackgroundTaskHistory.markCleared(conversationID, now: t0, defaults: defaults)
        XCTAssertEqual(BackgroundTaskHistory.clearedBefore(conversationID, defaults: defaults), t0)
        XCTAssertNil(BackgroundTaskHistory.clearedBefore(other, defaults: defaults))
    }

    // MARK: - Reading an old run's output

    func testAnOldRunReadsItsLogFileWhileItExists() throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("bghist-\(UUID()).log")
        try Data("full build log\n".utf8).write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }
        let item = try XCTUnwrap(BackgroundTaskHistory.items(
            live: [], saved: [row("bg_1", log: file.path, tail: "tail only")], clearedBefore: nil).first)
        XCTAssertEqual(BackgroundTasksListView.logText(for: item, conversationID: conversationID), "full build log\n")
    }

    /// Past retention the file is gone; the saved tail is shown, and the text says why.
    func testASweptLogFallsBackToTheSavedTail() throws {
        let item = try XCTUnwrap(BackgroundTaskHistory.items(
            live: [], saved: [row("bg_1", log: "/nonexistent/\(UUID()).log", tail: "BUILD SUCCEEDED")],
            clearedBefore: nil).first)
        let text = BackgroundTasksListView.logText(for: item, conversationID: conversationID)
        XCTAssertTrue(text.contains("BUILD SUCCEEDED"), text)
        XCTAssertTrue(text.contains("removed after 7 days"), "the fallback must say it is not the full log: \(text)")
    }

    func testAnInterruptedRowSaysSoWithoutADuration() throws {
        let item = try XCTUnwrap(BackgroundTaskHistory.items(
            live: [], saved: [row("bg_1", log: "/l/a.log", status: .running)], clearedBefore: nil).first)
        let subtitle = BackgroundTasksListView.finishedSubtitle(item, now: t0.addingTimeInterval(50_000))
        XCTAssertTrue(subtitle.contains("Ended when the app quit"), subtitle)
        XCTAssertFalse(subtitle.contains("13h") || subtitle.contains("833m"), "a duration was invented: \(subtitle)")
    }

    // MARK: - The store and the view model (the wiring)

    private func inMemoryStore() throws -> (ChatPersistenceStore, ModelContainer?) {
        let store = ChatPersistenceStore.shared
        let previous = store.modelContainer
        let container = try ModelContainer(
            for: ConversationSD.self, ChatMessageSD.self,
            AttachedTextFileSD.self, AttachedImageFileSD.self, WorkflowRunRecordSD.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        store.configureContainer(container)
        store.addConversation(from: Conversation(id: conversationID, messages: [], timestamp: t0,
                                                 userDefinedTitle: "bg history", isPinned: false,
                                                 backendEntityId: nil))
        return (store, previous)
    }

    private func savedTurn(with events: [TimelineEvent], text: String = "answer", at offset: TimeInterval = 0) -> ChatMessage {
        let message = ChatMessage(id: UUID(), conversationId: conversationID,
                                  timestamp: t0.addingTimeInterval(offset), sender: .agent, content: .markdownText(text))
        message.timelineEvents = events
        return message
    }

    /// Rows saved in timelines come back, oldest first; a message whose TEXT mentions the word but
    /// has no task row is not mistaken for one (the byte check is only a pre-filter).
    func testTheStoreReturnsEverySavedTaskRow() async throws {
        let (store, previous) = try inMemoryStore()
        defer { if let previous { store.configureContainer(previous) } }

        await store.addMessage(savedTurn(with: [.backgroundTask(row("bg_1", log: "/l/a.log"))], at: 0), toConversation: conversationID)
        await store.addMessage(savedTurn(with: [.thought(id: UUID(), text: "no tasks")],
                                         text: "\"backgroundTask\" mentioned in prose", at: 10), toConversation: conversationID)
        await store.addMessage(savedTurn(with: [.backgroundTask(row("fg_2", log: "/l/b.log"))], at: 20), toConversation: conversationID)

        let rows = await store.fetchBackgroundTaskRows(for: conversationID)
        XCTAssertEqual(rows.map(\.taskID), ["bg_1", "fg_2"])
    }

    /// ⚠️ THE WIRING: after a relaunch (nothing live), the view model's list must include the saved
    /// history — which is what both the pill and the panel read.
    func testTheViewModelListsSavedHistoryWithNothingLive() async throws {
        let (store, previous) = try inMemoryStore()
        defer { if let previous { store.configureContainer(previous) } }
        await store.addMessage(savedTurn(with: [.backgroundTask(row("bg_1", log: "/l/\(UUID()).log"))]),
                               toConversation: conversationID)

        let viewModel = ChatHistoryViewModel(
            persistenceService: store,
            activeStreamManager: ActiveStreamManager(persistenceService: store, fileProcessorService: FileProcessorService()))
        await viewModel.refreshSavedBackgroundTasks(for: conversationID)

        XCTAssertEqual(viewModel.backgroundTaskItems(for: conversationID).map(\.taskID), ["bg_1"],
                       "the saved history does not reach the list")
        XCTAssertTrue(viewModel.backgroundTaskItems(for: UUID()).isEmpty,
                      "one conversation's history leaked into another")
    }

    /// Both surfaces must read the merged list, not the registry alone.
    func testThePillAndThePanelReadTheMergedList() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        for path in ["Devgentic/Interfaces/Shared/Chat/BackgroundTasksFloatingButton.swift",
                     "Devgentic/Interfaces/Shared/Chat/BackgroundTasksListView.swift"] {
            guard let text = try? String(contentsOf: root.appendingPathComponent(path), encoding: .utf8) else {
                throw XCTSkip("\(path) not reachable — running outside a checkout")
            }
            XCTAssertTrue(text.contains("chatHistoryViewModel.backgroundTaskItems(for: conversationID)"),
                          "\(path) no longer reads the merged list")
            XCTAssertTrue(text.contains("await chatHistoryViewModel.refreshSavedBackgroundTasks(for: conversationID)"),
                          "\(path) never loads the saved history")
        }
    }
}
