// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
//
//  OutcomeDeduplicationTests.swift
//  DevgenticTests
//
//  Item 13 (2026-10-04): on native providers every prior answer reached the model twice — complete,
//  as a native assistant turn, and again as a 200-char `<outcome>` clip in the episodic XML, cut
//  mid-word. The XML now drops `<outcome>` for exactly the answers the native turns carry in full,
//  matched by agent message id.
//

import XCTest
@testable import devgentic

final class OutcomeDeduplicationTests: XCTestCase {

    private let convID = UUID()
    private let t0 = Date(timeIntervalSince1970: 9_000_000)

    private func message(_ sender: SenderRole, _ text: String, _ i: Int) -> ChatMessage {
        ChatMessage(id: UUID(), conversationId: convID, timestamp: t0.addingTimeInterval(TimeInterval(i)),
                    sender: sender, content: .plainText(text))
    }

    /// `pairs` question/answer turns; answer N is "Answer N: …" padded to `replyChars`.
    private func conversation(pairs: Int, replyChars: Int = 400) -> [ChatMessage] {
        (0..<pairs).flatMap { n -> [ChatMessage] in
            let answer = "Answer \(n): " + String(repeating: "x", count: max(0, replyChars - 10))
            return [message(.user, "Question \(n)?", n * 2), message(.agent, answer, n * 2 + 1)]
        }
    }

    private func outcomeCount(_ xml: String) -> Int { xml.components(separatedBy: "<outcome>").count - 1 }

    // MARK: - Converter provenance

    func testRecentHistoryReportsEveryCarriedAnswer() {
        let history = conversation(pairs: 3)
        let native = NativeHistoryConverter.buildCarryingProvenance(
            strategy: .recentHistory, from: history, charBudget: 100_000, toolsAvailable: true)
        let agentIDs = Set(history.filter { $0.sender == .agent }.map(\.id))
        XCTAssertEqual(native.fullAnswerMessageIDs, agentIDs)
    }

    /// Turns trimmed by the char budget are NOT carried, so they must not be reported.
    func testBudgetTrimmedAnswersAreNotReported() {
        let history = conversation(pairs: 4, replyChars: 1_000)
        let native = NativeHistoryConverter.buildCarryingProvenance(
            strategy: .recentHistory, from: history, charBudget: 2_100, toolsAvailable: true)
        let agents = history.filter { $0.sender == .agent }
        XCTAssertEqual(native.fullAnswerMessageIDs, Set(agents.suffix(2).map(\.id)), "only the two newest fit")
    }

    func testHybridReportsOnlyTheInlineSegment() {
        let history = conversation(pairs: 5)
        let native = NativeHistoryConverter.buildCarryingProvenance(
            strategy: .hybrid, from: history, charBudget: 100_000, toolsAvailable: true)
        let agents = history.filter { $0.sender == .agent }
        XCTAssertEqual(native.fullAnswerMessageIDs, Set(agents.suffix(EpisodicHistoryFormatter.hybridInlineCount).map(\.id)),
                       "pointer skeletons carry a fetch instruction, not the answer")
    }

    func testPointerStrategyCarriesNoAnswers() {
        let native = NativeHistoryConverter.buildCarryingProvenance(
            strategy: .pointer, from: conversation(pairs: 3), charBudget: 100_000, toolsAvailable: true)
        XCTAssertTrue(native.fullAnswerMessageIDs.isEmpty)
    }

    func testBuildStillReturnsTheSameTurns() {
        let history = conversation(pairs: 4)
        for strategy in HistoryStrategy.allCases {
            XCTAssertEqual(
                NativeHistoryConverter.build(strategy: strategy, from: history, charBudget: 3_000, toolsAvailable: true).map(\.text),
                NativeHistoryConverter.buildCarryingProvenance(strategy: strategy, from: history, charBudget: 3_000, toolsAvailable: true).turns.map(\.text),
                "\(strategy)")
        }
    }

    // MARK: - Formatter

