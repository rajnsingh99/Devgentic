//
//  BackendHistoryResolutionTests.swift
//  DevgenticTests
//
//  Pins the merge that decoupled the model's history from the UI's pagination window.
//
//  Before this, the backend received `currentChatMessages` — the scroll window (20 on open,
//  +10 per scroll up) — so the model's memory depended on how far the user had scrolled and
//  a reopened long conversation got 20 messages regardless of its context window.
//  The store is now the base, but in-memory messages must be merged OVER it, never replaced
//  by it: the user's message is persisted in a DETACHED task that races the read.
//

import XCTest
@testable import devgentic

@MainActor
final class BackendHistoryResolutionTests: XCTestCase {

    private let convID = UUID()
    private let base = Date()

    private func message(_ offset: TimeInterval, _ text: String, sender: SenderRole = .user) -> ChatMessage {
        ChatMessage(
            conversationId: convID,
            timestamp: base.addingTimeInterval(offset),
            sender: sender,
            content: .plainText(text)
        )
    }

    /// THE load-bearing case. The just-sent user message is persisted in a detached task, so
    /// it may not be in the store when history is resolved. If the merge were
    /// store-authoritative, the request answering that question would omit the question.
    func testMerge_KeepsInMemoryMessageMissingFromStore() {
        let stored = [message(0, "older turn")]
        let justSent = message(10, "the question I just asked")

        let merged = MessagingCoordinator.mergeHistory(stored: stored, inMemory: [justSent])

        XCTAssertEqual(merged.count, 2)
        XCTAssertEqual(merged.last?.content.textContent, "the question I just asked",
                       "A not-yet-persisted message must survive the merge")
    }

    /// The store is the base for everything the UI window doesn't hold — this is the actual
    /// fix for a reopened long conversation.
    func testMerge_IncludesStoredHistoryBeyondTheLoadedWindow() {
        let stored = (0..<50).map { message(TimeInterval($0), "stored \($0)") }
        // The UI window only holds the newest few.
        let inMemory = Array(stored.suffix(3))

        let merged = MessagingCoordinator.mergeHistory(stored: stored, inMemory: inMemory)

        XCTAssertEqual(merged.count, 50, "History must not be capped to the UI's window")
    }

    func testMerge_DeduplicatesByID_InMemoryWins() {
        let shared = message(5, "stored version")
        // Same id, fresher content — mirrors a message mutated in memory mid-stream.
        let live = ChatMessage(
            id: shared.id,
            conversationId: convID,
            timestamp: shared.timestamp,
            sender: .agent,
            content: .plainText("live version")
        )

        let merged = MessagingCoordinator.mergeHistory(stored: [shared], inMemory: [live])

        XCTAssertEqual(merged.count, 1, "Same id must not appear twice")
        XCTAssertEqual(merged.first?.content.textContent, "live version",
                       "In-memory is fresher and must win")
    }

    /// The backend contract is oldest-first; the UI array is newest-first, so the merge
    /// must impose order rather than inherit either input's.
    func testMerge_IsSortedOldestFirst() {
        let stored = [message(3, "c"), message(1, "a")]
        let inMemory = [message(4, "d"), message(2, "b")]

        let merged = MessagingCoordinator.mergeHistory(stored: stored, inMemory: inMemory)

        XCTAssertEqual(merged.map { $0.content.textContent }, ["a", "b", "c", "d"])
    }

    func testMerge_EmptyInputs() {
        XCTAssertTrue(MessagingCoordinator.mergeHistory(stored: [], inMemory: []).isEmpty)

        let only = message(0, "only")
        XCTAssertEqual(MessagingCoordinator.mergeHistory(stored: [], inMemory: [only]).count, 1,
                       "A brand-new conversation has nothing stored yet")
        XCTAssertEqual(MessagingCoordinator.mergeHistory(stored: [only], inMemory: []).count, 1)
    }

    /// A compaction checkpoint is a real message in the store; it must survive the merge so
    /// HistoryCompactionService can find it and skip re-summarizing the same turns.
    func testMerge_PreservesCheckpointMessages() {
        let checkpoint = ChatMessage(
            conversationId: convID,
            timestamp: base.addingTimeInterval(1),
            sender: .agent,
            content: .checkpoint(summary: "Summary of turns 0-14")
        )

        let merged = MessagingCoordinator.mergeHistory(
            stored: [message(0, "turn"), checkpoint],
            inMemory: [message(2, "newer")]
        )

        let found = merged.contains {
            if case .checkpoint = $0.content { return true }
            return false
        }
        XCTAssertTrue(found, "Checkpoints must reach the backend or compaction re-runs forever")
    }
}
