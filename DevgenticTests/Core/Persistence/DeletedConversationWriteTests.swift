// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
//
//  DeletedConversationWriteTests.swift
//  DevgenticTests
//
//  Created by Raj Singh.
//

import XCTest
import SwiftData
@testable import devgentic

@MainActor
final class DeletedConversationWriteTests: XCTestCase {

    private var container: ModelContainer!
    private var store: ChatPersistenceStore!

    override func setUp() async throws {
        container = try ModelContainer(for: ConversationSD.self, ChatMessageSD.self,
                                       AttachedTextFileSD.self, AttachedImageFileSD.self,
                                       configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        store = ChatPersistenceStore.shared
        store.configureContainer(container)
    }

    override func tearDown() async throws {
        container = nil
        store = nil
    }

    private func allMessageRows() throws -> [ChatMessageSD] {
        try container.mainContext.fetch(FetchDescriptor<ChatMessageSD>())
    }

    private func message(_ sender: SenderRole, _ text: String, in conversationID: UUID) -> ChatMessage {
        ChatMessage(id: UUID(), conversationId: conversationID, timestamp: Date(), sender: sender, content: .plainText(text))
    }

    /// ⚠️⚠️ THE CR-61 SEQUENCE: the conversation is deleted, then the cancelled run finalizes.
    func testATurnFinalizedAfterItsConversationWasDeletedIsNotWritten() async throws {
        let id = UUID()
        store.addConversation(from: Conversation(id: id, messages: [], timestamp: Date(), backendEntityId: nil))
        await store.addMessage(message(.user, "question", in: id), toConversation: id)
        store.deleteConversation(with: id)
        XCTAssertTrue(try allMessageRows().isEmpty, "precondition: the delete cascaded the user turn")

        await store.addMessage(message(.agent, "the answer the user deleted", in: id), toConversation: id)

        let rows = try allMessageRows()
        XCTAssertTrue(rows.isEmpty, "an orphan row was written for a deleted conversation: \(rows.map { $0.id })")
    }

    /// The control: the ordinary write into an existing conversation is untouched, and linked.
    func testAnOrdinaryTurnIsStillWrittenAndLinked() async throws {
        let id = UUID()
        store.addConversation(from: Conversation(id: id, messages: [], timestamp: Date(), backendEntityId: nil))
        await store.addMessage(message(.agent, "hello", in: id), toConversation: id)

        let rows = try allMessageRows()
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows.first?.conversation?.id, id, "the row must belong to its conversation")
    }

    /// ⚠️ The vector-store half. The delayed indexing must confirm the conversation still exists —
    /// asserted on the source, because the detached indexing task has no reachable seam.
    func testTheDelayedIndexingChecksTheConversationStillExists() throws {
        var dir = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        var source: String?
        for _ in 0..<10 {
            let candidate = dir.appendingPathComponent("Devgentic/Core/Utils/ActiveStreamManager.swift")
            if let text = try? String(contentsOf: candidate, encoding: .utf8) { source = text; break }
            dir = dir.deletingLastPathComponent()
        }
        let text = try XCTUnwrap(source, "ActiveStreamManager.swift not found")
        let check = try XCTUnwrap(text.range(of: "persistence.getConversation(withId: conversationID) != nil"))
        let guardLine = try XCTUnwrap(text.range(of: "guard stillExists else {", range: check.upperBound..<text.endIndex))
        let index = try XCTUnwrap(text.range(of: "await RAGIndexingService.shared.indexSingleMessage(indexable)",
                                             range: guardLine.upperBound..<text.endIndex))
        XCTAssertLessThan(text.distance(from: check.lowerBound, to: index.lowerBound), 900,
                          "the existence check must guard THIS indexing call")
    }
}
