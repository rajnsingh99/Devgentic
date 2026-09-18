// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
//
//  CompactionPlannerTests.swift
//  DevgenticTests
//
//  Trigger and batch arithmetic for history compaction — pure, no IntelligenceCore.
//
//  This coverage was impossible before `compactIfNeeded` was split: every path that got
//  past the guards ended in an IC call, so exercising the math meant loading an MLX model.
//  `planCompaction` is the decision half, with the IC context window injected.
//

import XCTest
@testable import devgentic

final class CompactionPlannerTests: XCTestCase {

    private let convID = UUID()
    private let base = Date(timeIntervalSince1970: 1000)

    // Production values, passed explicitly so a change to either is visible here.
    private let triggerRatio = 0.6
    private let promptOverhead = 800

    private func msg(_ offset: TimeInterval, _ text: String, sender: SenderRole = .user) -> ChatMessage {
        ChatMessage(conversationId: convID, timestamp: base.addingTimeInterval(offset),
                    sender: sender, content: .plainText(text))
    }

    /// N turn pairs of `chars` per message, starting at `from`.
    private func pairs(_ count: Int, chars: Int, from: TimeInterval = 0) -> [ChatMessage] {
        let body = String(repeating: "x", count: chars)
        return (0..<count).flatMap { i -> [ChatMessage] in
            let t = from + Double(i * 2)
            return [msg(t, body), msg(t + 1, body, sender: .agent)]
        }
    }

    private func plan(_ history: [ChatMessage], charBudget: Int, icContextWindow: Int = 4096) -> CompactionPlan? {
        HistoryCompactionService.planCompaction(
            chatHistory: history,
            charBudget: charBudget,
            icContextWindow: icContextWindow,
            charBudgetTriggerRatio: triggerRatio,
            icPromptOverheadChars: promptOverhead
        )
    }

    // MARK: - Trigger

    func testNoPlan_WhenUnderCharTrigger() {
        // 10 messages × 100 chars = 1,000 vs a 6,000-char trigger.
        XCTAssertNil(plan(pairs(5, chars: 100), charBudget: 10_000))
    }

    func testPlan_WhenOverCharTrigger() {
        // 40 messages × 600 = 24,000 vs a 600-char trigger.
        XCTAssertNotNil(plan(pairs(20, chars: 600), charBudget: 1_000))
    }

    /// The trigger is a fraction of the budget, not the budget itself — a history at 50% of
    /// budget must not compact, one just over 60% must.
    func testTriggerBoundary_IsSixtyPercentOfBudget() {
        let budget = 10_000
        // 12 messages × 400 = 4,800 chars = 48% of budget → no.
        XCTAssertNil(plan(pairs(6, chars: 400), charBudget: budget))
        // 20 messages × 400 = 8,000 chars = 80% of budget → yes.
        XCTAssertNotNil(plan(pairs(10, chars: 400), charBudget: budget))
    }

    // MARK: - Structural floor

    /// A short-but-huge history must not compact away everything it has: after keeping the
    /// 5 most recent messages, too few remain to be worth an IC inference.
    func testNoPlan_WhenTooFewCompactableMessages() {
        // 6 messages, way over budget; dropLast(5) leaves 1 → below the >= 4 floor.
        XCTAssertNil(plan(pairs(3, chars: 5_000), charBudget: 1_000))
    }

    /// Regression on a trap found while testing: very large messages exhaust the IC input
    /// budget after only a couple of entries, so the batch can fall below the floor even
    /// when the history is enormous. Compaction declines rather than summarizing 2 messages.
    func testNoPlan_WhenHugeMessagesExhaustICBudgetBeforeTheFloor() {
        // 10 × 5,000-char messages: ~2 fit the ~10.5k IC input budget → batch < 4.
        XCTAssertNil(plan(pairs(5, chars: 5_000), charBudget: 1_000))
    }

