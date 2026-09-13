// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2026 Raj Singh
//
//  ChatHistoryViewModelTests.swift
//  DevgenticTests
//
//  Created on 03/04/26.
//
//  Tests ChatHistoryViewModel — paginated message loading, active stream merging,
//  filter toggling, code viewer lifecycle, and edge cases.
//  Uses a MockChatPersistenceStore to isolate from SwiftData.
//

import XCTest
import SwiftData
@testable import devgentic

// MARK: - Mock Persistence Store

@MainActor
private final class MockChatPersistenceStore: ChatPersistenceProtocol {

    var conversations: [UUID: Conversation] = [:]
    var messages: [UUID: [ChatMessage]] = [:]  // keyed by conversationId

    var addConversationCallCount = 0
    var addMessagesCallCount = 0
    var fetchMessagesCallCount = 0

    func addConversation(from conversation: Conversation) {
        conversations[conversation.id] = conversation
        addConversationCallCount += 1
    }

    func addMessage(_ message: ChatMessage, toConversation conversationId: UUID) async {
        await addMessages([message], toConversation: conversationId)
    }

    func addMessages(_ msgs: [ChatMessage], toConversation conversationId: UUID) async {
        var existing = messages[conversationId] ?? []
        for msg in msgs {
            if let idx = existing.firstIndex(where: { $0.id == msg.id }) {
                existing[idx] = msg
            } else {
                existing.append(msg)
            }
        }
        messages[conversationId] = existing
        addMessagesCallCount += 1
    }

    func getConversation(withId id: UUID) -> ConversationSD? {
        return nil // Not needed for ChatHistoryVM tests
    }

    func fetchMessages(for conversationId: UUID, offset: Int, limit: Int) async -> [ChatMessage] {
        fetchMessagesCallCount += 1
        let all = messages[conversationId] ?? []
        // Sort newest first (matching real store behavior)
        let sorted = all.sorted { $0.timestamp > $1.timestamp }
        let start = min(offset, sorted.count)
        let end = min(start + limit, sorted.count)
        return Array(sorted[start..<end])
    }

    func updateOpenAIThreadID(for conversationId: UUID, with threadId: String) {}
    func deleteConversation(with id: UUID) { conversations.removeValue(forKey: id) }
    func updateBackendForConversation(id: UUID, backendType: BackendType?, backendEntityId: UUID?) {}
    func updateProfileType(for conversationId: UUID, profileTypeRaw: String) {}
    func togglePinStatus(for conversationId: UUID) {}
}

// MARK: - Mock Active Stream Manager Helpers

@MainActor
private func makeStreamManager(persistenceService: ChatPersistenceProtocol) -> ActiveStreamManager {
    ActiveStreamManager(
        persistenceService: persistenceService,
        fileProcessorService: FileProcessorService()
    )
}

// MARK: - Tests

@MainActor
final class ChatHistoryViewModelTests: XCTestCase {

    private var mockStore: MockChatPersistenceStore!
    private var streamManager: ActiveStreamManager!
    private var viewModel: ChatHistoryViewModel!

    override func setUp() async throws {
        mockStore = MockChatPersistenceStore()
        streamManager = makeStreamManager(persistenceService: mockStore)
        viewModel = ChatHistoryViewModel(
            persistenceService: mockStore,
            activeStreamManager: streamManager
        )
    }

    override func tearDown() async throws {
        viewModel = nil
        streamManager = nil
        mockStore = nil
    }

    // MARK: - Helpers

    private func seedMessages(conversationId: UUID, count: Int) {
        let msgs = (0..<count).map { i in
            ChatMessage(
                conversationId: conversationId,
                timestamp: Date().addingTimeInterval(Double(i)),
                sender: i.isMultiple(of: 2) ? .user : .agent,
                content: .plainText("Message \(i)"),
                backendEntityId: i.isMultiple(of: 2) ? nil : UUID()
            )
        }
        mockStore.messages[conversationId] = msgs
    }

