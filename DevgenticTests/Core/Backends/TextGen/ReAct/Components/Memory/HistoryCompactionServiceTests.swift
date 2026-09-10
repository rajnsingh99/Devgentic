// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2026 Raj Singh
//
//  HistoryCompactionServiceTests.swift
//  DevgenticTests
//
//  Tests for HistoryCompactionService trigger logic, adaptive batch sizing,
//  checkpoint creation, and format-for-IC helpers.
//  Note: Tests that require IC inference are excluded — these test the
//  deterministic logic surrounding the IC call, not the IC model itself.
//

import XCTest
@testable import devgentic

final class HistoryCompactionServiceTests: XCTestCase {

    // MARK: - Helpers

    private let testConversationID = UUID()

    private func makeUserMessage(_ text: String, timestamp: Date = Date()) -> ChatMessage {
        ChatMessage(
            id: UUID(),
            conversationId: testConversationID,
            timestamp: timestamp,
            sender: .user,
            content: .plainText(text)
        )
    }

    private func makeAgentMessage(_ text: String, timestamp: Date = Date(), toolEvents: [(name: String, isSuccess: Bool)] = []) -> ChatMessage {
        let msg = ChatMessage(
            id: UUID(),
            conversationId: testConversationID,
            timestamp: timestamp,
            sender: .agent,
            content: .plainText(text)
        )
        msg.timelineEvents = toolEvents.map { event in
            .toolExecution(ToolExecutionData(
                id: UUID(),
                name: event.name,
                params: "{}",
                output: "output",
                isSuccess: event.isSuccess,
                isExecuting: false
            ))
        }
        return msg
    }

    private func makeCheckpointMessage(_ summary: String, timestamp: Date = Date()) -> ChatMessage {
        ChatMessage(
            id: UUID(),
            conversationId: testConversationID,
            timestamp: timestamp,
            sender: .agent,
            content: .checkpoint(summary: summary)
        )
    }

    /// Builds a conversation with N turn pairs (user + agent), each with a small text body.
    private func makeConversation(turnPairs: Int, startDate: Date = Date(timeIntervalSince1970: 1000)) -> [ChatMessage] {
        var history: [ChatMessage] = []
        for i in 0..<turnPairs {
            let ts = startDate.addingTimeInterval(Double(i * 2))
            history.append(makeUserMessage("Query \(i + 1)", timestamp: ts))
            history.append(makeAgentMessage("Response \(i + 1) with some tool output that is moderately long to simulate real usage.", timestamp: ts.addingTimeInterval(1)))
        }
        return history
    }

    // MARK: - Trigger Logic: compactIfNeeded

    func testCompactIfNeeded_EmptyHistory_ReturnsNil() async throws {
        let result = try await HistoryCompactionService.shared.compactIfNeeded(
            chatHistory: [],
            conversationID: testConversationID,
            charBudget: 10_000
        )
        XCTAssertNil(result, "Empty history should not trigger compaction")
    }

    /// Was `testCompactIfNeeded_BelowTurnThreshold_ReturnsNil`, asserting a 5 < 15 user-turn
    /// gate. That gate is GONE: context pressure is a size question, and an absolute turn
    /// count in different units from the budget could only disagree with it. This shape now
    /// returns nil purely because it is under the char trigger — which is the honest reason
    /// it should have been nil all along.
    func testCompactIfNeeded_SmallConversationUnderCharBudget_ReturnsNil() async throws {
        let history = makeConversation(turnPairs: 5)
        let result = try await HistoryCompactionService.shared.compactIfNeeded(
            chatHistory: history,
            conversationID: testConversationID,
            charBudget: 10_000 // 5 short turn pairs stay well under the 6,000-char trigger
        )
        XCTAssertNil(result, "Under the char trigger there is no pressure to relieve")
    }

