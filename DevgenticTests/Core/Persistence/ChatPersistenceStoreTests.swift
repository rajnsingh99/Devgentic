//
//  ChatPersistenceStoreTests.swift
//  DevgenticTests
//
//  Created on 03/04/26.
//
//  Comprehensive tests for ChatPersistenceStore — the SwiftData persistence layer
//  for conversations and messages. Validates CRUD, upsert, cascade delete,
//  pagination, pin/unpin, backend association, and edge cases.
//

import XCTest
import SwiftData
@testable import devgentic

@MainActor
final class ChatPersistenceStoreTests: XCTestCase {

    private var container: ModelContainer!
    private var store: ChatPersistenceStore!

    // MARK: - Setup / Teardown

    override func setUp() async throws {
        let config = ModelConfiguration(isStoredInMemoryOnly: true)
        container = try ModelContainer(
            for: ConversationSD.self, ChatMessageSD.self,
            AttachedTextFileSD.self, AttachedImageFileSD.self,
            configurations: config
        )
        store = ChatPersistenceStore.shared
        store.configureContainer(container)
    }

    override func tearDown() async throws {
        // Each setUp reconfigures the container fresh, so no explicit cleanup needed.
        container = nil
        store = nil
    }

    // MARK: - Helpers

    private func makeConversation(
        id: UUID = UUID(),
        title: String? = nil,
        isPinned: Bool = false,
        backendType: BackendType? = nil,
        backendEntityId: UUID? = nil,
        messages: [ChatMessage] = []
    ) -> Conversation {
        Conversation(
            id: id,
            messages: messages,
            timestamp: Date(),
            userDefinedTitle: title,
            isPinned: isPinned,
            backendType: backendType,
            backendEntityId: backendEntityId
        )
    }

    private func makeUserMessage(
        conversationId: UUID,
        text: String = "Hello",
        timestamp: Date = Date()
    ) -> ChatMessage {
        ChatMessage(
            conversationId: conversationId,
            timestamp: timestamp,
            sender: .user,
            content: .plainText(text)
        )
    }

    private func makeAgentMessage(
        conversationId: UUID,
        text: String = "Hi there!",
        timestamp: Date = Date(),
        backendEntityId: UUID? = nil
    ) -> ChatMessage {
        ChatMessage(
            conversationId: conversationId,
            timestamp: timestamp,
            sender: .agent,
            content: .markdownText(text),
            backendEntityId: backendEntityId
        )
    }

    // MARK: - Add & Get Conversation

    func testAddConversationAndRetrieve() {
        let convId = UUID()
        let conv = makeConversation(id: convId, title: "Test Chat")

        store.addConversation(from: conv)

        let fetched = store.getConversation(withId: convId)
        XCTAssertNotNil(fetched)
        XCTAssertEqual(fetched?.id, convId)
        XCTAssertEqual(fetched?.userDefinedTitle, "Test Chat")
        XCTAssertFalse(fetched?.isPinned ?? true)
    }

    func testAddConversationWithMessages() {
        let convId = UUID()
        let userMsg = makeUserMessage(conversationId: convId, text: "What is Swift?")
        let agentMsg = makeAgentMessage(conversationId: convId, text: "Swift is a programming language.")
        let conv = makeConversation(id: convId, title: "Swift Chat", messages: [userMsg, agentMsg])

        store.addConversation(from: conv)

        let fetched = store.getConversation(withId: convId)
        XCTAssertNotNil(fetched)
        XCTAssertEqual(fetched?.messages.count, 2)
    }

    func testGetConversationReturnsNilForUnknownId() {
        let result = store.getConversation(withId: UUID())
        XCTAssertNil(result)
    }

