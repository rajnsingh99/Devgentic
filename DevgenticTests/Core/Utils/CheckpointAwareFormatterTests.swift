// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
//
//  CheckpointAwareFormatterTests.swift
//  DevgenticTests
//
//  Tests for checkpoint-aware history formatting in EpisodicHistoryFormatter,
//  NativeHistoryConverter, and ConversationHistoryTool.
//  Verifies that checkpoint messages are correctly detected, filtered,
//  and used to produce compacted context blocks.
//

import XCTest
@testable import devgentic

final class CheckpointAwareFormatterTests: XCTestCase {

    // MARK: - Test Helpers

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

    private func makeAgentMessage(_ text: String, timestamp: Date = Date(), toolEvents: [(name: String, params: String, output: String?, isSuccess: Bool)] = []) -> ChatMessage {
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
                params: event.params,
                output: event.output,
                isSuccess: event.isSuccess,
                isExecuting: false
            ))
        }
        return msg
    }

    private func makeCheckpointMessage(_ summary: String, timestamp: Date) -> ChatMessage {
        ChatMessage(
            id: UUID(),
            conversationId: testConversationID,
            timestamp: timestamp,
            sender: .agent,
            content: .checkpoint(summary: summary)
        )
    }

    /// Builds a history with a checkpoint in the middle.
    /// Returns (fullHistory, checkpointTimestamp) for test assertions.
    private func makeHistoryWithCheckpoint() -> (history: [ChatMessage], checkpointTimestamp: Date) {
        let t0 = Date(timeIntervalSince1970: 1000)
        var history: [ChatMessage] = []

        // Pre-checkpoint turns (should be excluded after filtering)
        history.append(makeUserMessage("Old query 1", timestamp: t0))
        history.append(makeAgentMessage("Old response 1", timestamp: t0.addingTimeInterval(1), toolEvents: [
            (name: "read_file", params: "{\"path\":\"/old\"}", output: "old content", isSuccess: true)
        ]))
        history.append(makeUserMessage("Old query 2", timestamp: t0.addingTimeInterval(2)))
        history.append(makeAgentMessage("Old response 2", timestamp: t0.addingTimeInterval(3), toolEvents: [
            (name: "delete_file", params: "{\"path\":\"/old\"}", output: "Permission denied", isSuccess: false)
        ]))

        // Checkpoint
        let checkpointTs = t0.addingTimeInterval(4)
        history.append(makeCheckpointMessage(
            "User read /old file, then tried to delete it but was denied.",
            timestamp: checkpointTs
        ))

        // Post-checkpoint turns (should be included)
        history.append(makeUserMessage("New query 1", timestamp: t0.addingTimeInterval(5)))
        history.append(makeAgentMessage("New response 1", timestamp: t0.addingTimeInterval(6), toolEvents: [
            (name: "list_directory", params: "{\"path\":\"/new\"}", output: "file1.txt", isSuccess: true)
        ]))
        history.append(makeUserMessage("New query 2", timestamp: t0.addingTimeInterval(7)))
        history.append(makeAgentMessage("New response 2", timestamp: t0.addingTimeInterval(8)))

        return (history, checkpointTs)
    }

    // MARK: - EpisodicHistoryFormatter: buildRecentHistoryString with Checkpoints

    func testRecentHistory_NoCheckpoint_NormalBehavior() {
        let history: [ChatMessage] = [
            makeUserMessage("Query 1", timestamp: Date(timeIntervalSince1970: 100)),
            makeAgentMessage("Response 1", timestamp: Date(timeIntervalSince1970: 101))
        ]

        let xml = EpisodicHistoryFormatter.buildRecentHistoryString(from: history)
        XCTAssertTrue(xml.contains("<episodic_memory>"))
        XCTAssertTrue(xml.contains("goal=\"Query 1\""))
        XCTAssertFalse(xml.contains("<compacted_context>"), "No checkpoint → no compacted context")
    }

    func testRecentHistory_WithCheckpoint_IncludesCompactedContext() {
        let (history, _) = makeHistoryWithCheckpoint()

        let xml = EpisodicHistoryFormatter.buildRecentHistoryString(from: history)
        XCTAssertTrue(xml.contains("<compacted_context"), "Should include compacted context block")
        XCTAssertTrue(xml.contains("User read /old file"), "Checkpoint summary should be in compacted context")
    }

    func testRecentHistory_WithCheckpoint_OnlyRecentTurns() {
        let (history, _) = makeHistoryWithCheckpoint()

        let xml = EpisodicHistoryFormatter.buildRecentHistoryString(from: history)

        // Post-checkpoint turns should be present
        XCTAssertTrue(xml.contains("goal=\"New query 1\""), "Post-checkpoint turn should be present")
        XCTAssertTrue(xml.contains("goal=\"New query 2\""), "Post-checkpoint turn should be present")

        // Pre-checkpoint turns should NOT be in the <recent> section as individual turns
        // (they're summarized in the compacted_context)
        XCTAssertFalse(xml.contains("goal=\"Old query 1\""), "Pre-checkpoint turn should be excluded from recent")
        XCTAssertFalse(xml.contains("goal=\"Old query 2\""), "Pre-checkpoint turn should be excluded from recent")
    }

    func testRecentHistory_WithCheckpoint_MultipleCheckpoints_UsesLatest() {
        let t0 = Date(timeIntervalSince1970: 1000)
        var history: [ChatMessage] = []

        // First checkpoint (old)
        history.append(makeUserMessage("Very old", timestamp: t0))
        history.append(makeAgentMessage("Very old response", timestamp: t0.addingTimeInterval(1)))
        history.append(makeCheckpointMessage("Checkpoint A: very old summary", timestamp: t0.addingTimeInterval(2)))

        // Second checkpoint (newer)
        history.append(makeUserMessage("Old", timestamp: t0.addingTimeInterval(3)))
        history.append(makeAgentMessage("Old response", timestamp: t0.addingTimeInterval(4)))
        history.append(makeCheckpointMessage("Checkpoint B: newer summary", timestamp: t0.addingTimeInterval(5)))

        // Recent
        history.append(makeUserMessage("Current", timestamp: t0.addingTimeInterval(6)))
        history.append(makeAgentMessage("Current response", timestamp: t0.addingTimeInterval(7)))

        let xml = EpisodicHistoryFormatter.buildRecentHistoryString(from: history)
        XCTAssertTrue(xml.contains("Checkpoint B: newer summary"), "Should use the latest checkpoint")
        XCTAssertFalse(xml.contains("Checkpoint A: very old summary"), "Older checkpoint should not appear")
        XCTAssertTrue(xml.contains("goal=\"Current\""), "Post-checkpoint turn should be present")
        XCTAssertFalse(xml.contains("goal=\"Old\""), "Turn between checkpoints should be excluded")
    }

    // MARK: - EpisodicHistoryFormatter: buildGraph with Checkpoints

    func testBuildGraph_FiltersCheckpointMessages() {
        let (history, _) = makeHistoryWithCheckpoint()
        let graph = EpisodicHistoryFormatter.buildGraph(from: history, sessionID: "test")

        // Checkpoint messages should not create episodes
        for episode in graph.episodes {
            XCTAssertFalse(episode.primaryGoal.contains("checkpoint"),
                          "Checkpoint messages should not appear as episodes")
        }
    }

    func testBuildGraph_UsesPostCheckpointHistory() {
        let (history, _) = makeHistoryWithCheckpoint()
        let graph = EpisodicHistoryFormatter.buildGraph(from: history, sessionID: "test")

        // Should only have 2 episodes (the 2 post-checkpoint turn pairs)
        XCTAssertEqual(graph.episodes.count, 2, "Should only build episodes from post-checkpoint turns")
        XCTAssertEqual(graph.episodes[0].primaryGoal, "New query 1")
        XCTAssertEqual(graph.episodes[1].primaryGoal, "New query 2")
    }

    func testBuildGraph_GhostProtocol_OnlyFromPostCheckpoint() {
        let (history, _) = makeHistoryWithCheckpoint()
        let graph = EpisodicHistoryFormatter.buildGraph(from: history, sessionID: "test")

        // delete_file failure was pre-checkpoint — should NOT be in negative constraints
        XCTAssertFalse(graph.negativeConstraints.contains("delete_file"),
                       "Pre-checkpoint failures should not be in Ghost Protocol constraints")
    }

    // MARK: - NativeHistoryConverter: Checkpoint Context

    func testNativeTurns_NoCheckpoint_NormalBehavior() {
        let history: [ChatMessage] = [
            makeUserMessage("Q1", timestamp: Date(timeIntervalSince1970: 100)),
            makeAgentMessage("A1", timestamp: Date(timeIntervalSince1970: 101))
        ]

        let turns = NativeHistoryConverter.buildNativeTurns(from: history, limit: 10, charBudget: 50_000).asWireDicts()
        XCTAssertEqual(turns.count, 2) // 1 user + 1 assistant
        XCTAssertEqual(turns[0]["role"], "user")
        XCTAssertEqual(turns[1]["role"], "assistant")
        XCTAssertFalse(turns[0]["content"]?.contains("Prior conversation summary") ?? false)
    }

    func testNativeTurns_WithCheckpoint_PrependsContextPair() {
        let (history, _) = makeHistoryWithCheckpoint()

        let turns = NativeHistoryConverter.buildNativeTurns(from: history, limit: 10, charBudget: 50_000).asWireDicts()

        // First two turns should be the checkpoint context pair
        XCTAssertTrue(turns.count >= 2, "Should have at least the context pair")
        XCTAssertEqual(turns[0]["role"], "user")
        XCTAssertTrue(turns[0]["content"]?.contains("Prior conversation summary") ?? false,
                      "First message should be the checkpoint summary")
        XCTAssertEqual(turns[1]["role"], "assistant")
        XCTAssertTrue(turns[1]["content"]?.contains("Understood") ?? false,
                      "Second message should be the acknowledgment")
    }

    func testPointerTurns_WithCheckpoint_PrependsContextPair() {
        let (history, _) = makeHistoryWithCheckpoint()

        let turns = NativeHistoryConverter.buildPointerTurns(from: history, toolsAvailable: true).asWireDicts()

        XCTAssertTrue(turns.count >= 2)
        XCTAssertTrue(turns[0]["content"]?.contains("Prior conversation summary") ?? false,
                      "Pointer turns should also prepend checkpoint context")
    }

    func testHybridTurns_WithCheckpoint_PrependsContextPair() {
        let (history, _) = makeHistoryWithCheckpoint()

        let turns = NativeHistoryConverter.buildHybridTurns(from: history, inlineCount: 3, charBudget: 50_000, toolsAvailable: true).asWireDicts()

        XCTAssertTrue(turns.count >= 2)
        XCTAssertTrue(turns[0]["content"]?.contains("Prior conversation summary") ?? false,
                      "Hybrid turns should also prepend checkpoint context")
    }

    // MARK: - ConversationHistoryTool: Checkpoint Filtering

    func testConversationHistoryTool_FiltersCheckpoints() {
        let (history, _) = makeHistoryWithCheckpoint()

        let tool = ConversationHistoryTool(chatHistory: history)

        // The tool should have 4 turn records (2 pre-checkpoint + 2 post-checkpoint)
        // Checkpoint message itself should NOT create a turn record
        XCTAssertEqual(tool.turnRecords.count, 4, "Checkpoint messages should be filtered out of turn records")

        // Verify no turn record contains checkpoint content
        for record in tool.turnRecords {
            XCTAssertFalse(record.userQuery.contains("checkpoint"), "Checkpoint should not appear as a user query")
            XCTAssertFalse(record.agentResponse.contains("User read /old file"), "Checkpoint summary should not appear as agent response")
        }
    }

    func testConversationHistoryTool_IndexStability() async throws {
        let (history, _) = makeHistoryWithCheckpoint()
        let tool = ConversationHistoryTool(chatHistory: history)

        // Index 0 should be the first real turn pair
        let result = try await tool.call(arguments: ConversationHistoryTool.Arguments.testInit(index: 0))
        XCTAssertTrue(result.contains("Old query 1"), "Index 0 should be the first real turn")
    }
}

// MARK: - Test Helpers for Arguments

extension ConversationHistoryTool.Arguments {
    /// Test-only initializer to bypass Decodable requirement.
    static func testInit(index: Int) -> ConversationHistoryTool.Arguments {
        let json = "{\"index\": \(index)}"
        return try! JSONDecoder().decode(ConversationHistoryTool.Arguments.self, from: json.data(using: .utf8)!)
    }
}