    func testCarriedAnswersLoseTheirOutcomeButKeepGoalAndActions() {
        let history = conversation(pairs: 2)
        let carried = Set(history.filter { $0.sender == .agent }.map(\.id))
        let before = EpisodicHistoryFormatter.build(strategy: .recentHistory, from: history)
        let after = EpisodicHistoryFormatter.build(strategy: .recentHistory, from: history, answersCarriedNatively: carried)

        XCTAssertEqual(outcomeCount(before), 2)
        XCTAssertEqual(outcomeCount(after), 0)
        XCTAssertTrue(after.contains(#"goal="Question 0?""#) && after.contains(#"goal="Question 1?""#), "goal ties actions to their question")
        XCTAssertLessThan(after.count, before.count)
    }

    func testOnlyMatchingTurnsLoseTheirOutcome() {
        let history = conversation(pairs: 2)
        let newest = history.last { $0.sender == .agent }!
        let xml = EpisodicHistoryFormatter.build(strategy: .recentHistory, from: history, answersCarriedNatively: [newest.id])
        XCTAssertEqual(outcomeCount(xml), 1)
        XCTAssertTrue(xml.contains("<outcome>Answer 0:"), "the turn the native side did not carry keeps its outcome")
    }

    /// A cancelled turn's outcome is SYNTHESIZED ("…Terminated by user") — no native turn says
    /// that, so it must survive even when its message id is in the set.
    func testSynthesizedOutcomesAreKept() {
        var history = conversation(pairs: 1)
        history.append(message(.user, "Do it", 10))
        let cancelled = message(.agent, ChatMessage.stoppedRunPlaceholder, 11)
        history.append(cancelled)
        let xml = EpisodicHistoryFormatter.build(strategy: .recentHistory, from: history,
                                                 answersCarriedNatively: Set(history.filter { $0.sender == .agent }.map(\.id)))
        XCTAssertEqual(outcomeCount(xml), 1)
        XCTAssertTrue(xml.contains("Terminated by user"))
    }

    /// Without the set (MLX, every pre-existing caller) the XML is byte-identical to before.
    func testEmptySetChangesNothing() {
        let history = conversation(pairs: 5)
        for strategy in HistoryStrategy.allCases {
            XCTAssertEqual(EpisodicHistoryFormatter.build(strategy: strategy, from: history),
                           EpisodicHistoryFormatter.build(strategy: strategy, from: history, answersCarriedNatively: []),
                           "\(strategy)")
        }
    }

    // MARK: - The invariant across both channels

    /// For every strategy and a budget that trims: whatever the XML stops saying, the native turns
    /// say in full. This is the property that keeps an answer from vanishing.
    func testEveryOmittedOutcomeIsCarriedInFull() {
        let history = conversation(pairs: 6, replyChars: 700)
        let agents = history.filter { $0.sender == .agent }
        for strategy in HistoryStrategy.allCases {
            let native = NativeHistoryConverter.buildCarryingProvenance(
                strategy: strategy, from: history, charBudget: 2_500, toolsAvailable: true)
            let xml = EpisodicHistoryFormatter.build(strategy: strategy, from: history,
                                                     answersCarriedNatively: native.fullAnswerMessageIDs)
            let nativeText = native.turns.map(\.text)
            for agent in agents {
                let answer = agent.content.textContent!
                let prefix = String(answer.prefix(9))   // "Answer N:"
                if !xml.contains("<outcome>\(prefix)") && native.fullAnswerMessageIDs.contains(agent.id) {
                    XCTAssertTrue(nativeText.contains(answer), "\(strategy): \(prefix) dropped from XML but not carried in full")
                }
                if !native.fullAnswerMessageIDs.contains(agent.id), strategy != .pointer, strategy != .hybrid {
                    XCTAssertTrue(xml.contains("<outcome>\(prefix)") || !xml.contains(#"goal="Question"#),
                                  "\(strategy): \(prefix) is not carried natively, so the XML must keep it")
                }
            }
        }
    }

    // MARK: - Gauge agrees with the request

    func testGaugeSizesTheSameXMLTheRequestSends() {
        let history = conversation(pairs: 4)
        let window = 32_768
        let budget = PromptFitCheck.historyCharBudget(forContextWindow: window)
        let native = NativeHistoryConverter.buildCarryingProvenance(
            strategy: .hybrid, from: history, charBudget: budget, toolsAvailable: true)
        let shipped = EpisodicHistoryFormatter.build(
            strategy: .hybrid, from: history,
            effectBudget: ActionEffect.diffBudget(forHistoryCharBudget: budget),
            toolsAvailable: true, answersCarriedNatively: native.fullAnswerMessageIDs)

        let gauged = PromptFitCheck.estimatedEpisodicChars(in: history, strategy: .hybrid, contextWindow: window,
                                                           toolsAvailable: true, carriesProse: true)
        XCTAssertEqual(gauged, shipped.count)
        XCTAssertLessThan(gauged, PromptFitCheck.estimatedEpisodicChars(in: history, strategy: .hybrid, contextWindow: window,
                                                                        toolsAvailable: true, carriesProse: false))
    }
}