    func testAddConversationWithBackendAssociation() {
        let convId = UUID()
        let profileId = UUID()
        let conv = makeConversation(id: convId, backendType: .agent, backendEntityId: profileId)

        store.addConversation(from: conv)

        let fetched = store.getConversation(withId: convId)
        XCTAssertEqual(fetched?.backendType, BackendType.agent.rawValue)
        XCTAssertEqual(fetched?.backendEntityId, profileId)
    }

    func testAddConversationWithPinnedStatus() {
        let convId = UUID()
        let conv = makeConversation(id: convId, isPinned: true)

        store.addConversation(from: conv)

        let fetched = store.getConversation(withId: convId)
        XCTAssertTrue(fetched?.isPinned ?? false)
    }

    // MARK: - Add Messages

    func testAddSingleMessage() async {
        let convId = UUID()
        store.addConversation(from: makeConversation(id: convId))

        let msg = makeUserMessage(conversationId: convId, text: "Test message")
        await store.addMessage(msg, toConversation: convId)

        let messages = await store.fetchMessages(for: convId, offset: 0, limit: 10)
        XCTAssertEqual(messages.count, 1)
        XCTAssertEqual(messages.first?.content.textContent, "Test message")
    }

    func testAddMultipleMessages() async {
        let convId = UUID()
        store.addConversation(from: makeConversation(id: convId))

        let msgs = (0..<5).map { i in
            makeUserMessage(conversationId: convId, text: "Message \(i)",
                          timestamp: Date().addingTimeInterval(Double(i)))
        }
        await store.addMessages(msgs, toConversation: convId)

        let fetched = await store.fetchMessages(for: convId, offset: 0, limit: 10)
        XCTAssertEqual(fetched.count, 5)
    }

    func testAddMessageToNonExistentConversation() async {
        // Should not crash — gracefully handles missing conversation
        let msg = makeUserMessage(conversationId: UUID(), text: "Orphan message")
        await store.addMessage(msg, toConversation: UUID())
        // No assertion needed — just verifying no crash
    }

    // MARK: - Upsert (Update Existing Message)

    func testUpsertUpdatesExistingMessage() async {
        let convId = UUID()
        store.addConversation(from: makeConversation(id: convId))

        let msg = makeAgentMessage(conversationId: convId, text: "Initial response")
        await store.addMessage(msg, toConversation: convId)

        // Mutate the same message object (same ID)
        msg.agentResponse?.variants[0].content = .markdownText("Updated response")
        await store.addMessage(msg, toConversation: convId)

        let fetched = await store.fetchMessages(for: convId, offset: 0, limit: 10)
        XCTAssertEqual(fetched.count, 1, "Upsert should not duplicate the message")

        // The persisted content should reflect the agent response variant
        let content = fetched.first?.currentAgentContent ?? fetched.first?.content
        XCTAssertEqual(content?.textContent, "Updated response")
    }

    func testUpsertPreservesMessageId() async {
        let convId = UUID()
        store.addConversation(from: makeConversation(id: convId))

        let msg = makeUserMessage(conversationId: convId, text: "Original")
        let originalId = msg.id
        await store.addMessage(msg, toConversation: convId)

        msg.content = .plainText("Modified")
        await store.addMessage(msg, toConversation: convId)

        let fetched = await store.fetchMessages(for: convId, offset: 0, limit: 10)
        XCTAssertEqual(fetched.count, 1)
        XCTAssertEqual(fetched.first?.id, originalId)
    }

    // MARK: - Fetch Messages (Pagination)

    func testFetchMessagesPagination() async {
        let convId = UUID()
        store.addConversation(from: makeConversation(id: convId))

        // Insert 15 messages with sequential timestamps
        let msgs = (0..<15).map { i in
            makeUserMessage(conversationId: convId, text: "Msg \(i)",
                          timestamp: Date().addingTimeInterval(Double(i)))
        }
        await store.addMessages(msgs, toConversation: convId)

        // Page 1: offset 0, limit 10
        let page1 = await store.fetchMessages(for: convId, offset: 0, limit: 10)
        XCTAssertEqual(page1.count, 10)

        // Page 2: offset 10, limit 10
        let page2 = await store.fetchMessages(for: convId, offset: 10, limit: 10)
        XCTAssertEqual(page2.count, 5)

        // Ensure no overlap
        let page1Ids = Set(page1.map(\.id))
        let page2Ids = Set(page2.map(\.id))
        XCTAssertTrue(page1Ids.isDisjoint(with: page2Ids), "Pagination pages should not overlap")
    }