    // MARK: - Load Conversation

    func testLoadConversationFetchesMessages() async {
        let convId = UUID()
        seedMessages(conversationId: convId, count: 5)

        await viewModel.loadConversation(id: convId)

        XCTAssertEqual(viewModel.currentChatMessages.count, 5)
        XCTAssertEqual(mockStore.fetchMessagesCallCount, 1)
        XCTAssertFalse(viewModel.isInitiallyLoadingConversation)
    }

    func testLoadNilConversationClearsMessages() async {
        let convId = UUID()
        seedMessages(conversationId: convId, count: 3)
        await viewModel.loadConversation(id: convId)
        XCTAssertEqual(viewModel.currentChatMessages.count, 3)

        await viewModel.loadConversation(id: nil)
        XCTAssertTrue(viewModel.currentChatMessages.isEmpty)
    }

    func testLoadEmptyConversation() async {
        let convId = UUID()
        mockStore.messages[convId] = []

        await viewModel.loadConversation(id: convId)
        XCTAssertTrue(viewModel.currentChatMessages.isEmpty)
    }

    // MARK: - Pagination

    func testCanLoadMorePagesWhenFull() async {
        let convId = UUID()
        seedMessages(conversationId: convId, count: 25)

        await viewModel.loadConversation(id: convId)

        // Initial page size is 20 — store returns 20, so canLoadMorePages should be true
        XCTAssertTrue(viewModel.canLoadMorePages)
    }

    func testCannotLoadMorePagesWhenPartial() async {
        let convId = UUID()
        seedMessages(conversationId: convId, count: 5)

        await viewModel.loadConversation(id: convId)

        // Only 5 messages returned (< initial page size of 20)
        XCTAssertFalse(viewModel.canLoadMorePages)
    }

    func testLoadMoreMessagesAppends() async {
        let convId = UUID()
        seedMessages(conversationId: convId, count: 25)

        await viewModel.loadConversation(id: convId)
        let initialCount = viewModel.currentChatMessages.count

        await viewModel.loadMoreMessages()

        XCTAssertGreaterThan(viewModel.currentChatMessages.count, initialCount)
    }

    // MARK: - Messages Order

    func testMessagesStoredNewestFirst() async {
        let convId = UUID()
        let oldMsg = ChatMessage(
            conversationId: convId,
            timestamp: Date().addingTimeInterval(-100),
            sender: .user,
            content: .plainText("Old")
        )
        let newMsg = ChatMessage(
            conversationId: convId,
            timestamp: Date(),
            sender: .user,
            content: .plainText("New")
        )
        mockStore.messages[convId] = [oldMsg, newMsg]

        await viewModel.loadConversation(id: convId)

        // Descending order: newest first
        XCTAssertEqual(viewModel.currentChatMessages.first?.content.textContent, "New")
        XCTAssertEqual(viewModel.currentChatMessages.last?.content.textContent, "Old")
    }

    // [vm-9] `testToggleUserMessagesFilter` lived here. It set the flag, called the toggle,
    // slept 100 ms and asserted NOTHING — it would have passed over any behaviour at all,
    // including the in-place mutation of `currentChatMessages` that made the next page load
    // fetch from the wrong offset and append duplicate rows. Deleted with the feature, which
    // had no production entry point in any build.

    // MARK: - Sending State

    func testResetSendingState() async {
        viewModel.isSending = true
        XCTAssertTrue(viewModel.isSending)

        await viewModel.resetSendingState()
        XCTAssertFalse(viewModel.isSending)
    }

    // MARK: - Code Viewer

    func testShowCodeInViewer() {
        viewModel.showCodeInViewer(language: "swift", code: "let x = 1")

        XCTAssertTrue(viewModel.isCodeViewerPanelPresented)
        XCTAssertEqual(viewModel.codeViewerTabs.count, 1)
        XCTAssertEqual(viewModel.activeCodeViewerTabID, viewModel.codeViewerTabs.first?.id,
                       "The opened tab must be the active one")
    }