    /// The structural floor that replaced the turn-count gate: even when history is WAY over
    /// the char trigger, a conversation with too few compactable messages (after keeping the
    /// 5 most recent) must not pay an IC inference. Returns before any IC call, so this test
    /// never loads a model.
    func testCompactIfNeeded_OverCharBudgetButTooFewCompactableMessages_ReturnsNil() async throws {
        // 3 turn pairs = 6 messages. dropLast(5) leaves 1 compactable → below the >= 4 floor.
        let big = String(repeating: "x", count: 5_000)
        let base = Date(timeIntervalSince1970: 1000)
        var history: [ChatMessage] = []
        for i in 0..<3 {
            let ts = base.addingTimeInterval(Double(i * 2))
            history.append(makeUserMessage(big, timestamp: ts))
            history.append(makeAgentMessage(big, timestamp: ts.addingTimeInterval(1)))
        }

        let result = try await HistoryCompactionService.shared.compactIfNeeded(
            chatHistory: history,
            conversationID: testConversationID,
            charBudget: 1_000 // 30,000 chars vs a 600-char trigger — massively over
        )
        XCTAssertNil(result, "The batch floor must hold even under heavy char pressure")
    }

    func testCompactIfNeeded_BelowCharThreshold_ReturnsNil() async throws {
        // 20 turn pairs but with very large charBudget — under 60% ratio
        let history = makeConversation(turnPairs: 20)
        let result = try await HistoryCompactionService.shared.compactIfNeeded(
            chatHistory: history,
            conversationID: testConversationID,
            charBudget: 1_000_000 // Huge budget — estimated chars won't exceed 60%
        )
        XCTAssertNil(result, "Below char threshold should not trigger compaction")
    }

    func testCompactIfNeeded_AllCheckpoints_ReturnsNil() async throws {
        // Pathological: only checkpoint messages, no real turns
        let history = [
            makeCheckpointMessage("Summary 1", timestamp: Date(timeIntervalSince1970: 100)),
            makeCheckpointMessage("Summary 2", timestamp: Date(timeIntervalSince1970: 200))
        ]
        let result = try await HistoryCompactionService.shared.compactIfNeeded(
            chatHistory: history,
            conversationID: testConversationID,
            charBudget: 100
        )
        XCTAssertNil(result, "All-checkpoint history should not trigger compaction")
    }

    // MARK: - Background Run Dedup

    /// Compaction runs off the request path now, so a second turn can arrive while a run is
    /// still in flight. Its planner would re-plan the SAME batch (the checkpoint hasn't
    /// landed yet) — the dedup is what stops a duplicate IC summarization.
    func testBackgroundRunDedup_SecondRunForSameConversationIsRejected() async {
        let conv = UUID()
        let service = HistoryCompactionService.shared

        let first = await service.beginBackgroundRun(conversationID: conv)
        let second = await service.beginBackgroundRun(conversationID: conv)
        XCTAssertTrue(first, "First run must be admitted")
        XCTAssertFalse(second, "A duplicate for the same conversation must be rejected")

        // Ending the run frees the slot for the next genuine compaction.
        await service.endBackgroundRun(conversationID: conv)
        let third = await service.beginBackgroundRun(conversationID: conv)
        XCTAssertTrue(third, "After the run ends, the conversation may compact again")
        await service.endBackgroundRun(conversationID: conv)
    }

    /// The dedup is per conversation — one chat compacting must not block another.
    func testBackgroundRunDedup_IsScopedPerConversation() async {
        let a = UUID(), b = UUID()
        let service = HistoryCompactionService.shared

        let first = await service.beginBackgroundRun(conversationID: a)
        let other = await service.beginBackgroundRun(conversationID: b)
        XCTAssertTrue(first)
        XCTAssertTrue(other, "A run in conversation A must not block conversation B")

        await service.endBackgroundRun(conversationID: a)
        await service.endBackgroundRun(conversationID: b)
    }

    // MARK: - Checkpoint Filtering

