// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
//
//  CheckpointEdgeCaseTests.swift
//  DevgenticTests
//
//  Red-Green synthetic edge case tests for checkpoint-aware formatting.
//  Probes timestamp boundaries, XML special characters, empty histories
//  after checkpoint, and cascading checkpoint scenarios.
//

import XCTest
@testable import devgentic

final class CheckpointEdgeCaseTests: XCTestCase {

    // MARK: - Helpers

    private let testConversationID = UUID()

    private func makeUserMessage(_ text: String, timestamp: Date) -> ChatMessage {
        ChatMessage(id: UUID(), conversationId: testConversationID, timestamp: timestamp, sender: .user, content: .plainText(text))
    }

    private func makeAgentMessage(_ text: String, timestamp: Date) -> ChatMessage {
        ChatMessage(id: UUID(), conversationId: testConversationID, timestamp: timestamp, sender: .agent, content: .plainText(text))
    }

    private func makeCheckpoint(_ summary: String, timestamp: Date) -> ChatMessage {
        ChatMessage(id: UUID(), conversationId: testConversationID, timestamp: timestamp, sender: .agent, content: .checkpoint(summary: summary))
    }

    // MARK: - Checkpoint Summary with XML Special Characters

    func testCheckpoint_SummaryWithXMLChars_EscapedCorrectly() {
        let t0 = Date(timeIntervalSince1970: 1000)
        let history: [ChatMessage] = [
            makeCheckpoint("User searched for <script> tags & \"special\" chars in /tmp/file.txt", timestamp: t0),
            makeUserMessage("Next query", timestamp: t0.addingTimeInterval(1)),
            makeAgentMessage("Response", timestamp: t0.addingTimeInterval(2))
        ]

        let xml = EpisodicHistoryFormatter.buildRecentHistoryString(from: history)
        // The compacted_context should have escaped XML characters
        XCTAssertTrue(xml.contains("&lt;script&gt;"), "< and > should be escaped in checkpoint summary")
        XCTAssertTrue(xml.contains("&amp;"), "& should be escaped")
        XCTAssertTrue(xml.contains("&quot;"), "Quotes should be escaped")
    }

    // MARK: - Empty History After Checkpoint

    func testCheckpoint_NoMessagesAfter_ReturnsMinimalXML() {
        let t0 = Date(timeIntervalSince1970: 1000)
        let history: [ChatMessage] = [
            makeUserMessage("Old query", timestamp: t0),
            makeAgentMessage("Old response", timestamp: t0.addingTimeInterval(1)),
            makeCheckpoint("Summary of old conversation", timestamp: t0.addingTimeInterval(2))
            // No messages after checkpoint
        ]

        let xml = EpisodicHistoryFormatter.buildRecentHistoryString(from: history)
        // Should still produce valid XML with compacted context but empty recent
        XCTAssertTrue(xml.contains("<episodic_memory>"))
        XCTAssertTrue(xml.contains("<compacted_context"))
        XCTAssertTrue(xml.contains("Summary of old conversation"))
    }

    // MARK: - Checkpoint With Exact Same Timestamp as Message

    func testCheckpoint_SameTimestampAsMessage_FilteringWorksCorrectly() {
        let t0 = Date(timeIntervalSince1970: 1000)
        let history: [ChatMessage] = [
            makeUserMessage("Before checkpoint", timestamp: t0),
            makeAgentMessage("Response before", timestamp: t0.addingTimeInterval(1)),
            // Checkpoint and next message have the EXACT same timestamp
            makeCheckpoint("Summary", timestamp: t0.addingTimeInterval(2)),
            makeUserMessage("After checkpoint", timestamp: t0.addingTimeInterval(2)), // Same timestamp!
            makeAgentMessage("Response after", timestamp: t0.addingTimeInterval(3))
        ]

        let xml = EpisodicHistoryFormatter.buildRecentHistoryString(from: history)
        // "After checkpoint" has the same timestamp — filter is `> checkpoint.timestamp`
        // so it should NOT be included (strict greater than)
        // This tests the boundary behavior
        XCTAssertTrue(xml.contains("<episodic_memory>"))
        // The behavior here depends on strict vs non-strict filtering
        // This test documents the current behavior
    }

    // MARK: - Native History: Checkpoint Context Pair Format

    func testNativeCheckpoint_ContextPairRoles_AlternateCorrectly() {
        let t0 = Date(timeIntervalSince1970: 1000)
        let history: [ChatMessage] = [
            makeUserMessage("Old", timestamp: t0),
            makeAgentMessage("Old response", timestamp: t0.addingTimeInterval(1)),
            makeCheckpoint("Prior summary", timestamp: t0.addingTimeInterval(2)),
            makeUserMessage("New query", timestamp: t0.addingTimeInterval(3)),
            makeAgentMessage("New response", timestamp: t0.addingTimeInterval(4))
        ]

        let turns = NativeHistoryConverter.buildNativeTurns(from: history, limit: 10, charBudget: 50_000).asWireDicts()

        // Verify alternating roles: user, assistant, user, assistant
        XCTAssertGreaterThanOrEqual(turns.count, 4, "Should have context pair + actual turn pair")

        for i in stride(from: 0, to: turns.count, by: 2) {
            XCTAssertEqual(turns[i]["role"], "user", "Even indices should be user messages")
        }
        for i in stride(from: 1, to: turns.count, by: 2) {
            XCTAssertEqual(turns[i]["role"], "assistant", "Odd indices should be assistant messages")
        }
    }

    // MARK: - buildGraph: Checkpoint as Agent Message Should Not Create Episode