    func testCloseAllCodeViewerTabs() {
        viewModel.showCodeInViewer(language: "swift", code: "let x = 1")
        viewModel.closeAllCodeViewerTabs()

        XCTAssertTrue(viewModel.codeViewerTabs.isEmpty)
        XCTAssertFalse(viewModel.isCodeViewerVisible)
        XCTAssertNil(viewModel.activeCodeViewerTabID)
    }

    /// Minimize keeps the tabs alive (the floating reopen button takes over); reopen
    /// brings the same tabs back.
    func testMinimizeKeepsTabsThenReopen() {
        viewModel.showCodeInViewer(language: "swift", code: "let x = 1")

        viewModel.minimizeCodeViewer()
        XCTAssertFalse(viewModel.isCodeViewerVisible)
        XCTAssertEqual(viewModel.codeViewerTabs.count, 1, "Minimize must NOT drop the tabs")
        XCTAssertTrue(viewModel.isCodeViewerMinimized)

        viewModel.reopenCodeViewer()
        XCTAssertTrue(viewModel.isCodeViewerVisible)
        XCTAssertTrue(viewModel.isCodeViewerPanelPresented)
    }

    func testNavigateTabs() {
        let snippet1 = CodeSnippet(language: "swift", code: "let a = 1")
        let snippet2 = CodeSnippet(language: "python", code: "a = 1")
        viewModel.codeViewerTabs = [CodeViewerTab(snippet: snippet1), CodeViewerTab(snippet: snippet2)]
        viewModel.activeCodeViewerTabID = viewModel.codeViewerTabs.first?.id
        viewModel.isCodeViewerVisible = true

        viewModel.navigateToNextSnippet()
        XCTAssertEqual(viewModel.activeCodeViewerTabID, viewModel.codeViewerTabs[1].id)

        viewModel.navigateToPreviousSnippet()
        XCTAssertEqual(viewModel.activeCodeViewerTabID, viewModel.codeViewerTabs[0].id)

        // Should not move before the first tab
        viewModel.navigateToPreviousSnippet()
        XCTAssertEqual(viewModel.activeCodeViewerTabID, viewModel.codeViewerTabs[0].id)
    }

    /// Presentation is a mode that survives minimize/reopen but clears with the tabs.
    func testPresentationTogglesAndClearsWithTabs() {
        viewModel.showCodeInViewer(language: "swift", code: "let x = 1")
        XCTAssertEqual(viewModel.codeViewerPresentation, .overlay, "Fresh viewer opens in overlay")

        viewModel.toggleCodeViewerExpansion()
        XCTAssertEqual(viewModel.codeViewerPresentation, .full)

        // Survives minimize → reopen (the pill round-trip must not lose the mode).
        viewModel.minimizeCodeViewer()
        viewModel.reopenCodeViewer()
        XCTAssertEqual(viewModel.codeViewerPresentation, .full)

        viewModel.toggleCodeViewerExpansion()
        XCTAssertEqual(viewModel.codeViewerPresentation, .overlay)

        // Clears when the viewer fully dismisses.
        viewModel.toggleCodeViewerExpansion()
        viewModel.closeAllCodeViewerTabs()
        XCTAssertEqual(viewModel.codeViewerPresentation, .overlay, "Dismissing the viewer must reset presentation")
    }

    /// Closing the LAST tab (not just close-all) also resets presentation.
    func testClosingLastTabResetsPresentation() {
        viewModel.showCodeInViewer(language: "swift", code: "let x = 1")
        viewModel.toggleCodeViewerExpansion()

        guard let tabID = viewModel.codeViewerTabs.first?.id else { return XCTFail("No tab opened") }
        viewModel.closeCodeViewerTab(id: tabID)

        XCTAssertTrue(viewModel.codeViewerTabs.isEmpty)
        XCTAssertEqual(viewModel.codeViewerPresentation, .overlay)
    }

