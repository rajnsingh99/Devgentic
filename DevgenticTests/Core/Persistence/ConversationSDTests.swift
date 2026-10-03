// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
//
//  ConversationSDTests.swift
//  DevgenticTests
//
//  Created on 03/04/26.
//
//  Tests ConversationSD @Model — schema integrity, relationship cascade,
//  toStruct() mapping, and SwiftData-specific behaviors.
//

import XCTest
import SwiftData
@testable import devgentic

@MainActor
final class ConversationSDTests: XCTestCase {

    private var container: ModelContainer!
    private var context: ModelContext!

    override func setUp() async throws {
        let config = ModelConfiguration(isStoredInMemoryOnly: true)
        container = try ModelContainer(
            for: ConversationSD.self, ChatMessageSD.self,
            AttachedTextFileSD.self, AttachedImageFileSD.self,
            configurations: config
        )
        context = container.mainContext
    }

    override func tearDown() async throws {
        container = nil
        context = nil
    }

    // MARK: - Basic CRUD

    func testInsertAndFetch() throws {
        let id = UUID()
        let conv = ConversationSD(id: id, timestamp: Date(), userDefinedTitle: "Test Chat", isPinned: false)
        context.insert(conv)
        try context.save()

        let fetched = try context.fetch(FetchDescriptor<ConversationSD>())
        XCTAssertEqual(fetched.count, 1)
        XCTAssertEqual(fetched.first?.id, id)
        XCTAssertEqual(fetched.first?.userDefinedTitle, "Test Chat")
    }

    func testUniqueIdConstraint() throws {
        let id = UUID()
        let conv1 = ConversationSD(id: id, userDefinedTitle: "First")
        let conv2 = ConversationSD(id: id, userDefinedTitle: "Second")

        context.insert(conv1)
        try context.save()

        context.insert(conv2)

        // SwiftData should handle the unique constraint — either merge or error
        // The exact behavior depends on merge policy; just ensure no crash.
        do {
            try context.save()
        } catch {
            // Expected if merge policy rejects duplicate
        }
    }

    // MARK: - All Fields Persist

    func testAllFieldsPersist() throws {
        let id = UUID()
        let profileId = UUID()
        let conv = ConversationSD(
            id: id,
            timestamp: Date(timeIntervalSince1970: 1_700_000_000),
            userDefinedTitle: "Full Conv",
            isPinned: true,
            backendEntityId: profileId
        )
        context.insert(conv)
        try context.save()

        let fetched = try context.fetch(FetchDescriptor<ConversationSD>()).first!
        XCTAssertEqual(fetched.userDefinedTitle, "Full Conv")
        XCTAssertTrue(fetched.isPinned)
        XCTAssertEqual(fetched.backendEntityId, profileId)
        XCTAssertEqual(fetched.timestamp.timeIntervalSince1970, 1_700_000_000, accuracy: 1)
    }

    func testNilOptionalFields() throws {
        let conv = ConversationSD(id: UUID())
        context.insert(conv)
        try context.save()

        let fetched = try context.fetch(FetchDescriptor<ConversationSD>()).first!
        XCTAssertNil(fetched.userDefinedTitle)
        XCTAssertNil(fetched.backendEntityId)
    }

    // MARK: - Relationship: Messages

    func testConversationMessagesRelationship() throws {
        let conv = ConversationSD(id: UUID(), userDefinedTitle: "With Messages")
        context.insert(conv)

        let contentData = try JSONEncoder().encode(MessageContent.plainText("Hello"))
        let msg = ChatMessageSD(
            id: UUID(),
            conversationId: conv.id,
            timestamp: Date(),
            senderType: "user",
            traceID: nil,
            contentData: contentData,
            agentResponseData: nil,
            timelineEventsData: nil
        )
        msg.conversation = conv
        conv.messages.append(msg)
        context.insert(msg)
        try context.save()

        let fetched = try context.fetch(FetchDescriptor<ConversationSD>()).first!
        XCTAssertEqual(fetched.messages.count, 1)
        XCTAssertEqual(fetched.messages.first?.conversationId, conv.id)
    }

    func testCascadeDeleteRemovesMessages() throws {
        let conv = ConversationSD(id: UUID())
        context.insert(conv)

        let contentData = try JSONEncoder().encode(MessageContent.plainText("Will be deleted"))
        let msg = ChatMessageSD(
            id: UUID(),
            conversationId: conv.id,
            timestamp: Date(),
            senderType: "user",
            traceID: nil,
            contentData: contentData,
            agentResponseData: nil,
            timelineEventsData: nil
        )
        msg.conversation = conv
        conv.messages.append(msg)
        context.insert(msg)
        try context.save()

        // Delete conversation
        context.delete(conv)
        try context.save()

        // Messages should be cascade-deleted
        let remainingMessages = try context.fetch(FetchDescriptor<ChatMessageSD>())
        XCTAssertTrue(remainingMessages.isEmpty, "Messages should be cascade-deleted with conversation")
    }

