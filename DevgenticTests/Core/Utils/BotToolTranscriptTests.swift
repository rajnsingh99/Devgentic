// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2026 Raj Singh
//
//  BotToolTranscriptTests.swift
//  DevgenticTests
//
//  `pairTurns` extracts tool actions from persisted timeline events with no profile gating,
//  so switching an agent conversation to a BOT profile shipped the model a full tool-execution
//  transcript — names, arguments, `<effect>` diffs — for tools it has no schemas for
//  (`rawTools = []`) and no dispatch loop to run (`ChatExecutor` sends `tools: nil`).
//
//  Two problems, and only one is context waste. The sharper one is that the codebase already
//  documents this pressure: when tool summaries were baked into assistant turns, models
//  imitated the FORMAT instead of calling tools. A bot shown `<action tool="write_file">` with
//  nothing to match it against is the same trap.
//
//  The actions are true history and stay. What goes is the revert instrument — a diff is for
//  undoing, and a profile that cannot call `write_file` cannot undo anything.
//

import XCTest
@testable import devgentic

final class BotToolTranscriptTests: XCTestCase {

    private let convID = UUID()
    private let t0 = Date(timeIntervalSince1970: 9_000_000)

    // MARK: - Fixtures

    private func toolTurn() -> [ChatMessage] {
        var data = ToolExecutionData(
            id: UUID(), name: "write_file",
            params: #"{"path":"/Users/me/Shape.java"}"#,
            output: "Successfully wrote", isSuccess: true, isExecuting: false
        )
        data.effect = ActionEffect(
            path: "/Users/me/Shape.java", linesAdded: 14, linesRemoved: 5,
            diff: "+    public abstract double calculateArea();\n-    public double area();",
            isTruncated: false
        )
        let user = ChatMessage(id: UUID(), conversationId: convID, timestamp: t0,
                               sender: .user, content: .plainText("refactor Shape"))
        let agent = ChatMessage(id: UUID(), conversationId: convID, timestamp: t0.addingTimeInterval(1),
                                sender: .agent, content: .plainText("Done."))
        agent.timelineEvents = [.toolExecution(data)]
        return [user, agent]
    }

    private func blob(toolsAvailable: Bool) -> String {
        EpisodicHistoryFormatter.build(
            strategy: .recentHistory, from: toolTurn(), toolsAvailable: toolsAvailable
        )
    }

    // MARK: - What a tool-less profile stops receiving

    /// The diff is a revert instrument. A bot cannot revert, so carrying it spends context on
    /// something it can never use.
    func testBotDoesNotReceiveTheDiffBody() {
        let bot = blob(toolsAvailable: false)
        XCTAssertFalse(bot.contains("calculateArea"), "the diff body must not ship:\n\(bot)")
        XCTAssertTrue(bot.contains("diff=\"withheld\""))
    }

    /// …and an agent still does. The fix must not quietly disarm the feature it was built for.
    func testAgentStillReceivesTheDiffBody() {
        XCTAssertTrue(blob(toolsAvailable: true).contains("+    public abstract double calculateArea();"))
    }

    // MARK: - What it keeps

    /// The history is TRUE. "What did you change earlier?" must stay answerable — only "undo
    /// it" becomes unavailable.
    func testBotStillLearnsWhatChangedAndByHowMuch() {
        let bot = blob(toolsAvailable: false)
        XCTAssertTrue(bot.contains("Shape.java"), "the file must still be named")
        XCTAssertTrue(bot.contains("added=\"14\""))
        XCTAssertTrue(bot.contains("removed=\"5\""))
        XCTAssertTrue(bot.contains("write_file"), "the action itself is factual history")
    }

    // MARK: - Saying so, rather than leaving it to be inferred

    /// A marker the model has to interpret is weaker than a sentence. This is the mimicry
    /// guard: an explicit statement that no tools exist this turn.
    func testBotBlobStatesThatNoToolsAreAvailable() {
        let bot = blob(toolsAvailable: false)
        XCTAssertTrue(bot.contains("<tool_availability>"), "\(bot)")
        XCTAssertTrue(bot.contains("NO tools available"))
    }

    func testAgentBlobCarriesNoSuchNote() {
        XCTAssertFalse(blob(toolsAvailable: true).contains("<tool_availability>"))
    }