    /// Split toggles against overlay, and full-width remembers it entered from split.
    func testSplitToggleAndFullRoundTrip() {
        viewModel.showCodeInViewer(language: "swift", code: "let x = 1")

        viewModel.toggleCodeViewerSplit()
        XCTAssertEqual(viewModel.codeViewerPresentation, .split)

        // full from split → back lands in split, not overlay.
        viewModel.toggleCodeViewerExpansion()
        XCTAssertEqual(viewModel.codeViewerPresentation, .full)
        viewModel.toggleCodeViewerExpansion()
        XCTAssertEqual(viewModel.codeViewerPresentation, .split,
                       "Restoring from full must return to the mode it was entered from")

        // From full, the split button goes STRAIGHT to split.
        viewModel.toggleCodeViewerExpansion()   // → full
        viewModel.toggleCodeViewerSplit()
        XCTAssertEqual(viewModel.codeViewerPresentation, .split)

        viewModel.toggleCodeViewerSplit()
        XCTAssertEqual(viewModel.codeViewerPresentation, .overlay)
    }

    // MARK: - Editable tabs

    /// Drafts live beside the immutable snippet; typing back to the original clears dirty.
    func testDraftLifecycleAndDirtyState() {
        viewModel.showCodeInViewer(language: "swift", code: "let a = 1")
        guard let id = viewModel.codeViewerTabs.first?.id else { return XCTFail("No tab") }
        XCTAssertFalse(viewModel.codeViewerTabs[0].isDirty)

        viewModel.updateCodeViewerDraft(tabID: id, content: "let a = 2")
        XCTAssertTrue(viewModel.codeViewerTabs[0].isDirty)
        XCTAssertEqual(viewModel.codeViewerTabs[0].effectiveCode, "let a = 2")
        XCTAssertEqual(viewModel.codeViewerTabs[0].snippet.code, "let a = 1",
                       "The snippet is the immutable chat block — edits must not mutate it")

        viewModel.updateCodeViewerDraft(tabID: id, content: "let a = 1")
        XCTAssertFalse(viewModel.codeViewerTabs[0].isDirty,
                       "Typing back to the restore point clears the dirty state")
    }

    /// Closing a dirty tab pends a confirmation; force-close discards. Clean closes never pend.
    func testDirtyCloseRequiresConfirmation() {
        viewModel.showCodeInViewer(language: "swift", code: "A")
        guard let id = viewModel.codeViewerTabs.first?.id else { return XCTFail("No tab") }
        viewModel.updateCodeViewerDraft(tabID: id, content: "B")

        viewModel.closeCodeViewerTab(id: id)
        XCTAssertEqual(viewModel.pendingCloseTabID, id, "Dirty close must pend, not close")
        XCTAssertEqual(viewModel.codeViewerTabs.count, 1, "Tab must survive until confirmed")

        viewModel.forceCloseCodeViewerTab(id: id)
        XCTAssertTrue(viewModel.codeViewerTabs.isEmpty)
        XCTAssertNil(viewModel.pendingCloseTabID)
    }

    func testDirtyCloseAllRequiresConfirmation() {
        viewModel.showCodeInViewer(language: "swift", code: "A")
        viewModel.showCodeInViewer(language: "python", code: "b = 1")
        guard let dirtyID = viewModel.codeViewerTabs.first?.id else { return XCTFail("No tab") }
        viewModel.updateCodeViewerDraft(tabID: dirtyID, content: "CHANGED")

        viewModel.closeAllCodeViewerTabs()
        XCTAssertTrue(viewModel.isPendingCloseAll, "Close-all with a dirty tab must pend")
        XCTAssertEqual(viewModel.codeViewerTabs.count, 2, "Tabs must survive until confirmed")

        viewModel.forceCloseAllCodeViewerTabs()
        XCTAssertTrue(viewModel.codeViewerTabs.isEmpty)
        XCTAssertFalse(viewModel.isPendingCloseAll)
    }

