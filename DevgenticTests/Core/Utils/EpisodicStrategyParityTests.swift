// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2026 Raj Singh
//
//  EpisodicStrategyParityTests.swift
//  DevgenticTests
//
//  The three episodic emitters each hand-rolled their own turn rendering, and the copies
//  drifted. `buildHybridHistoryString`'s inline branch is commented "same format as
//  buildRecentHistoryString" and was not: no `<effect>`, and `<params>` emitted in
//  Dictionary order instead of sorted. Separately, hybrid returned "" for an empty
//  post-checkpoint history and `buildPointerHistoryString` discards the checkpoint summary
//  outright — both throwing away the `<compacted_context>` that `buildRecentHistoryString`
//  preserves.
//
//  These pin the parity contract so the strategies cannot drift apart again.
//

import XCTest
@testable import devgentic

final class EpisodicStrategyParityTests: XCTestCase {

    private let convID = UUID()
    private let t0 = Date(timeIntervalSince1970: 1_000_000)

    // MARK: - Fixtures

    private func user(_ text: String, at offset: TimeInterval) -> ChatMessage {
        ChatMessage(id: UUID(), conversationId: convID, timestamp: t0.addingTimeInterval(offset),
                    sender: .user, content: .plainText(text))
    }

    private func agent(_ text: String, at offset: TimeInterval, tools: [ToolExecutionData] = []) -> ChatMessage {
        let message = ChatMessage(id: UUID(), conversationId: convID, timestamp: t0.addingTimeInterval(offset),
                                  sender: .agent, content: .plainText(text))
        message.timelineEvents = tools.map { .toolExecution($0) }
        return message
    }

    private func checkpoint(_ summary: String, at offset: TimeInterval) -> ChatMessage {
        ChatMessage(id: UUID(), conversationId: convID, timestamp: t0.addingTimeInterval(offset),
                    sender: .agent, content: .checkpoint(summary: summary))
    }

    private func measuredEffect(_ fileName: String) -> ActionEffect {
        ActionEffect(
            path: "/Users/me/\(fileName)",
            linesAdded: 14,
            linesRemoved: 5,
            diff: "+    public abstract double calculateArea();\n-    public double area();",
            isTruncated: false
        )
    }

    private func write(_ fileName: String, effect: ActionEffect) -> ToolExecutionData {
        var data = ToolExecutionData(
            id: UUID(),
            name: "write_file",
            params: #"{"path":"/Users/me/\#(fileName)"}"#,
            output: "Successfully wrote",
            isSuccess: true,
            isExecuting: false
        )
        data.effect = effect
        return data
    }

    /// Four write turns. Under `hybrid(inlineCount: 3)` the first is a pointer skeleton and
    /// the last three are inline, so one fixture exercises both branches of the split.
    private func fourWriteTurns() -> (history: [ChatMessage], effects: [ActionEffect]) {
        let names = ["A.java", "B.java", "C.java", "D.java"]
        let effects = names.map(measuredEffect)
        var history: [ChatMessage] = []
        for (index, name) in names.enumerated() {
            history.append(user("Edit \(name)", at: TimeInterval(index * 2)))
            history.append(agent("Done.", at: TimeInterval(index * 2 + 1),
                                 tools: [write(name, effect: effects[index])]))
        }
        return (history, effects)
    }

    /// Compaction inserts a checkpoint, so on the NEXT turn the history ends with it and
    /// the post-checkpoint filter yields zero turns.
    private func historyEndingInCheckpoint() -> [ChatMessage] {
        [
            user("Old question", at: 0),
            agent("Old answer", at: 1),
            checkpoint("The user asked about X; the agent explained Y.", at: 2)
        ]
    }

    // MARK: - `<effect>` parity

    /// The core contract. Before the shared-renderer extraction, hybrid's inline branch
    /// emitted `<params>` and `<error>` and dropped the effect entirely — so a "Smart"
    /// profile could not answer "undo that" even for the turn that had just run, while the
    /// persisted effect sat in the row the whole time.
    func testHybridInlineTurnRendersEffectIdenticallyToRecent() {
        let (history, effects) = fourWriteTurns()
        let expected = EpisodicHistoryFormatter.renderEffect(effects[3])

        let recent = EpisodicHistoryFormatter.buildRecentHistoryString(from: history, limit: 10)
        let hybrid = EpisodicHistoryFormatter.buildHybridHistoryString(from: history, inlineCount: 3)

        XCTAssertTrue(recent.contains(expected), "precondition: recent already renders the effect")
        XCTAssertTrue(hybrid.contains(expected),
                      "hybrid's newest inline turn must render the identical effect block:\n\(hybrid)")
    }

    /// Every inline turn, not only the newest — hybrid renders three of them.
    func testHybridRendersEffectForEveryInlineTurn() {
        let (history, effects) = fourWriteTurns()
        let hybrid = EpisodicHistoryFormatter.buildHybridHistoryString(from: history, inlineCount: 3)

        for effect in effects.suffix(3) {
            XCTAssertTrue(hybrid.contains(EpisodicHistoryFormatter.renderEffect(effect)),
                          "inline turn for \(effect.fileName) must carry its effect")
        }
    }

