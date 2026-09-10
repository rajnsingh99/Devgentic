// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2026 Raj Singh
//
//  ConversationHistoryDetailTests.swift
//  DevgenticTests
//
//  `get_conversation_history(N)` is the escape hatch for the pointer strategy's lossiness —
//  the skeleton replaces `<outcome>` with "Call get_conversation_history(N) for details." and
//  the tool is supposed to supply what was withheld.
//
//  For the agent's response it never did: `TurnRecord.agentResponse` was `pair.outcome`, the
//  identical 200-char clip the prompt already carried. A pointer agent could not recover more
//  than 200 characters of any answer it had given, and a recentHistory agent got a round trip
//  that returned exactly what it already had.
//
//  Tool RESULTS remain deliberately unserved: a call is reproducible from the name and
//  arguments the tool does return.
//

import XCTest
@testable import devgentic

final class ConversationHistoryDetailTests: XCTestCase {

    private let convID = UUID()
    private let t0 = Date(timeIntervalSince1970: 6_000_000)

    // MARK: - Fixtures

    /// Comfortably past the 200-char `<outcome>` clip, with a sentinel at the very end so a
    /// test can prove the TAIL survived, not merely that the string got longer.
    private func longAnswer() -> String {
        String(repeating: "The orchestrator resolves the profile, then the executor runs. ", count: 20)
            + "FINAL_SENTENCE_SENTINEL"
    }

    private func turn(response: String, tool: ToolExecutionData? = nil) -> [ChatMessage] {
        let user = ChatMessage(id: UUID(), conversationId: convID, timestamp: t0,
                               sender: .user, content: .plainText("explain the backend"))
        let agent = ChatMessage(id: UUID(), conversationId: convID, timestamp: t0.addingTimeInterval(1),
                                sender: .agent, content: .plainText(response))
        if let tool { agent.timelineEvents = [.toolExecution(tool)] }
        return [user, agent]
    }

    private func args(_ index: Int) throws -> ConversationHistoryTool.Arguments {
        try JSONDecoder().decode(ConversationHistoryTool.Arguments.self,
                                 from: Data("{\"index\":\(index)}".utf8))
    }

    private func writeRow(diff: String) -> ToolExecutionData {
        var data = ToolExecutionData(
            id: UUID(), name: "write_file", params: #"{"path":"/Users/me/A.swift"}"#,
            output: "SENTINEL_TOOL_OUTPUT", isSuccess: true, isExecuting: false
        )
        data.effect = ActionEffect(path: "/Users/me/A.swift", linesAdded: 3, linesRemoved: 1,
                                   diff: diff, isTruncated: false)
        return data
    }

    // MARK: - The gap

    /// The property that was never true: the tool must return MORE than the skeleton.
    func testToolReturnsMoreThanTheSkeletonsTwoHundredChars() async throws {
        let answer = longAnswer()
        let history = turn(response: answer)

        let tool = ConversationHistoryTool(chatHistory: history)
        let retrieved = try await tool.call(arguments: args(0))
        let skeleton = EpisodicHistoryFormatter.buildPointerHistoryString(from: history)

        XCTAssertGreaterThan(answer.count, 200, "sanity: this answer is clipped in the prompt")
        XCTAssertTrue(retrieved.contains("FINAL_SENTENCE_SENTINEL"),
                      "the TAIL of the answer must survive, not just a longer head:\n\(retrieved)")
        XCTAssertFalse(skeleton.contains("FINAL_SENTENCE_SENTINEL"),
                       "…and the skeleton must still withhold it — that is the whole split")
        XCTAssertGreaterThan(retrieved.count, 200)
    }

    /// De-truncating the retrieval must not inflate the prompt. The 200-char `<outcome>` is
    /// what rides EVERY request; the full text is served only when asked for.
    func testThePromptFormIsUnchanged() {
        let history = turn(response: longAnswer())
        let xml = EpisodicHistoryFormatter.buildRecentHistoryString(from: history, limit: 10)

        XCTAssertFalse(xml.contains("FINAL_SENTENCE_SENTINEL"),
                       "the prompt must still carry the clipped outcome:\n\(xml)")
        XCTAssertTrue(xml.contains("<outcome>"))
    }