    /// Accumulation: opening blocks from different messages adds tabs rather than replacing.
    func testTabsAccumulateAcrossOpens() {
        viewModel.showCodeInViewer(language: "swift", code: "let a = 1")
        viewModel.showCodeInViewer(language: "python", code: "b = 2")

        XCTAssertEqual(viewModel.codeViewerTabs.count, 2, "Second open must ADD a tab, not replace")
        XCTAssertEqual(viewModel.activeCodeViewerTabID, viewModel.codeViewerTabs.last?.id,
                       "The most recently opened tab is focused")

        // Re-opening an identical block focuses the existing tab instead of duplicating it.
        viewModel.showCodeInViewer(language: "swift", code: "let a = 1")
        XCTAssertEqual(viewModel.codeViewerTabs.count, 2, "Re-opening the same block must not duplicate a tab")
        XCTAssertEqual(viewModel.activeCodeViewerTabID, viewModel.codeViewerTabs.first?.id,
                       "Re-opening focuses the existing tab")
    }

    // MARK: - Copy to Clipboard

    func testCopyMessageContent() {
        let msg = ChatMessage(conversationId: UUID(), sender: .user, content: .plainText("Copy me"))
        viewModel.copyMessageContentToClipboard(message: msg)

        let pasteboard = NSPasteboard.general
        XCTAssertEqual(pasteboard.string(forType: .string), "Copy me")
    }

    // MARK: - Compaction Checkpoint Splice

    /// A checkpoint is timestamped just AFTER the turns it summarized, so in a
    /// descending array it belongs in the middle — appending or prepending it would
    /// misorder the transcript and corrupt the history handed to the next turn.
    func testInsertCheckpoint_PlacedByTimestamp_NotAppended() {
        let convId = UUID()
        let base = Date()
        // Descending (newest first), as the view model stores them.
        viewModel.currentChatMessages = (0..<5).reversed().map { i in
            ChatMessage(
                conversationId: convId,
                timestamp: base.addingTimeInterval(Double(i)),
                sender: .user,
                content: .plainText("Message \(i)")
            )
        }

        // Sits between message 1 (t=1) and message 2 (t=2).
        let checkpoint = ChatMessage(
            conversationId: convId,
            timestamp: base.addingTimeInterval(1.5),
            sender: .agent,
            content: .checkpoint(summary: "Summary of turns 0-1")
        )

        viewModel.insertCheckpoint(checkpoint)

        XCTAssertEqual(viewModel.currentChatMessages.count, 6)
        let timestamps = viewModel.currentChatMessages.map(\.timestamp)
        XCTAssertEqual(timestamps, timestamps.sorted(by: >),
                       "History must remain sorted newest-first after the splice")
        let idx = viewModel.currentChatMessages.firstIndex { $0.id == checkpoint.id }
        XCTAssertEqual(idx, 3, "Checkpoint belongs between t=2 and t=1 in a descending array")
    }

    /// Mirrors the persistence-side upsert: a repeat must not double-render the card
    /// or inflate the history handed to the backend.
    func testInsertCheckpoint_IsIdempotentByID() {
        let convId = UUID()
        viewModel.currentChatMessages = [
            ChatMessage(conversationId: convId, timestamp: Date().addingTimeInterval(10),
                        sender: .user, content: .plainText("hi"))
        ]
        let checkpoint = ChatMessage(
            conversationId: convId,
            timestamp: Date(),
            sender: .agent,
            content: .checkpoint(summary: "Summary")
        )

        viewModel.insertCheckpoint(checkpoint)
        viewModel.insertCheckpoint(checkpoint)

        XCTAssertEqual(viewModel.currentChatMessages.count, 2, "A repeated checkpoint must not duplicate")
    }

