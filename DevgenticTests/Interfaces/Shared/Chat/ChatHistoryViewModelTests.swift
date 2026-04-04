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

    // MARK: - User Messages Filter

    func testToggleUserMessagesFilter() async {
        let convId = UUID()
        let userMsg = ChatMessage(conversationId: convId, sender: .user, content: .plainText("User"))
        let agentMsg = ChatMessage(conversationId: convId, sender: .agent, content: .markdownText("Agent"), backendEntityId: UUID())
        mockStore.messages[convId] = [userMsg, agentMsg]

        await viewModel.loadConversation(id: convId)
        XCTAssertEqual(viewModel.currentChatMessages.count, 2)

        viewModel.isUserMessagesOnlyFilterActive = true
        // Toggle triggers reload internally
        viewModel.toggleUserMessagesFilter()
        // Wait for the async reload
        try? await Task.sleep(nanoseconds: 100_000_000)
    }

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

        XCTAssertNotNil(viewModel.codeViewerContent)
        XCTAssertEqual(viewModel.codeViewerContent?.snippets.count, 1)
        XCTAssertEqual(viewModel.codeViewerContent?.currentIndex, 0)
    }

    func testHideCodeViewer() {
        viewModel.showCodeInViewer(language: "swift", code: "let x = 1")
        viewModel.hideCodeViewer()

        XCTAssertNil(viewModel.codeViewerContent)
        XCTAssertFalse(viewModel.isShowingDiff)
        XCTAssertNil(viewModel.originalCodeForDiff)
    }

    func testNavigateSnippets() {
        let snippet1 = CodeSnippet(language: "swift", code: "let a = 1")
        let snippet2 = CodeSnippet(language: "python", code: "a = 1")
        viewModel.codeViewerContent = (snippets: [snippet1, snippet2], currentIndex: 0)

        viewModel.navigateToNextSnippet()
        XCTAssertEqual(viewModel.codeViewerContent?.currentIndex, 1)

        viewModel.navigateToPreviousSnippet()
        XCTAssertEqual(viewModel.codeViewerContent?.currentIndex, 0)

        // Should not go below 0
        viewModel.navigateToPreviousSnippet()
        XCTAssertEqual(viewModel.codeViewerContent?.currentIndex, 0)
    }

    // MARK: - Copy to Clipboard

    func testCopyMessageContent() {
        let msg = ChatMessage(conversationId: UUID(), sender: .user, content: .plainText("Copy me"))
        viewModel.copyMessageContentToClipboard(message: msg)

        let pasteboard = NSPasteboard.general
        XCTAssertEqual(pasteboard.string(forType: .string), "Copy me")
    }
}