    func testFetchMessagesReturnsNewestFirst() async {
        let convId = UUID()
        store.addConversation(from: makeConversation(id: convId))

        let old = makeUserMessage(conversationId: convId, text: "Old",
                                  timestamp: Date().addingTimeInterval(-100))
        let new = makeUserMessage(conversationId: convId, text: "New",
                                  timestamp: Date())
        await store.addMessages([old, new], toConversation: convId)

        let fetched = await store.fetchMessages(for: convId, offset: 0, limit: 10)
        XCTAssertEqual(fetched.first?.content.textContent, "New")
        XCTAssertEqual(fetched.last?.content.textContent, "Old")
    }

    func testFetchMessagesForEmptyConversation() async {
        let convId = UUID()
        store.addConversation(from: makeConversation(id: convId))

        let fetched = await store.fetchMessages(for: convId, offset: 0, limit: 10)
        XCTAssertTrue(fetched.isEmpty)
    }

    func testFetchMessagesForNonExistentConversation() async {
        let fetched = await store.fetchMessages(for: UUID(), offset: 0, limit: 10)
        XCTAssertTrue(fetched.isEmpty)
    }

    // MARK: - Delete Conversation (Cascade)

    func testDeleteConversationRemovesMessages() async {
        let convId = UUID()
        let msg = makeUserMessage(conversationId: convId, text: "Will be deleted")
        store.addConversation(from: makeConversation(id: convId, messages: [msg]))

        // Verify it exists
        XCTAssertNotNil(store.getConversation(withId: convId))

        // Delete
        store.deleteConversation(with: convId)

        // Verify conversation gone
        XCTAssertNil(store.getConversation(withId: convId))

        // Verify messages gone (cascade)
        let messages = await store.fetchMessages(for: convId, offset: 0, limit: 10)
        XCTAssertTrue(messages.isEmpty)
    }

    func testDeleteNonExistentConversation() {
        // Should not crash
        store.deleteConversation(with: UUID())
    }

    // MARK: - Toggle Pin

    func testTogglePinStatus() {
        let convId = UUID()
        store.addConversation(from: makeConversation(id: convId, isPinned: false))

        store.togglePinStatus(for: convId)
        XCTAssertTrue(store.getConversation(withId: convId)?.isPinned ?? false)

        store.togglePinStatus(for: convId)
        XCTAssertFalse(store.getConversation(withId: convId)?.isPinned ?? true)
    }

    func testTogglePinForNonExistentConversation() {
        // Should not crash
        store.togglePinStatus(for: UUID())
    }

    // MARK: - Update Backend

    func testUpdateBackendForConversation() {
        let convId = UUID()
        let profileId = UUID()
        store.addConversation(from: makeConversation(id: convId))

        store.updateBackendForConversation(id: convId, backendType: .agent, backendEntityId: profileId)

        let fetched = store.getConversation(withId: convId)
        XCTAssertEqual(fetched?.backendType, BackendType.agent.rawValue)
        XCTAssertEqual(fetched?.backendEntityId, profileId)
    }

    func testUpdateBackendClearsExisting() {
        let convId = UUID()
        store.addConversation(from: makeConversation(id: convId, backendType: .agent, backendEntityId: UUID()))

        store.updateBackendForConversation(id: convId, backendType: nil, backendEntityId: nil)

        let fetched = store.getConversation(withId: convId)
        XCTAssertNil(fetched?.backendType)
        XCTAssertNil(fetched?.backendEntityId)
    }