    // MARK: - Tool results stay unserved, by decision

    /// A call is reproducible from its name and arguments, both of which ARE returned, so
    /// results are not carried. What a write CHANGED is not reproducible, so that is.
    func testToolResultsAreNotServedButTheRecipeAndDiffAre() async throws {
        let history = turn(response: "Patched it.", tool: writeRow(diff: "+let a = 1\n-let a = 0"))
        let tool = ConversationHistoryTool(chatHistory: history)
        let retrieved = try await tool.call(arguments: args(0))

        XCTAssertFalse(retrieved.contains("SENTINEL_TOOL_OUTPUT"),
                       "tool results are deliberately not stored:\n\(retrieved)")
        XCTAssertTrue(retrieved.contains("write_file"), "the tool NAME is the recipe")
        XCTAssertTrue(retrieved.contains("/Users/me/A.swift"), "…and so are its arguments")
        XCTAssertTrue(retrieved.contains("+let a = 1"), "the diff is not reproducible, so it IS served")
    }

    // MARK: - Bounds

    /// The response prints before the tool rows and the whole result is capped at 32 KB when
    /// persisted, so an unbounded answer would push the diffs — the non-reproducible half —
    /// past the cut.
    func testPathologicalResponseIsClippedSoTheDiffStillSurvives() async throws {
        let huge = String(repeating: "x", count: ConversationHistoryTool.maxResponseChars + 5_000)
        let history = turn(response: huge, tool: writeRow(diff: "+DIFF_SENTINEL"))

        let tool = ConversationHistoryTool(chatHistory: history)
        let retrieved = try await tool.call(arguments: args(0))

        XCTAssertTrue(retrieved.contains("truncated 5000 characters of the agent's response"),
                      "the clip must name its loss")
        XCTAssertTrue(retrieved.contains("+DIFF_SENTINEL"),
                      "the diff must survive the clip — it is the part that cannot be re-derived")
        XCTAssertLessThan(retrieved.count, ToolExecutionData.maxPersistedOutputLength,
                          "and the whole result stays inside the persistence ceiling")
    }

    func testResponseAtExactLimitIsUntouched() async throws {
        let exact = String(repeating: "y", count: ConversationHistoryTool.maxResponseChars)
        let tool = ConversationHistoryTool(chatHistory: turn(response: exact))
        let retrieved = try await tool.call(arguments: args(0))

        XCTAssertFalse(retrieved.contains("truncated"), "the boundary must not clip")
    }

    // MARK: - Degenerate turns

    /// A cancelled turn has no real response, so the synthesis — which names the tools that
    /// did complete — is the fullest thing available and must not regress to a placeholder.
    func testCancelledTurnFallsBackToTheSynthesis() async throws {
        let user = ChatMessage(id: UUID(), conversationId: convID, timestamp: t0,
                               sender: .user, content: .plainText("do it"))
        let agent = ChatMessage(id: UUID(), conversationId: convID, timestamp: t0.addingTimeInterval(1),
                                sender: .agent, content: .plainText(""))
        agent.terminalOutcome = .cancelled
        agent.timelineEvents = [.toolExecution(ToolExecutionData(
            id: UUID(), name: "read_file", params: "{}", output: "ok",
            isSuccess: true, isExecuting: false
        ))]

        let tool = ConversationHistoryTool(chatHistory: [user, agent])
        let retrieved = try await tool.call(arguments: args(0))

        XCTAssertTrue(retrieved.contains("read_file"), "the tools that ran are still named")
        XCTAssertFalse(retrieved.contains("(No response recorded)"),
                       "the synthesis beats a bare placeholder:\n\(retrieved)")
    }
}
