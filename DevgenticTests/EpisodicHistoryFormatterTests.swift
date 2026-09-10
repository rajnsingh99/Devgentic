// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2026 Raj Singh
//
//  EpisodicHistoryFormatterTests.swift
//  DevgenticTests
//
//  Tests for XML-based episodic memory generation.
//

import XCTest
@testable import devgentic

final class EpisodicHistoryFormatterTests: XCTestCase {

    // MARK: - Test Helpers

    private let testConversationID = UUID()

    private func makeUserMessage(_ text: String) -> ChatMessage {
        ChatMessage(
            conversationId: testConversationID,
            sender: .user,
            content: .plainText(text)
        )
    }

    /// `failureCategory` is REQUIRED on every fixture rather than optional-by-omission.
    /// `classify()` branches on it, and a failed row WITHOUT one falls to the legacy fallback
    /// — generic `.failed`, no user-correction, no Ghost Protocol ban — that exists only for
    /// rows persisted before the field. Four tests in this file had been red since that
    /// refactor because they still supplied the OLD signal: the denial phrasing in `output`,
    /// which the classifier deliberately no longer reads.
    private func makeAgentMessage(
        _ text: String,
        toolEvents: [(name: String, params: String, output: String?, isSuccess: Bool, failureCategory: ToolFailureCategory?)] = []
    ) -> ChatMessage {
        let msg = ChatMessage(
            conversationId: testConversationID,
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
                failureCategory: event.failureCategory,
                isExecuting: false
            ))
        }
        return msg
    }

    // MARK: - buildRecentHistoryString Tests

    func testEmptyHistory() {
        let result = EpisodicHistoryFormatter.buildRecentHistoryString(from: [])
        XCTAssertEqual(result, "<episodic_memory>\n  <recent/>\n</episodic_memory>",
                       "the emitted blob is indented and always has been — this assertion never matched it")
    }

    func testSingleSuccessfulTurn() {
        let history: [ChatMessage] = [
            makeUserMessage("List files in /tmp"),
            makeAgentMessage("Found 3 files.", toolEvents: [
                (name: "list_directory", params: "{\"path\":\"/tmp\"}", output: "file1.txt\nfile2.txt\nfile3.txt", isSuccess: true, failureCategory: nil)
            ])
        ]

        let xml = EpisodicHistoryFormatter.buildRecentHistoryString(from: history)

        XCTAssertTrue(xml.contains("<episodic_memory>"))
        XCTAssertTrue(xml.contains("</episodic_memory>"))
        XCTAssertTrue(xml.contains("status=\"completed\""))
        XCTAssertTrue(xml.contains("goal=\"List files in /tmp\""))
        XCTAssertTrue(xml.contains("recency=\"1 turn ago\""))
        XCTAssertTrue(xml.contains("tool=\"list_directory\""))
        XCTAssertTrue(xml.contains("status=\"success\""))
        XCTAssertTrue(xml.contains("path=\"/tmp\""))
    }

    func testFailedDeniedTurn() {
        let history: [ChatMessage] = [
            makeUserMessage("Delete cache folder"),
            makeAgentMessage("Permission denied.", toolEvents: [
                (name: "delete_file", params: "{\"path\":\"/tmp/cache\"}", output: "User explicitly denied permission for destructive operation", isSuccess: false, failureCategory: .userDenied)
            ])
        ]

        let xml = EpisodicHistoryFormatter.buildRecentHistoryString(from: history)

        XCTAssertTrue(xml.contains("status=\"failed\""), "Turn should be failed")
        XCTAssertTrue(xml.contains("status=\"denied\""), "Action should be denied")
        XCTAssertTrue(xml.contains("<error>"), "Should contain error element")
        XCTAssertTrue(xml.contains("denied permission"), "Error should contain denial reason")
        XCTAssertTrue(xml.contains("<user_correction>User denied: delete_file</user_correction>"))
    }

    func testRecencyAttributes() {
        var history: [ChatMessage] = []
        for i in 1...4 {
            history.append(makeUserMessage("Query \(i)"))
            history.append(makeAgentMessage("Response \(i)"))
        }

        let xml = EpisodicHistoryFormatter.buildRecentHistoryString(from: history)

        XCTAssertTrue(xml.contains("recency=\"4 turns ago\""))
        XCTAssertTrue(xml.contains("recency=\"3 turns ago\""))
        XCTAssertTrue(xml.contains("recency=\"2 turns ago\""))
        XCTAssertTrue(xml.contains("recency=\"1 turn ago\""))
    }

    func testUserCorrectionSignal() {
        let history: [ChatMessage] = [
            makeUserMessage("Run rm -rf /"),
            makeAgentMessage("Denied.", toolEvents: [
                (name: "execute_shell", params: "{\"command\":\"rm -rf /\"}", output: "User explicitly denied permission", isSuccess: false, failureCategory: .userDenied)
            ])
        ]

        let xml = EpisodicHistoryFormatter.buildRecentHistoryString(from: history)

        XCTAssertTrue(xml.contains("<user_correction>User denied: execute_shell</user_correction>"))
    }

    func testParamsSerialization() {
        let history: [ChatMessage] = [
            makeUserMessage("Search for Python files"),
            makeAgentMessage("Found files.", toolEvents: [
                (name: "fs_smart_search", params: "{\"search_term\":\"*.py\",\"search_scope\":\"/tmp\"}", output: nil, isSuccess: true, failureCategory: nil)
            ])
        ]

        let xml = EpisodicHistoryFormatter.buildRecentHistoryString(from: history)

        XCTAssertTrue(xml.contains("search_scope=\"/tmp\""))
        XCTAssertTrue(xml.contains("search_term=\"*.py\""))
    }

    func testEmptyParamsLegacyMigration() {
        // Legacy migrated messages have params: ""
        let history: [ChatMessage] = [
            makeUserMessage("Old query"),
            makeAgentMessage("Old response.", toolEvents: [
                (name: "list_directory", params: "", output: "result", isSuccess: true, failureCategory: nil)
            ])
        ]

        let xml = EpisodicHistoryFormatter.buildRecentHistoryString(from: history)

        XCTAssertTrue(xml.contains("tool=\"list_directory\""))
        // No <params/> element should appear for empty params
        XCTAssertFalse(xml.contains("<params"))
    }

    func testMultipleToolsPerTurn() {
        let history: [ChatMessage] = [
            makeUserMessage("Read and search files"),
            makeAgentMessage("Done.", toolEvents: [
                (name: "read_file", params: "{\"path\":\"/tmp/a.txt\"}", output: "content", isSuccess: true, failureCategory: nil),
                (name: "fs_smart_search", params: "{\"search_term\":\"hello\"}", output: "found", isSuccess: true, failureCategory: nil)
            ])
        ]

        let xml = EpisodicHistoryFormatter.buildRecentHistoryString(from: history)

        XCTAssertTrue(xml.contains("tool=\"read_file\""))
        XCTAssertTrue(xml.contains("tool=\"fs_smart_search\""))
    }

    func testXMLEscaping() {
        let history: [ChatMessage] = [
            makeUserMessage("Find files with \"special\" <chars> & symbols"),
            makeAgentMessage("Done.", toolEvents: [
                (name: "fs_smart_search", params: "{\"search_term\":\"<>&\\\"\"}", output: nil, isSuccess: true, failureCategory: nil)
            ])
        ]

        let xml = EpisodicHistoryFormatter.buildRecentHistoryString(from: history)

        // Goal should be escaped
        XCTAssertTrue(xml.contains("&amp;"))
        XCTAssertTrue(xml.contains("&lt;"))
        XCTAssertTrue(xml.contains("&gt;"))
        XCTAssertTrue(xml.contains("&quot;"))
    }

    // MARK: - buildGraph Tests

    func testGhostProtocolPreserved() {
        let history: [ChatMessage] = [
            makeUserMessage("Delete file"),
            makeAgentMessage("Failed.", toolEvents: [
                (name: "delete_file", params: "{\"path\":\"/tmp/x\"}", output: "Permission denied", isSuccess: false, failureCategory: .permissionRejected)
            ]),
            makeUserMessage("Try again"),
            makeAgentMessage("OK.", toolEvents: [
                (name: "read_file", params: "{\"path\":\"/tmp/x\"}", output: "contents", isSuccess: true, failureCategory: nil)
            ])
        ]

        let graph = EpisodicHistoryFormatter.buildGraph(from: history, sessionID: "test")

        XCTAssertTrue(graph.negativeConstraints.contains("delete_file"), "Failed tool should be in negative constraints")
        XCTAssertFalse(graph.negativeConstraints.contains("read_file"), "Successful tool should NOT be in negative constraints")
    }

    func testBuildGraphEnrichesActions() {
        let history: [ChatMessage] = [
            makeUserMessage("Search for logs"),
            makeAgentMessage("Found logs.", toolEvents: [
                (name: "fs_smart_search", params: "{\"search_term\":\"*.log\",\"search_scope\":\"/var\"}", output: "found 5", isSuccess: true, failureCategory: nil)
            ])
        ]

        let graph = EpisodicHistoryFormatter.buildGraph(from: history, sessionID: "test")

        XCTAssertEqual(graph.episodes.count, 1)
        let episode = graph.episodes[0]
        XCTAssertEqual(episode.actions.count, 1)

        let action = episode.actions[0]
        XCTAssertEqual(action.toolName, "fs_smart_search")
        XCTAssertEqual(action.params["search_term"], "*.log")
        XCTAssertEqual(action.params["search_scope"], "/var")
        XCTAssertEqual(action.status, .success)
        XCTAssertNil(action.errorReason)
    }

    /// The legacy path the four denial tests above were exercising by ACCIDENT until their
    /// fixtures were corrected: a failed row with no category, as persisted before
    /// `failureCategory` existed. `classify()` treats it as a generic failure and deliberately
    /// does NOT ban the tool — Ghost Protocol on unclassified data would also ban timeouts and
    /// transient errors it was never meant to cover.
    ///
    /// Also pins that the denial phrasing in `output` is no longer a signal. Reading it was
    /// the old scheme, and re-introducing it would resurrect the string-matching this suite's
    /// staleness came from.
    func testLegacyFailureWithoutCategoryStaysSoft() {
        let history: [ChatMessage] = [
            makeUserMessage("Delete file"),
            makeAgentMessage("Failed.", toolEvents: [
                (name: "delete_file", params: "{}", output: "User explicitly denied permission",
                 isSuccess: false, failureCategory: nil)
            ])
        ]

        let xml = EpisodicHistoryFormatter.buildRecentHistoryString(from: history)
        XCTAssertTrue(xml.contains("status=\"failed\""), "no category → generic failure")
        XCTAssertFalse(xml.contains("status=\"denied\""), "the output TEXT must not be re-read as a signal")
        XCTAssertFalse(xml.contains("<user_correction>"), "no correction without a typed denial")

        let graph = EpisodicHistoryFormatter.buildGraph(from: history, sessionID: "test")
        XCTAssertTrue(graph.negativeConstraints.isEmpty,
                      "an unclassified failure must not ban the tool: \(graph.negativeConstraints)")
    }

    func testBuildGraphUserCorrection() {
        let history: [ChatMessage] = [
            makeUserMessage("Delete everything"),
            makeAgentMessage("Denied.", toolEvents: [
                (name: "delete_file", params: "{}", output: "User explicitly denied permission", isSuccess: false, failureCategory: .userDenied)
            ])
        ]

        let graph = EpisodicHistoryFormatter.buildGraph(from: history, sessionID: "test")

        XCTAssertEqual(graph.episodes.count, 1)
        XCTAssertEqual(graph.episodes[0].userCorrection, "User denied: delete_file")
    }
}