    func testPlan_KeepsFiveMostRecentMessagesUncompacted() {
        let history = pairs(20, chars: 600)
        let p = plan(history, charBudget: 1_000)
        XCTAssertNotNil(p)

        let compactedIDs = Set(p!.turnsToCompact.map(\.id))
        for recent in history.suffix(5) {
            XCTAssertFalse(compactedIDs.contains(recent.id), "The 5 most recent must stay verbatim")
        }
    }

    // MARK: - IC context window drives batch size

    /// The whole point of injecting the window: a larger IC model compacts more per pass.
    func testLargerICContextWindow_ProducesALargerBatch() {
        let history = pairs(40, chars: 600)
        let small = plan(history, charBudget: 1_000, icContextWindow: 4_096)
        let large = plan(history, charBudget: 1_000, icContextWindow: 32_768)

        XCTAssertNotNil(small)
        XCTAssertNotNil(large)
        XCTAssertGreaterThan(large!.turnsToCompact.count, small!.turnsToCompact.count,
                             "Batch size must scale with the IC model's context window")
    }

    // MARK: - Checkpoints

    func testCheckpointNumber_IsOneForAFirstCompaction() {
        XCTAssertEqual(plan(pairs(20, chars: 600), charBudget: 1_000)?.checkpointNumber, 1)
    }

    /// Cascading: with a prior checkpoint present the number increments and its summary is
    /// carried into the plan (it gets prepended to the next IC prompt).
    func testCheckpointNumber_IncrementsAndCarriesPriorSummary() {
        var history: [ChatMessage] = pairs(3, chars: 100)
        history.append(ChatMessage(conversationId: convID, timestamp: base.addingTimeInterval(50),
                                   sender: .agent, content: .checkpoint(summary: "Earlier summary")))
        history += pairs(20, chars: 600, from: 100)

        let p = plan(history, charBudget: 1_000)

        XCTAssertEqual(p?.checkpointNumber, 2)
        XCTAssertEqual(p?.priorSummary, "Earlier summary")
    }

    /// Only post-checkpoint turns count toward the trigger, so already-summarized history
    /// can't keep re-triggering compaction forever.
    func testPostCheckpointTurnsOnly_CountTowardTheTrigger() {
        var history: [ChatMessage] = pairs(20, chars: 600)   // 24,000 chars, pre-checkpoint
        history.append(ChatMessage(conversationId: convID, timestamp: base.addingTimeInterval(500),
                                   sender: .agent, content: .checkpoint(summary: "Summary")))
        history += pairs(2, chars: 10, from: 600)            // ~40 chars, post-checkpoint

        XCTAssertNil(plan(history, charBudget: 1_000),
                     "The 24,000 pre-checkpoint chars are already summarized and must be excluded")
    }

    // MARK: - Reported figures

    /// `turnPairsInBatch` is what the UI announces, and it counts USER messages — so it is
    /// roughly half the batch size, not the batch size.
    func testTurnPairsInBatch_CountsUserMessagesOnly() {
        let p = plan(pairs(20, chars: 600), charBudget: 1_000)
        XCTAssertNotNil(p)
        let userCount = p!.turnsToCompact.filter { $0.sender == .user }.count
        XCTAssertEqual(p!.turnPairsInBatch, userCount)
        XCTAssertLessThan(p!.turnPairsInBatch, p!.turnsToCompact.count)
    }

    func testEmptyHistory_ProducesNoPlan() {
        XCTAssertNil(plan([], charBudget: 1_000))
    }

    /// Pathological: a history of nothing but checkpoints has no real turns to compact.
    func testAllCheckpointHistory_ProducesNoPlan() {
        let history = [
            ChatMessage(conversationId: convID, timestamp: base, sender: .agent,
                        content: .checkpoint(summary: String(repeating: "s", count: 5_000))),
            ChatMessage(conversationId: convID, timestamp: base.addingTimeInterval(1), sender: .agent,
                        content: .checkpoint(summary: String(repeating: "s", count: 5_000)))
        ]
        XCTAssertNil(plan(history, charBudget: 100))
    }
}