    /// A conversation with no tool history has nothing to disclaim — the note would be noise.
    func testNoteIsOmittedWhenThereAreNoToolActions() {
        let plain = [
            ChatMessage(id: UUID(), conversationId: convID, timestamp: t0,
                        sender: .user, content: .plainText("hello")),
            ChatMessage(id: UUID(), conversationId: convID, timestamp: t0.addingTimeInterval(1),
                        sender: .agent, content: .plainText("hi"))
        ]
        let bot = EpisodicHistoryFormatter.build(
            strategy: .recentHistory, from: plain, toolsAvailable: false
        )
        XCTAssertFalse(bot.contains("<tool_availability>"), "\(bot)")
    }

    // MARK: - Marker distinctness

    /// Four reasons a body can be absent, four different things the model can do about it.
    /// `withheld` must not be confused with the two that carry different implications:
    /// `elided` (budget dropped it) or `on_demand` (fetch it — there is no tool to fetch with).
    func testWithheldIsDistinctFromElidedAndOnDemand() {
        let effect = ActionEffect(path: "/a/B.swift", linesAdded: 1, linesRemoved: 1,
                                  diff: "+new\n-old", isTruncated: false)

        let withheld = EpisodicHistoryFormatter.renderEffect(effect, diff: .withheld)
        XCTAssertTrue(withheld.contains("diff=\"withheld\""))
        XCTAssertFalse(withheld.contains("elided"))
        XCTAssertFalse(withheld.contains("on_demand"))
        XCTAssertFalse(withheld.contains("baseline=\"none\""), "it WAS measured")
    }

    // MARK: - What it costs

    /// The framing note is a FIXED ~300 chars while the saving scales with diff volume, so on
    /// a single tiny diff the bot blob is actually LARGER. That is the right trade — the note
    /// exists to stop a tool-less profile being handed a tool-call format to imitate, which is
    /// a correctness guard, not a size optimisation — but it should be stated, not discovered.
    func testTheFramingNoteCostsMoreThanItSavesOnATrivialConversation() {
        let bot = blob(toolsAvailable: false)
        let agent = blob(toolsAvailable: true)
        XCTAssertGreaterThan(bot.count, agent.count,
                             "one 90-char diff cannot pay for a 300-char note (bot \(bot.count) vs agent \(agent.count))")
    }

    /// With realistic diff volume the saving dominates, which is the case that actually
    /// occurs: a conversation switched from an agent to a bot has real edit history behind it.
    func testBotBlobIsMateriallySmallerOnceThereIsRealDiffVolume() {
        func history(files: [String]) -> [ChatMessage] {
            var messages: [ChatMessage] = []
            for (i, name) in files.enumerated() {
                var data = ToolExecutionData(
                    id: UUID(), name: "write_file", params: #"{"path":"/Users/me/\#(name)"}"#,
                    output: "ok", isSuccess: true, isExecuting: false
                )
                data.effect = ActionEffect(path: "/Users/me/\(name)", linesAdded: 20, linesRemoved: 8,
                                           diff: String(repeating: "+ changed line\n", count: 40),
                                           isTruncated: false)
                messages.append(ChatMessage(id: UUID(), conversationId: convID,
                                            timestamp: t0.addingTimeInterval(TimeInterval(i * 2)),
                                            sender: .user, content: .plainText("edit \(name)")))
                let agent = ChatMessage(id: UUID(), conversationId: convID,
                                        timestamp: t0.addingTimeInterval(TimeInterval(i * 2 + 1)),
                                        sender: .agent, content: .plainText("Done."))
                agent.timelineEvents = [.toolExecution(data)]
                messages.append(agent)
            }
            return messages
        }

        let messages = history(files: ["A.java", "B.java", "C.java", "D.java", "E.java"])
        let bot = EpisodicHistoryFormatter.build(strategy: .recentHistory, from: messages, toolsAvailable: false)
        let agent = EpisodicHistoryFormatter.build(strategy: .recentHistory, from: messages, toolsAvailable: true)

        XCTAssertLessThan(bot.count, agent.count / 2,
                          "5 real diffs: bot \(bot.count) vs agent \(agent.count) chars")
    }
}
