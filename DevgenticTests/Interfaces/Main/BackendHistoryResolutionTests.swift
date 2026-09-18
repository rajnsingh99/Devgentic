// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
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

        let merged = BackendHistoryResolver.merge(stored: stored, inMemory: [justSent])

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

        let merged = BackendHistoryResolver.merge(stored: stored, inMemory: inMemory)

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

        let merged = BackendHistoryResolver.merge(stored: [shared], inMemory: [live])

        XCTAssertEqual(merged.count, 1, "Same id must not appear twice")
        XCTAssertEqual(merged.first?.content.textContent, "live version",
                       "In-memory is fresher and must win")
    }

    /// The backend contract is oldest-first; the UI array is newest-first, so the merge
    /// must impose order rather than inherit either input's.
    func testMerge_IsSortedOldestFirst() {
        let stored = [message(3, "c"), message(1, "a")]
        let inMemory = [message(4, "d"), message(2, "b")]

        let merged = BackendHistoryResolver.merge(stored: stored, inMemory: inMemory)

        XCTAssertEqual(merged.map { $0.content.textContent }, ["a", "b", "c", "d"])
    }

    func testMerge_EmptyInputs() {
        XCTAssertTrue(BackendHistoryResolver.merge(stored: [], inMemory: []).isEmpty)

        let only = message(0, "only")
        XCTAssertEqual(BackendHistoryResolver.merge(stored: [], inMemory: [only]).count, 1,
                       "A brand-new conversation has nothing stored yet")
        XCTAssertEqual(BackendHistoryResolver.merge(stored: [only], inMemory: []).count, 1)
    }

    // MARK: - Slice before a target (regeneration / resume replay)

    /// A retry must not replay less context than the original send. This previously sliced
    /// `currentChatMessages` by index, so regenerating the newest message of a freshly
    /// opened long conversation replayed only the ~19 loaded messages.
    func testSlice_TakesEverythingStrictlyBeforeTheTarget() {
        let history = (0..<10).map { message(TimeInterval($0), "m\($0)") }
        let target = history[7]

        let slice = MessagingCoordinator.historySlice(before: target, in: history)

        XCTAssertEqual(slice.count, 7)
        XCTAssertEqual(slice.map { $0.content.textContent }, (0..<7).map { "m\($0)" })
        XCTAssertFalse(slice.contains { $0.id == target.id }, "The target itself is excluded")
    }

    /// Identity, not timestamp — a message and its reply can be persisted in the same
    /// instant, and a timestamp cut would then keep or drop both.
    func testSlice_CutsByIdentityWhenTimestampsTie() {
        let shared = base.addingTimeInterval(5)
        let userTurn = ChatMessage(conversationId: convID, timestamp: shared, sender: .user, content: .plainText("q"))
        let agentTurn = ChatMessage(conversationId: convID, timestamp: shared, sender: .agent, content: .plainText("a"))
        let history = [message(0, "older"), userTurn, agentTurn]

        let slice = MessagingCoordinator.historySlice(before: agentTurn, in: history)

        XCTAssertEqual(slice.count, 2, "The tied user turn must be KEPT — it precedes the target")
        XCTAssertEqual(slice.last?.content.textContent, "q")
    }

    /// Target beyond the resolved window (older than the 300-message cap): fall back to a
    /// timestamp cut rather than replaying the whole conversation past it.
    func testSlice_FallsBackToTimestampWhenTargetIsAbsent() {
        let history = (0..<5).map { message(TimeInterval($0), "m\($0)") }
        let absent = message(2.5, "not in the window")

        let slice = MessagingCoordinator.historySlice(before: absent, in: history)

        XCTAssertEqual(slice.map { $0.content.textContent }, ["m0", "m1", "m2"])
    }

    func testSlice_TargetIsOldestYieldsEmpty() {
        let history = (0..<5).map { message(TimeInterval($0), "m\($0)") }
        XCTAssertTrue(MessagingCoordinator.historySlice(before: history[0], in: history).isEmpty)
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

        let merged = BackendHistoryResolver.merge(
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
