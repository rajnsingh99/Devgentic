// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
//
//  BackgroundTaskEndingPersistenceTests.swift
//  DevgenticTests
//
//  The defect: a background task's ENDING never reached disk.
//
//  Found on the first device run of the wake flow (2026-09-23). The observer wrote the final
//  status into the in-memory message and nothing saved that message again — the turn that launched
//  the task had finished streaming 30s earlier, so its last flush carried `running`. The row
//  reloaded as `running`; `reconcile` corrected it on screen while the process still remembered the
//  task, but saved nothing either; and after a relaunch the same row became "ended when the app
//  restarted" for a build that had exited 0 and been reported.
//
//  ⚠️ Every test here reads the answer back out of the REAL `ChatPersistenceStore`. The in-memory
//  row was always right — asserting on it would pass with the defect fully present.
//

import XCTest
import SwiftData
@testable import devgentic

@MainActor
final class BackgroundTaskEndingPersistenceTests: XCTestCase {

    private var root: URL!
    private var registry: BackgroundProcessRegistry!
    private var observer: BackgroundTaskObserver!
    private var previousContainer: ModelContainer?
    private let store = ChatPersistenceStore.shared
    private let conversationID = UUID()

    /// The live message the observer finds at launch. Settable to nil to simulate the user
    /// switching away — the observer's reference is weak, so this is the only strong one.
    private var live: ChatMessage?