    // MARK: - Update OpenAI Thread ID

    func testUpdateOpenAIThreadID() {
        let convId = UUID()
        store.addConversation(from: makeConversation(id: convId))

        store.updateOpenAIThreadID(for: convId, with: "thread_abc123")

        let fetched = store.getConversation(withId: convId)
        XCTAssertEqual(fetched?.openAIThreadID, "thread_abc123")
    }

    func testUpdateOpenAIThreadIDForNonExistentConversation() {
        // Should not crash
        store.updateOpenAIThreadID(for: UUID(), with: "thread_xyz")
    }

    // MARK: - ConversationSD → Conversation Struct Mapping

    func testToStructMapping() async {
        let convId = UUID()
        let profileId = UUID()
        let msg = makeUserMessage(conversationId: convId, text: "Mapped message")
        let conv = makeConversation(id: convId, title: "Mapped Conv",
                                    isPinned: true, backendType: .agent,
                                    backendEntityId: profileId, messages: [msg])

        store.addConversation(from: conv)

        let sd = store.getConversation(withId: convId)!
        let result = sd.toStruct()

        XCTAssertEqual(result.id, convId)
        XCTAssertEqual(result.userDefinedTitle, "Mapped Conv")
        XCTAssertTrue(result.isPinned)
        XCTAssertEqual(result.backendType, .agent)
        XCTAssertEqual(result.backendEntityId, profileId)
        XCTAssertEqual(result.messages.count, 1)
        XCTAssertEqual(result.messages.first?.content.textContent, "Mapped message")
    }

    // MARK: - Conversation Timestamp Update

    func testAddMessageUpdatesConversationTimestamp() async {
        let convId = UUID()
        let earlyDate = Date().addingTimeInterval(-3600)
        let conv = Conversation(id: convId, messages: [], timestamp: earlyDate)
        store.addConversation(from: conv)

        let msg = makeUserMessage(conversationId: convId)
        await store.addMessage(msg, toConversation: convId)

        let fetched = store.getConversation(withId: convId)
        // Conversation timestamp should be updated to ~now
        XCTAssertGreaterThan(fetched?.timestamp ?? earlyDate, earlyDate)
    }

    // MARK: - Multiple Conversations Isolation

    func testMultipleConversationsDoNotInterfere() async {
        let conv1Id = UUID()
        let conv2Id = UUID()
        store.addConversation(from: makeConversation(id: conv1Id, title: "Conv 1"))
        store.addConversation(from: makeConversation(id: conv2Id, title: "Conv 2"))

        await store.addMessage(makeUserMessage(conversationId: conv1Id, text: "In conv 1"), toConversation: conv1Id)
        await store.addMessage(makeUserMessage(conversationId: conv2Id, text: "In conv 2"), toConversation: conv2Id)

        let msgs1 = await store.fetchMessages(for: conv1Id, offset: 0, limit: 10)
        let msgs2 = await store.fetchMessages(for: conv2Id, offset: 0, limit: 10)

        XCTAssertEqual(msgs1.count, 1)
        XCTAssertEqual(msgs2.count, 1)
        XCTAssertEqual(msgs1.first?.content.textContent, "In conv 1")
        XCTAssertEqual(msgs2.first?.content.textContent, "In conv 2")
    }

    // MARK: - Stress: High Message Volume

    func testHighVolumeMessageInsert() async {
        let convId = UUID()
        store.addConversation(from: makeConversation(id: convId))

        let msgs = (0..<100).map { i in
            makeUserMessage(conversationId: convId, text: "Msg \(i)",
                          timestamp: Date().addingTimeInterval(Double(i)))
        }
        await store.addMessages(msgs, toConversation: convId)

        let page = await store.fetchMessages(for: convId, offset: 0, limit: 100)
        XCTAssertEqual(page.count, 100)
    }

}