    /// The diff BODY is what makes a change revertible — `- foo()` alone does not say where
    /// to put it back. Assert the lines survive, not merely that an `<effect` tag appears.
    func testHybridCarriesTheDiffBodyNotJustTheCounts() {
        let (history, _) = fourWriteTurns()
        let hybrid = EpisodicHistoryFormatter.buildHybridHistoryString(from: history, inlineCount: 3)

        XCTAssertTrue(hybrid.contains("+    public abstract double calculateArea();"))
        XCTAssertTrue(hybrid.contains("-    public double area();"))
    }

    /// Regression guard for the refactor: routing pointer turns through the inline renderer
    /// would silently inflate every skeleton with params. Omitting them is the whole point
    /// of a pointer skeleton.
    func testHybridPointerSegmentStaysASkeleton() {
        let (history, effects) = fourWriteTurns()
        let hybrid = EpisodicHistoryFormatter.buildHybridHistoryString(from: history, inlineCount: 3)

        guard let oldest = hybrid.range(of: "goal=\"Edit A.java\""),
              let next = hybrid.range(of: "goal=\"Edit B.java\"") else {
            return XCTFail("expected both goals present:\n\(hybrid)")
        }
        let pointerBlock = String(hybrid[oldest.lowerBound..<next.lowerBound])

        XCTAssertTrue(pointerBlock.contains("get_conversation_history(0)"),
                      "the oldest turn must still be a pointer")
        XCTAssertFalse(pointerBlock.contains("<params"),
                       "pointer skeletons carry no params:\n\(pointerBlock)")
        XCTAssertFalse(pointerBlock.contains(EpisodicHistoryFormatter.renderEffect(effects[0])),
                       "the pointer segment carries no inline effect body in phase 1")
    }

    // MARK: - Deterministic `<params>` ordering

    /// `buildRecentHistoryString` sorts params by key; hybrid's inline branch iterated the
    /// Dictionary directly. Swift seeds Dictionary order per process, so the same
    /// conversation rendered a different attribute order on every app launch.
    func testHybridParamsAreSortedLikeRecent() {
        let keys = ["zeta", "eta", "theta", "iota", "kappa", "lambda", "mu", "nu"]
        let json = "{" + keys.map { "\"\($0)\":\"v\"" }.joined(separator: ",") + "}"
        let data = ToolExecutionData(
            id: UUID(), name: "some_tool", params: json,
            output: "ok", isSuccess: true, isExecuting: false
        )
        let history = [user("go", at: 0), agent("done", at: 1, tools: [data])]
        let expected = "<params " + keys.sorted().map { "\($0)=\"v\"" }.joined(separator: " ") + "/>"

        let recent = EpisodicHistoryFormatter.buildRecentHistoryString(from: history, limit: 10)
        let hybrid = EpisodicHistoryFormatter.buildHybridHistoryString(from: history, inlineCount: 3)

        XCTAssertTrue(recent.contains(expected), "precondition: recent sorts by key")
        XCTAssertTrue(hybrid.contains(expected),
                      "hybrid must emit the same deterministic order:\n\(hybrid)")
    }

    // MARK: - Checkpoint survival

    func testRecentPreservesCheckpointWhenNoTurnsFollow() {
        let xml = EpisodicHistoryFormatter.buildRecentHistoryString(
            from: historyEndingInCheckpoint(), limit: 10
        )
        XCTAssertTrue(xml.contains("<compacted_context"), "precondition: recent already preserves it")
    }

    /// Hybrid bailed with "" before reaching `wrapWithCheckpoint`, so the turn immediately
    /// after a compaction sent no episodic memory at all — losing the summary that had just
    /// been computed to stand in for the compacted turns.
    func testHybridPreservesCheckpointWhenNoTurnsFollow() {
        let xml = EpisodicHistoryFormatter.buildHybridHistoryString(
            from: historyEndingInCheckpoint(), inlineCount: 3
        )
        XCTAssertTrue(xml.contains("<compacted_context"),
                      "hybrid dropped the compacted summary entirely:\n\(xml)")
        XCTAssertTrue(xml.contains("The user asked about X"))
    }

    func testPointerPreservesCheckpointWhenNoTurnsFollow() {
        let xml = EpisodicHistoryFormatter.buildPointerHistoryString(from: historyEndingInCheckpoint())
        XCTAssertTrue(xml.contains("<compacted_context"),
                      "pointer dropped the compacted summary entirely:\n\(xml)")
    }

    /// Worse than the empty case: `buildPointerHistoryString` discarded the summary with
    /// `let (_, filteredHistory)` and never called `wrapWithCheckpoint`, so a pointer
    /// profile lost every pre-checkpoint turn with nothing standing in for them — even when
    /// later turns existed to render.
    func testPointerPreservesCheckpointWithFollowingTurns() {
        let history: [ChatMessage] = [
            user("Old question", at: 0),
            agent("Old answer", at: 1),
            checkpoint("The user asked about X; the agent explained Y.", at: 2),
            user("New question", at: 3),
            agent("New answer", at: 4)
        ]
        let xml = EpisodicHistoryFormatter.buildPointerHistoryString(from: history)

        XCTAssertTrue(xml.contains("<compacted_context"),
                      "pointer must carry the compacted summary:\n\(xml)")
        XCTAssertTrue(xml.contains("New question"), "post-checkpoint turns still render")
        XCTAssertFalse(xml.contains("Old question"), "pre-checkpoint turns stay compacted away")
    }
}