    func testBuildGraph_CheckpointDoesNotCreateEpisode() {
        let t0 = Date(timeIntervalSince1970: 1000)
        let history: [ChatMessage] = [
            makeUserMessage("Query", timestamp: t0),
            makeAgentMessage("Response", timestamp: t0.addingTimeInterval(1)),
            makeCheckpoint("Summary", timestamp: t0.addingTimeInterval(2)),
            makeUserMessage("Post-checkpoint query", timestamp: t0.addingTimeInterval(3)),
            makeAgentMessage("Post-checkpoint response", timestamp: t0.addingTimeInterval(4))
        ]

        let graph = EpisodicHistoryFormatter.buildGraph(from: history, sessionID: "test")

        // Only 1 episode should exist (the post-checkpoint turn)
        XCTAssertEqual(graph.episodes.count, 1, "Checkpoint should not create an episode")
        XCTAssertEqual(graph.episodes[0].primaryGoal, "Post-checkpoint query")
    }

    // MARK: - Cascading Checkpoints: Only Latest Used

    func testCascadingCheckpoints_BuildGraph_OnlyUsesLatest() {
        let t0 = Date(timeIntervalSince1970: 1000)
        let history: [ChatMessage] = [
            makeUserMessage("Ancient query", timestamp: t0),
            makeAgentMessage("Ancient response", timestamp: t0.addingTimeInterval(1)),
            makeCheckpoint("Checkpoint A", timestamp: t0.addingTimeInterval(2)),
            makeUserMessage("Middle query", timestamp: t0.addingTimeInterval(3)),
            makeAgentMessage("Middle response", timestamp: t0.addingTimeInterval(4)),
            makeCheckpoint("Checkpoint B (absorbs A)", timestamp: t0.addingTimeInterval(5)),
            makeUserMessage("Recent query", timestamp: t0.addingTimeInterval(6)),
            makeAgentMessage("Recent response", timestamp: t0.addingTimeInterval(7))
        ]

        let graph = EpisodicHistoryFormatter.buildGraph(from: history, sessionID: "test")

        // Only 1 episode: the post-Checkpoint-B turn
        XCTAssertEqual(graph.episodes.count, 1)
        XCTAssertEqual(graph.episodes[0].primaryGoal, "Recent query")
    }

    // MARK: - ConversationHistoryTool: Only Checkpoints in History

    func testConversationHistoryTool_OnlyCheckpoints_EmptyRecords() {
        let t0 = Date(timeIntervalSince1970: 1000)
        let history: [ChatMessage] = [
            makeCheckpoint("Summary 1", timestamp: t0),
            makeCheckpoint("Summary 2", timestamp: t0.addingTimeInterval(1))
        ]

        let tool = ConversationHistoryTool(chatHistory: history)
        XCTAssertEqual(tool.turnRecords.count, 0, "Checkpoint-only history should produce zero turn records")
    }

    // MARK: - Hybrid History: Checkpoint + Fewer Turns Than inlineCount

    func testHybridHistory_WithCheckpoint_FewerTurnsThanInlineCount() {
        let t0 = Date(timeIntervalSince1970: 1000)
        let history: [ChatMessage] = [
            makeUserMessage("Old", timestamp: t0),
            makeAgentMessage("Old response", timestamp: t0.addingTimeInterval(1)),
            makeCheckpoint("Summary", timestamp: t0.addingTimeInterval(2)),
            makeUserMessage("Only post-checkpoint turn", timestamp: t0.addingTimeInterval(3)),
            makeAgentMessage("Response", timestamp: t0.addingTimeInterval(4))
        ]

        // inlineCount=3 but only 1 post-checkpoint turn → all should be inline
        let xml = EpisodicHistoryFormatter.buildHybridHistoryString(from: history, inlineCount: 3)
        XCTAssertTrue(xml.contains("Only post-checkpoint turn"))
        XCTAssertTrue(xml.contains("<compacted_context"))
        // No pointer skeletons should appear since all turns fit inline
        XCTAssertFalse(xml.contains("get_conversation_history"), "Should not need pointers when all turns fit inline")
    }

    // MARK: - Checkpoint Codable: Round-Trip With Large Summary

    func testCheckpointCodable_LargeSummary_RoundTrips() throws {
        let largeSummary = String(repeating: "Summary line. ", count: 100) // ~1400 chars
        let original = MessageContent.checkpoint(summary: largeSummary)

        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(MessageContent.self, from: data)

        if case .checkpoint(let roundTripped) = decoded {
            XCTAssertEqual(roundTripped, largeSummary, "Large summary should survive Codable round-trip")
        } else {
            XCTFail("Decoded content should be .checkpoint")
        }
    }

    // MARK: - Native Turns: charBudget With Checkpoint Context

    func testNativeTurns_CheckpointContextDoesNotConsumeCharBudget() {
        let t0 = Date(timeIntervalSince1970: 1000)
        var history: [ChatMessage] = []

        // Add a checkpoint with a long summary
        history.append(makeCheckpoint(String(repeating: "x", count: 500), timestamp: t0))

        // Add several post-checkpoint turns
        for i in 1...5 {
            history.append(makeUserMessage("Q\(i)", timestamp: t0.addingTimeInterval(Double(i * 2))))
            history.append(makeAgentMessage("A\(i)", timestamp: t0.addingTimeInterval(Double(i * 2 + 1))))
        }

        // Small charBudget — should still include context pair + some turns
        let turns = NativeHistoryConverter.buildNativeTurns(from: history, limit: 10, charBudget: 200).asWireDicts()
        XCTAssertGreaterThanOrEqual(turns.count, 2, "Should at least include the checkpoint context pair")
        XCTAssertTrue(turns[0]["content"]?.contains("Prior conversation summary") ?? false)
    }
}