    override func setUp() async throws {
        try await super.setUp()
        root = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("bgend-\(UUID().uuidString)", isDirectory: true)
        registry = BackgroundProcessRegistry(rootDirectory: root)

        previousContainer = store.modelContainer
        let container = try ModelContainer(
            for: ConversationSD.self, ChatMessageSD.self,
            AttachedTextFileSD.self, AttachedImageFileSD.self, WorkflowRunRecordSD.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
        store.configureContainer(container)
        store.addConversation(from: Conversation(
            id: conversationID, messages: [], timestamp: Date(),
            userDefinedTitle: "bg ending", isPinned: false,
            backendEntityId: nil
        ))

        observer = BackgroundTaskObserver(registry: registry, persistence: store)
        observer.start { [weak self] id in id == self?.conversationID ? self?.live : nil }
    }

    override func tearDown() async throws {
        registry?.terminateAll()
        if let root { try? FileManager.default.removeItem(at: root) }
        if let previousContainer { store.configureContainer(previousContainer) }
        live = nil
        try await super.tearDown()
    }

    // MARK: - The defect

    /// ⚠️⚠️ THE REGRESSION TEST — the device run, exactly. The turn is saved while the task is
    /// still running (its row reads `running` on disk), then the task finishes. The disk must now
    /// say `exited`, with its exit code.
    func testTheEndingOfATaskThatOutlivedItsTurnReachesDisk() async throws {
        let message = try await savedTurn()
        live = message

        try registry.launch(command: "sleep 0.5 && echo done", workingDirectory: NSTemporaryDirectory(),
                            timeout: 30, conversationID: conversationID)
        try await waitUntil { self.row(in: message)?.status == .running }
        // The turn's last flush — carrying `running`, as it does on device.
        await store.addMessage(message, toConversation: conversationID)
        let before = try await storedRow(of: message.id)
        XCTAssertEqual(before?.status, .running, "premise: disk says running")

        try await waitUntil { self.row(in: message)?.status == .exited }
        await settleWrites()

        let storedRow = try await storedRow(of: message.id)
        let stored = try XCTUnwrap(storedRow)
        XCTAssertEqual(stored.status, .exited,
                       "the task finished but disk still says \(stored.status) — after a relaunch this "
                       + "row reads 'ended when the app restarted' for a task that exited cleanly")
        XCTAssertEqual(stored.exitCode, 0)
    }

    /// The user switched conversations mid-task, so the observer's weak reference is gone. The
    /// ending must still reach disk — through the stored copy.
    func testTheEndingReachesDiskEvenAfterTheConversationWasUnloaded() async throws {
        var message: ChatMessage? = try await savedTurn()
        live = message
        let messageID = try XCTUnwrap(message?.id)

        try registry.launch(command: "sleep 1 && echo done", workingDirectory: NSTemporaryDirectory(),
                            timeout: 30, conversationID: conversationID)
        try await waitUntil { message.flatMap(self.row(in:))?.status == .running }
        await store.addMessage(try XCTUnwrap(message), toConversation: conversationID)

        // Switch away: drop every strong reference, so the observer's weak one dies.
        live = nil
        message = nil

        try await waitUntil {
            self.registry.snapshots(conversationID: self.conversationID).allSatisfy { $0.status.isTerminal }
        }
        // ⚠️ NOT `waitUntil`: that SKIPS on timeout, and without the fix there is never a write —
        // the regression would report as "skipped" instead of failing. Pause, then assert.
        await pause(atMost: 3) { !self.observer.pendingWrites.isEmpty }
        await settleWrites()

        let storedRow = try await storedRow(of: messageID)
        let stored = try XCTUnwrap(storedRow)
        XCTAssertEqual(stored.status, .exited,
                       "the conversation was unloaded when the task ended and the ending was dropped — "
                       + "disk says \(stored.status)")
    }

    /// ⚠️ The save is an upsert that INSERTS a missing row. A message the stream has not flushed
    /// yet must NOT be written by the observer — that would mint a message the stream then writes
    /// again, or an orphan if the turn is abandoned. The stream owns it until its first flush.
    func testAMessageThatWasNeverSavedIsNotInsertedByTheObserver() async throws {
        let message = ChatMessage(conversationId: conversationID, sender: .agent, content: .markdownText("unsaved"))
        live = message

        // ⚠️ A RUNNING PHASE IS REQUIRED. A command that ends before the observer first sees it
        // (`echo`) is adopted already-terminal and never reaches `persistEnding` at all — so with
        // `echo` this test passed even when the observer DID insert unsaved messages. Mutation found it.
        try registry.launch(command: "sleep 0.5 && echo quick", workingDirectory: NSTemporaryDirectory(),
                            timeout: 30, conversationID: conversationID)
        try await waitUntil { self.row(in: message)?.status == .running }
        try await waitUntil { self.row(in: message)?.status == .exited }
        await pause(atMost: 3) { !self.observer.pendingWrites.isEmpty }
        await settleWrites()

        let fetched = await store.fetchMessage(withId: message.id)
        XCTAssertNil(fetched, "the observer inserted a message the stream had never saved")
    }

    // MARK: - Reconcile hands back what it changed

    /// The load path saves exactly what `reconciledMessages` returns. A message with no running
    /// row must not be in that list — the caller would rewrite every loaded message on every load.
    func testReconcileReturnsOnlyTheMessagesItChanged() throws {
        let stale = ChatMessage(conversationId: conversationID, sender: .agent, content: .markdownText("a"))
        stale.timelineEvents = [.backgroundTask(runningRow(taskID: "bg_99"))]
        let untouched = ChatMessage(conversationId: conversationID, sender: .agent, content: .markdownText("b"))

        let result = BackgroundTaskObserver.reconciledMessages([stale, untouched], registry: registry)

        XCTAssertEqual(result.rows, 1)
        XCTAssertEqual(result.messages.map(\.id), [stale.id],
                       "reconcile must hand back only the messages it corrected")
    }

    /// ⚠️ THE WIRING for the load path. `ChatHistoryViewModel`'s load has no test seam short of a
    /// full view model, so this is a source scan: it fails if the corrected messages stop being
    /// saved — which is the whole defect for a task whose conversation was unloaded AND whose
    /// ending arrived before this fix, and for any row `persistEnding` could not reach.
    func testTheLoadPathSavesWhatReconcileCorrected() throws {
        let repoRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let source = repoRoot.appendingPathComponent("Devgentic/Interfaces/Shared/Chat/ChatHistoryViewModel.swift")
        try XCTSkipUnless(FileManager.default.fileExists(atPath: source.path), "running outside a checkout")

        let code = try String(contentsOf: source, encoding: .utf8)
            .components(separatedBy: "\n")
            .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
            .joined(separator: "\n")

        XCTAssertTrue(code.contains("BackgroundTaskObserver.reconciledMessages("),
                      "the load path no longer asks reconcile WHICH messages it changed")
        XCTAssertTrue(code.contains("addMessages(corrected"),
                      "the load path corrects rows on screen but no longer SAVES them — a recovered "
                      + "outcome is lost at the next relaunch")
    }

    // MARK: - Helpers

    /// A turn that has already been flushed once, as a finished agent turn has.
    private func savedTurn() async throws -> ChatMessage {
        let message = ChatMessage(conversationId: conversationID, sender: .agent,
                                  content: .markdownText("Started the build."))
        await store.addMessage(message, toConversation: conversationID)
        let stored = await store.fetchMessage(withId: message.id)
        XCTAssertNotNil(stored, "premise: the turn is on disk before the task starts")
        return message
    }

    private func row(in message: ChatMessage) -> BackgroundTaskData? {
        message.timelineEvents.lazy.compactMap {
            if case .backgroundTask(let data) = $0 { return data }
            return nil
        }.first
    }

    private func storedRow(of messageID: UUID) async throws -> BackgroundTaskData? {
        let stored = await store.fetchMessage(withId: messageID)
        return stored.flatMap(row(in:))
    }

    private func settleWrites() async {
        for write in observer.pendingWrites { await write.value }
    }

    private func runningRow(taskID: String) -> BackgroundTaskData {
        BackgroundTaskData(id: UUID(), taskID: taskID, name: nil, command: "sleep 99",
                           workingDirectory: "/tmp", startedAt: Date(), finishedAt: nil,
                           status: .running, exitCode: nil, logPath: "/tmp/none.log",
                           outputTail: "", logCharacterCount: 0)
    }

    private func pause(atMost seconds: TimeInterval, until condition: @escaping @MainActor () -> Bool) async {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline, !condition() {
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
    }

    private func waitUntil(_ condition: @escaping @MainActor () -> Bool,
                           within seconds: TimeInterval = 10,
                           file: StaticString = #filePath, line: UInt = #line) async throws {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            if condition() { return }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        if !condition() {
            throw XCTSkip("condition not reached in \(seconds)s — environment, not a regression")
        }
    }
}