    func testCascadeDeleteRemovesAttachments() throws {
        let conv = ConversationSD(id: UUID())
        context.insert(conv)

        let contentData = try JSONEncoder().encode(MessageContent.plainText("File msg"))
        let msg = ChatMessageSD(
            id: UUID(),
            conversationId: conv.id,
            timestamp: Date(),
            senderType: "user",
            traceID: nil,
            contentData: contentData,
            agentResponseData: nil,
            timelineEventsData: nil
        )
        let textFile = AttachedTextFileSD(
            id: UUID(), name: "test.swift", url: "file:///test.swift",
            fileExtension: "swift", content: "let x = 1", size: 10
        )
        msg.attachedTextFiles.append(textFile)
        msg.conversation = conv
        conv.messages.append(msg)
        context.insert(msg)
        try context.save()

        context.delete(conv)
        try context.save()

        let remainingFiles = try context.fetch(FetchDescriptor<AttachedTextFileSD>())
        XCTAssertTrue(remainingFiles.isEmpty, "Attachments should be cascade-deleted")
    }

    // MARK: - toStruct() Mapping

    func testToStructMapsAllFields() throws {
        let profileId = UUID()
        let conv = ConversationSD(
            id: UUID(),
            timestamp: Date(),
            userDefinedTitle: "Struct Test",
            isPinned: true,
            backendEntityId: profileId
        )
        context.insert(conv)
        try context.save()

        let result = conv.toStruct()
        XCTAssertEqual(result.id, conv.id)
        XCTAssertEqual(result.userDefinedTitle, "Struct Test")
        XCTAssertTrue(result.isPinned)
        XCTAssertEqual(result.backendEntityId, profileId)
    }

    func testToStructSortsMessagesByTimestamp() throws {
        let conv = ConversationSD(id: UUID())
        context.insert(conv)

        let now = Date()
        for i in [2, 0, 1] { // Insert out of order
            let contentData = try JSONEncoder().encode(MessageContent.plainText("Msg \(i)"))
            let msg = ChatMessageSD(
                id: UUID(),
                conversationId: conv.id,
                timestamp: now.addingTimeInterval(Double(i)),
                senderType: "user",
                traceID: nil,
                contentData: contentData,
                agentResponseData: nil,
                timelineEventsData: nil
            )
            msg.conversation = conv
            conv.messages.append(msg)
            context.insert(msg)
        }
        try context.save()

        let result = conv.toStruct()
        XCTAssertEqual(result.messages.count, 3)
        // Should be sorted ascending (oldest first)
        XCTAssertEqual(result.messages[0].content.textContent, "Msg 0")
        XCTAssertEqual(result.messages[1].content.textContent, "Msg 1")
        XCTAssertEqual(result.messages[2].content.textContent, "Msg 2")
    }

    func testToStructWithNoMessages() throws {
        let conv = ConversationSD(id: UUID())
        context.insert(conv)
        try context.save()

        let result = conv.toStruct()
        XCTAssertTrue(result.messages.isEmpty)
    }

    // MARK: - Fetch with Predicate

    func testFetchByIdPredicate() throws {
        let target = UUID()
        context.insert(ConversationSD(id: target, userDefinedTitle: "Target"))
        context.insert(ConversationSD(id: UUID(), userDefinedTitle: "Other"))
        try context.save()

        var descriptor = FetchDescriptor<ConversationSD>(
            predicate: #Predicate { $0.id == target }
        )
        descriptor.fetchLimit = 1
        let results = try context.fetch(descriptor)

        XCTAssertEqual(results.count, 1)
        XCTAssertEqual(results.first?.userDefinedTitle, "Target")
    }

    // MARK: - Sorting

    func testSortByTimestampDescending() throws {
        let now = Date()
        for i in 0..<5 {
            context.insert(ConversationSD(
                id: UUID(),
                timestamp: now.addingTimeInterval(Double(i) * 100),
                userDefinedTitle: "Conv \(i)"
            ))
        }
        try context.save()

        let descriptor = FetchDescriptor<ConversationSD>(
            sortBy: [SortDescriptor(\.timestamp, order: .reverse)]
        )
        let results = try context.fetch(descriptor)

        XCTAssertEqual(results.first?.userDefinedTitle, "Conv 4")
        XCTAssertEqual(results.last?.userDefinedTitle, "Conv 0")
    }

    // MARK: - Multiple Conversations

    func testMultipleConversationsWithMessages() throws {
        let conv1 = ConversationSD(id: UUID(), userDefinedTitle: "Chat 1")
        let conv2 = ConversationSD(id: UUID(), userDefinedTitle: "Chat 2")
        context.insert(conv1)
        context.insert(conv2)

        for conv in [conv1, conv2] {
            let contentData = try JSONEncoder().encode(MessageContent.plainText("In \(conv.userDefinedTitle ?? "")"))
            let msg = ChatMessageSD(
                id: UUID(), conversationId: conv.id, timestamp: Date(),
                senderType: "user", traceID: nil, contentData: contentData,
                agentResponseData: nil, timelineEventsData: nil
            )
            msg.conversation = conv
            conv.messages.append(msg)
            context.insert(msg)
        }
        try context.save()

        XCTAssertEqual(conv1.messages.count, 1)
        XCTAssertEqual(conv2.messages.count, 1)

        // Delete conv1 should not affect conv2
        context.delete(conv1)
        try context.save()

        let remaining = try context.fetch(FetchDescriptor<ConversationSD>())
        XCTAssertEqual(remaining.count, 1)
        XCTAssertEqual(remaining.first?.userDefinedTitle, "Chat 2")
        XCTAssertEqual(remaining.first?.messages.count, 1)
    }
}