    /// Background compaction can finish after the user switched chats. Splicing then would
    /// inject a foreign message into whatever transcript happens to be open.
    func testInsertCheckpoint_SkipsWhenDifferentConversationIsOpen() {
        let openConv = UUID()
        viewModel.currentChatMessages = [
            ChatMessage(conversationId: openConv, timestamp: Date(), sender: .user, content: .plainText("hi"))
        ]
        let checkpoint = ChatMessage(
            conversationId: UUID(), // a different conversation
            timestamp: Date().addingTimeInterval(-60),
            sender: .agent,
            content: .checkpoint(summary: "Summary for another chat")
        )

        viewModel.insertCheckpoint(checkpoint)

        XCTAssertEqual(viewModel.currentChatMessages.count, 1,
                       "A checkpoint for another conversation must not enter this transcript")
    }

    /// "New chat" between scheduling and completion: nothing loaded → skip, or an orphan
    /// card floats in the empty transcript until the next load wipes it.
    func testInsertCheckpoint_SkipsWhenNothingLoaded() {
        viewModel.currentChatMessages = []
        let checkpoint = ChatMessage(
            conversationId: UUID(),
            timestamp: Date(),
            sender: .agent,
            content: .checkpoint(summary: "Summary")
        )

        viewModel.insertCheckpoint(checkpoint)

        XCTAssertTrue(viewModel.currentChatMessages.isEmpty,
                      "No conversation loaded → the persisted copy is the only correct home")
    }

    /// The checkpoint must be findable by the next turn's compaction check — that is the
    /// whole point of the splice (otherwise the same turns get re-summarized every request).
    func testInsertCheckpoint_IsDiscoverableAsCheckpointContent() {
        let convId = UUID()
        viewModel.currentChatMessages = [
            ChatMessage(conversationId: convId, timestamp: Date(), sender: .user, content: .plainText("hi"))
        ]
        let checkpoint = ChatMessage(
            conversationId: convId,
            timestamp: Date().addingTimeInterval(-60),
            sender: .agent,
            content: .checkpoint(summary: "Prior summary")
        )

        viewModel.insertCheckpoint(checkpoint)

        let found = viewModel.currentChatMessages.last {
            if case .checkpoint = $0.content { return true }
            return false
        }
        XCTAssertNotNil(found, "HistoryCompactionService.findLatestCheckpoint must be able to see it")
    }

    // MARK: - Descending Insertion Index (pure)

    func testDescendingInsertionIndex_EmptyAndBoundaries() {
        let convId = UUID()
        let base = Date()
        let msgs = [2.0, 1.0, 0.0].map { offset in
            ChatMessage(conversationId: convId, timestamp: base.addingTimeInterval(offset),
                        sender: .user, content: .plainText("m"))
        }

        XCTAssertEqual(ChatHistoryViewModel.descendingInsertionIndex(for: base, in: []), 0,
                       "Empty history → index 0")
        XCTAssertEqual(ChatHistoryViewModel.descendingInsertionIndex(
            for: base.addingTimeInterval(5), in: msgs), 0, "Newest → front")
        XCTAssertEqual(ChatHistoryViewModel.descendingInsertionIndex(
            for: base.addingTimeInterval(-5), in: msgs), 3, "Oldest → end")
        XCTAssertEqual(ChatHistoryViewModel.descendingInsertionIndex(
            for: base.addingTimeInterval(1.5), in: msgs), 1, "Middle → after the newer entry")
    }

    /// Exact-tie goes before the equal-timestamped message, which keeps the checkpoint
    /// ahead of anything sharing its instant rather than silently sinking below it.
    func testDescendingInsertionIndex_ExactTie() {
        let convId = UUID()
        let base = Date()
        let msgs = [1.0, 0.0].map { offset in
            ChatMessage(conversationId: convId, timestamp: base.addingTimeInterval(offset),
                        sender: .user, content: .plainText("m"))
        }
        XCTAssertEqual(ChatHistoryViewModel.descendingInsertionIndex(
            for: base.addingTimeInterval(1.0), in: msgs), 0)
    }
}