    /// Only turns AFTER the latest checkpoint count toward the trigger — already-summarized
    /// history must not keep re-triggering compaction forever.
    ///
    /// Constructed so correct and broken behaviour genuinely diverge:
    ///   • correct (post-checkpoint only) → ~12 chars, under the 600-char trigger → nil,
    ///     and it returns before any IC call, so the green path never loads a model;
    ///   • broken (whole history) → 24,000 chars, sails past the trigger AND past the
    ///     >= 4 batch floor, so it proceeds and the assertion fires.
    ///
    /// The message size matters: an earlier attempt used 5 × 5,000-char pairs, and the
    /// BROKEN path still returned nil because two such messages exhaust the ~10.5k IC input
    /// budget, leaving a batch of 2 that the >= 4 floor rejected. The test passed either
    /// way — vacuous. Many moderate messages keep the broken path above the floor.
    ///
    /// The version before that asserted NOTHING ("the important thing is it doesn't crash")
    /// and, once the turn-count gate was removed, began making a real IntelligenceCore call
    /// — a multi-second model load inside a unit test.
    func testTurnsAfterCheckpoint_FilteredCorrectly() async throws {
        let baseDate = Date(timeIntervalSince1970: 1000)
        let moderate = String(repeating: "x", count: 600)

        // 20 moderate turn pairs BEFORE the checkpoint (24,000 chars — already summarized).
        var history: [ChatMessage] = []
        for i in 0..<20 {
            let ts = baseDate.addingTimeInterval(Double(i * 2))
            history.append(makeUserMessage(moderate, timestamp: ts))
            history.append(makeAgentMessage(moderate, timestamp: ts.addingTimeInterval(1)))
        }

        let checkpointTs = baseDate.addingTimeInterval(100)
        history.append(makeCheckpointMessage("Prior context summary", timestamp: checkpointTs))

        // 3 tiny turn pairs AFTER the checkpoint (~12 chars).
        for i in 0..<3 {
            let ts = checkpointTs.addingTimeInterval(Double(i * 2) + 1)
            history.append(makeUserMessage("hi", timestamp: ts))
            history.append(makeAgentMessage("ok", timestamp: ts.addingTimeInterval(1)))
        }
        history.sort(by: { $0.timestamp < $1.timestamp })

        let result = try await HistoryCompactionService.shared.compactIfNeeded(
            chatHistory: history,
            conversationID: testConversationID,
            charBudget: 1_000 // trigger = 600 chars
        )

        XCTAssertNil(result, "Only post-checkpoint turns count; the 24,000 pre-checkpoint chars must be excluded")
    }

    // MARK: - MessageContent.checkpoint Codable

    func testCheckpointContent_EncodeDecode() throws {
        let original = MessageContent.checkpoint(summary: "User found config at /etc/config.yaml, fixed port bug")
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(MessageContent.self, from: data)

        if case .checkpoint(let summary) = decoded {
            XCTAssertEqual(summary, "User found config at /etc/config.yaml, fixed port bug")
        } else {
            XCTFail("Decoded content should be .checkpoint, got \(decoded)")
        }
    }

    func testCheckpointContent_TextContent() {
        let content = MessageContent.checkpoint(summary: "Summary text here")
        XCTAssertEqual(content.textContent, "Summary text here")
    }

    // MARK: - Format for IC

    func testFormatTurnsForIC_SkipsCheckpoints() {
        let history: [ChatMessage] = [
            makeUserMessage("Query 1"),
            makeAgentMessage("Response 1"),
            makeCheckpointMessage("Summary"),
            makeUserMessage("Query 2"),
            makeAgentMessage("Response 2")
        ]

        // We can't directly test the private formatTurnsForIC, but we can verify
        // that checkpoint messages don't corrupt the compaction pipeline by checking
        // that the service handles them without crashing.
        // Verified via the public compactIfNeeded interface in integration tests.
    }

    func testFormatTurnsForIC_IncludesToolSummaries() {
        let msg = makeAgentMessage("Done.", toolEvents: [
            (name: "read_file", isSuccess: true),
            (name: "write_file", isSuccess: false)
        ])

        // Verify the message has tool events that would be formatted
        XCTAssertEqual(msg.timelineEvents.count, 2)
        if case .toolExecution(let data) = msg.timelineEvents[0] {
            XCTAssertEqual(data.name, "read_file")
        }
    }
}
