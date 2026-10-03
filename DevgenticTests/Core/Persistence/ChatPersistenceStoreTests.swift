// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
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
        backendEntityId: UUID? = nil,
        messages: [ChatMessage] = []
    ) -> Conversation {
        Conversation(
            id: id,
            messages: messages,
            timestamp: Date(),
            userDefinedTitle: title,
            isPinned: isPinned,
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

    private func makeImage(id: UUID = UUID(), name: String = "pic.png", byte: UInt8 = 0xAB, count: Int = 2048) -> AttachedImageFile {
        AttachedImageFile(
            id: id,
            name: name,
            url: URL(fileURLWithPath: "/tmp/\(name)"),
            fileExtension: "png",
            binaryData: Data(repeating: byte, count: count),
            size: Int64(count)
        )
    }

    private func makeUserImageMessage(
        conversationId: UUID,
        text: String = "look at this",
        images: [AttachedImageFile],
        timestamp: Date = Date()
    ) -> ChatMessage {
        ChatMessage(
            conversationId: conversationId,
            timestamp: timestamp,
            sender: .user,
            content: .plainText(text),
            attachedImageFiles: images
        )
    }

    /// All image rows currently in the store (the `@Attribute(.externalStorage)` owners).
    private func imageRows() throws -> [AttachedImageFileSD] {
        try container.mainContext.fetch(FetchDescriptor<AttachedImageFileSD>())
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
        let conv = makeConversation(id: convId, backendEntityId: profileId)

        store.addConversation(from: conv)

        let fetched = store.getConversation(withId: convId)
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

        store.updateBackendForConversation(id: convId, backendEntityId: profileId)

        let fetched = store.getConversation(withId: convId)
        XCTAssertEqual(fetched?.backendEntityId, profileId)
    }

    func testUpdateBackendClearsExisting() {
        let convId = UUID()
        store.addConversation(from: makeConversation(id: convId, backendEntityId: UUID()))

        store.updateBackendForConversation(id: convId, backendEntityId: nil)

        let fetched = store.getConversation(withId: convId)
        XCTAssertNil(fetched?.backendEntityId)
    }

    // MARK: - ConversationSD → Conversation Struct Mapping

    func testToStructMapping() async {
        let convId = UUID()
        let profileId = UUID()
        let msg = makeUserMessage(conversationId: convId, text: "Mapped message")
        let conv = makeConversation(id: convId, title: "Mapped Conv",
                                    isPinned: true,
                                    backendEntityId: profileId, messages: [msg])

        store.addConversation(from: conv)

        let sd = store.getConversation(withId: convId)!
        let result = sd.toStruct()

        XCTAssertEqual(result.id, convId)
        XCTAssertEqual(result.userDefinedTitle, "Mapped Conv")
        XCTAssertTrue(result.isPinned)
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

    // MARK: - Token Usage Persistence (P2, chat hardening round 3)

    /// P2: any tool-using agent run flushes mid-stream, INSERTing the row BEFORE the
    /// provider's `.tokenUsage` event arrives; finalize then takes the upsert's UPDATE
    /// branch — which never wrote `tokenUsageData`. The badge and conversation total
    /// were visible live but gone forever after reload.
    func testTokenUsageSurvivesUpsertUpdate() async {
        let convId = UUID()
        store.addConversation(from: makeConversation(id: convId))

        let msg = makeAgentMessage(conversationId: convId, text: "streaming…")
        await store.addMessage(msg, toConversation: convId)            // mid-stream flush → INSERT (no usage yet)

        msg.tokenUsage = TokenUsage(inputTokens: 11, outputTokens: 22, isEstimated: false)
        await store.addMessage(msg, toConversation: convId)            // finalize → UPDATE

        let reloaded = await store.fetchMessages(for: convId, offset: 0, limit: 10)
        XCTAssertEqual(reloaded.first?.tokenUsage?.inputTokens, 11,
                       "tokenUsage set after the first flush must survive the upsert UPDATE branch — losing it here erases the badge and the conversation total on every reload (P2).")
        XCTAssertEqual(reloaded.first?.tokenUsage?.outputTokens, 22)
    }

    // MARK: - Timeline Revision Skip (P4) + Sidebar Row Projection (P1)

    /// [P4] The flush skips re-encoding an UNCHANGED timeline — this pins that a
    /// CHANGED timeline is never skipped (the failure mode that would lose data).
    func testTimelineMutationBetweenUpsertsIsPersisted() async {
        let convId = UUID()
        store.addConversation(from: makeConversation(id: convId))

        let msg = makeAgentMessage(conversationId: convId)
        msg.appendTimelineEvent(.thought(id: UUID(), text: "first"))
        await store.addMessage(msg, toConversation: convId)          // INSERT (1 event)

        msg.appendTimelineEvent(.thought(id: UUID(), text: "second"))
        await store.addMessage(msg, toConversation: convId)          // UPDATE — revision changed, must encode

        let reloaded = await store.fetchMessages(for: convId, offset: 0, limit: 10)
        XCTAssertEqual(reloaded.first?.timelineEvents.count, 2,
                       "A timeline mutated between flushes must persist — the revision skip may only elide truly unchanged encodes (P4)")
    }

    /// [P4] Unchanged-timeline double-upsert still round-trips correctly (the skip
    /// path must be indistinguishable from an encode, minus the cost).
    func testUnchangedTimelineDoubleUpsertRoundTrips() async {
        let convId = UUID()
        store.addConversation(from: makeConversation(id: convId))

        let msg = makeAgentMessage(conversationId: convId)
        msg.appendTimelineEvent(.thought(id: UUID(), text: "only"))
        await store.addMessage(msg, toConversation: convId)
        await store.addMessage(msg, toConversation: convId)          // UPDATE — same revision, skip path

        let reloaded = await store.fetchMessages(for: convId, offset: 0, limit: 10)
        XCTAssertEqual(reloaded.first?.timelineEvents.count, 1)
    }

    /// [P1] The sidebar's row projection must derive the SAME title as the full
    /// projection — via the probe-message trick it reuses `Conversation.displayTitle`'s
    /// own selection + truncation, so parity here guards the whole contract.
    func testRowStructTitleMatchesFullProjection() async {
        let convId = UUID()
        store.addConversation(from: makeConversation(id: convId))
        // First message empty → title must come from the SECOND (first non-empty text).
        await store.addMessage(makeUserMessage(conversationId: convId, text: "", timestamp: Date().addingTimeInterval(-10)), toConversation: convId)
        await store.addMessage(makeUserMessage(conversationId: convId, text: "Refactor the parser to handle CRLF", timestamp: Date()), toConversation: convId)

        guard let sd = store.getConversation(withId: convId) else { XCTFail("conversation missing"); return }

        XCTAssertEqual(sd.toRowStruct().displayTitle, sd.toStruct().displayTitle,
                       "Row titles must never drift from the full projection (P1)")
        XCTAssertTrue(sd.toRowStruct().displayTitle.contains("Refactor the parser"))
    }

    /// [P1] User-defined titles short-circuit the probe entirely; empty conversations
    /// fall back exactly like the full projection.
    func testRowStructUserTitleAndEmptyParity() async {
        let namedId = UUID()
        store.addConversation(from: makeConversation(id: namedId, title: "My Named Chat"))
        await store.addMessage(makeUserMessage(conversationId: namedId, text: "ignored for title"), toConversation: namedId)

        let emptyId = UUID()
        store.addConversation(from: makeConversation(id: emptyId))

        guard let named = store.getConversation(withId: namedId),
              let empty = store.getConversation(withId: emptyId) else { XCTFail(); return }

        XCTAssertEqual(named.toRowStruct().displayTitle, "My Named Chat")
        XCTAssertEqual(empty.toRowStruct().displayTitle, empty.toStruct().displayTitle)
    }

    /// Control: the INSERT path already persisted usage (short runs with no mid-stream
    /// flush) — pins that the fix didn't disturb it, and proves this harness CAN
    /// round-trip usage at all.
    func testTokenUsagePersistsOnInsert() async {
        let convId = UUID()
        store.addConversation(from: makeConversation(id: convId))

        let msg = makeAgentMessage(conversationId: convId)
        msg.tokenUsage = TokenUsage(inputTokens: 5, outputTokens: 7, isEstimated: true)
        await store.addMessage(msg, toConversation: convId)

        let reloaded = await store.fetchMessages(for: convId, offset: 0, limit: 10)
        XCTAssertEqual(reloaded.first?.tokenUsage?.inputTokens, 5)
        XCTAssertEqual(reloaded.first?.tokenUsage?.isEstimated, true)
    }

    // MARK: - Image Attachment Reconcile (external-storage clone hazard)

    /// The UPDATE branch used to DELETE every `AttachedImageFileSD` (the
    /// `@Attribute(.externalStorage)` blob owner) and re-INSERT a new one with the SAME
    /// unique id + SAME bytes on every upsert — the pattern that makes CoreData try to
    /// clone an external `.interim` file the same save just removed ("Failed to clone
    /// external data reference … .interim doesn't exist"). The fix reconciles in place.
    /// This pins the durable invariant: upsert an image message TWICE → exactly one image
    /// row, bytes round-trip, and the row is REUSED (not delete-then-recreated), proven by
    /// a stable `persistentModelID`. (The on-disk clone error itself is verified on-device
    /// via `[IMG-PERSIST]` logging; an in-memory store doesn't exercise external files.)
    func testUpsertImageMessageTwice_singleDurableRow_bytesRoundTrip_noChurn() async throws {
        let convId = UUID()
        store.addConversation(from: makeConversation(id: convId))

        let bytes = Data((0..<4096).map { UInt8($0 & 0xFF) })
        let imageID = UUID()
        let image = AttachedImageFile(id: imageID, name: "pic.png",
                                      url: URL(fileURLWithPath: "/tmp/pic.png"),
                                      fileExtension: "png", binaryData: bytes, size: Int64(bytes.count))
        let msg = makeUserImageMessage(conversationId: convId, images: [image])

        await store.addMessage(msg, toConversation: convId)                 // INSERT
        let rowsAfterInsert = try imageRows()
        XCTAssertEqual(rowsAfterInsert.count, 1, "INSERT must write exactly one image row")
        let idAfterInsert = rowsAfterInsert.first!.persistentModelID

        await store.addMessage(msg, toConversation: convId)                 // UPDATE — identical images

        let rowsAfterUpdate = try imageRows()
        XCTAssertEqual(rowsAfterUpdate.count, 1,
            "Re-upserting an unchanged image message must not duplicate or orphan the external row")
        XCTAssertEqual(rowsAfterUpdate.first?.id, imageID)
        XCTAssertEqual(rowsAfterUpdate.first?.binaryData, bytes, "Image bytes must round-trip across the upsert")
        XCTAssertEqual(rowsAfterUpdate.first!.persistentModelID, idAfterInsert,
            "Unchanged image must be reconciled IN PLACE (same row reused), not delete-then-recreated — the pre-fix churn that raised the external-storage clone error")

        // And it reloads as a real message with its image.
        let reloaded = await store.fetchMessages(for: convId, offset: 0, limit: 10)
        XCTAssertEqual(reloaded.first?.attachedImageFiles?.count, 1)
        XCTAssertEqual(reloaded.first?.attachedImageFiles?.first?.binaryData, bytes)
    }

    /// The reconcile must still handle a genuinely-changed image set: grow (add) then
    /// shrink (remove). Survivors keep their row; only true adds insert and only true
    /// removes delete.
    func testUpsert_addThenRemoveImage_reconcilesWithoutDuplication() async throws {
        let convId = UUID()
        store.addConversation(from: makeConversation(id: convId))

        let a = makeImage(name: "a.png", byte: 0x11)
        let b = makeImage(name: "b.png", byte: 0x22)

        // 1) [a]
        let msg = makeUserImageMessage(conversationId: convId, images: [a])
        await store.addMessage(msg, toConversation: convId)
        XCTAssertEqual(try imageRows().count, 1)
        let aModelID = try imageRows().first { $0.id == a.id }!.persistentModelID

        // 2) [a, b] — a survives (row reused), b inserted
        msg.attachedImageFiles = [a, b]
        await store.addMessage(msg, toConversation: convId)
        let two = try imageRows()
        XCTAssertEqual(two.count, 2)
        XCTAssertEqual(Set(two.map(\.id)), [a.id, b.id])
        XCTAssertEqual(two.first { $0.id == a.id }!.persistentModelID, aModelID,
            "Surviving image 'a' must keep its row across an add")

        // 3) [b] — a removed, b survives (row reused)
        let bModelID = two.first { $0.id == b.id }!.persistentModelID
        msg.attachedImageFiles = [b]
        await store.addMessage(msg, toConversation: convId)
        let one = try imageRows()
        XCTAssertEqual(one.count, 1, "Removed image must be deleted, not left orphaned")
        XCTAssertEqual(one.first?.id, b.id)
        XCTAssertEqual(one.first!.persistentModelID, bModelID, "Surviving image 'b' must keep its row across a removal")

        let reloaded = await store.fetchMessages(for: convId, offset: 0, limit: 10)
        XCTAssertEqual(reloaded.first?.attachedImageFiles?.map(\.id), [b.id])
    }

    /// Control: the imageless agent message (finalize/flush re-upserts it many times) must
    /// never create image rows and must not throw — the reconcile's empty-set no-op path.
    func testUpsert_imagelessAgentMessage_neverCreatesImageRows() async throws {
        let convId = UUID()
        store.addConversation(from: makeConversation(id: convId))

        let msg = makeAgentMessage(conversationId: convId, text: "streaming…")
        await store.addMessage(msg, toConversation: convId)   // INSERT
        await store.addMessage(msg, toConversation: convId)   // UPDATE
        await store.addMessage(msg, toConversation: convId)   // UPDATE

        XCTAssertEqual(try imageRows().count, 0, "An imageless message must never create AttachedImageFileSD rows")
        let reloaded = await store.fetchMessages(for: convId, offset: 0, limit: 10)
        XCTAssertEqual(reloaded.count, 1, "Repeated upserts must not duplicate the row")
        XCTAssertNil(reloaded.first?.attachedImageFiles)
    }

}

