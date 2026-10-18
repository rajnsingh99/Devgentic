// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
//
//  HistoryProseSizingTests.swift
//  DevgenticTests
//
//  Created by Raj Singh.
//

import XCTest
@testable import devgentic

final class HistoryProseSizingTests: XCTestCase {

    private let convID = UUID()
    private let t0 = Date(timeIntervalSince1970: 8_000_000)
    private let window = 32_768

    // MARK: - Fixtures

    /// `pairs` turns of chatty prose — the shape that made the over-count severe.
    private func conversation(pairs: Int, replyChars: Int = 2_000) -> [ChatMessage] {
        var messages: [ChatMessage] = []
        for i in 0..<pairs {
            messages.append(ChatMessage(id: UUID(), conversationId: convID,
                                        timestamp: t0.addingTimeInterval(TimeInterval(i * 2)),
                                        sender: .user, content: .plainText(String(repeating: "q", count: 200))))
            messages.append(ChatMessage(id: UUID(), conversationId: convID,
                                        timestamp: t0.addingTimeInterval(TimeInterval(i * 2 + 1)),
                                        sender: .agent, content: .plainText(String(repeating: "a", count: replyChars))))
        }
        return messages
    }

    private func rawSum(_ messages: [ChatMessage]) -> Int {
        messages.reduce(0) { $0 + ($1.content.textContent?.count ?? 0) }
    }

    // MARK: - The severe case

    /// A provider that receives no native turns must be charged NOTHING for prose. Its prior
    /// turns ride the episodic blob's goal/outcome, which is counted separately.
    func testNonCarryingProviderIsChargedNothingForProse() {
        let history = conversation(pairs: 25)

        let charged = PromptFitCheck.estimatedHistoryProseChars(
            in: history, carriesProse: false, strategy: .recentHistory, contextWindow: window
        )

        XCTAssertEqual(charged, 0, "MLX ships no prose; charging any is phantom")
        XCTAssertGreaterThan(rawSum(history), 50_000, "sanity: the old sum charged ~55K chars")
    }

    /// The headline regression, as a ratio rather than a magic number.
    func testTheOldSumWasOverwhelminglyPhantomOnANonCarryingProvider() {
        let history = conversation(pairs: 25)
        let old = rawSum(history)
        let now = PromptFitCheck.estimatedHistoryProseChars(
            in: history, carriesProse: false, strategy: .recentHistory, contextWindow: window
        )
        XCTAssertLessThan(Double(now), Double(old) * 0.02, "\(now) vs \(old)")
    }

    // MARK: - Carrying providers are charged what actually ships

    /// Still bounded by the strategy's turn limit: 25 pairs exist, 10 ship.
    func testCarryingProviderIsChargedOnlyTheTurnsThatShip() {
        let history = conversation(pairs: 25)
        let charged = PromptFitCheck.estimatedHistoryProseChars(
            in: history, carriesProse: true, strategy: .recentHistory, contextWindow: window
        )

        XCTAssertGreaterThan(charged, 0, "native providers DO carry prose")
        XCTAssertLessThan(charged, rawSum(history),
                          "…but only the last 10 pairs, not all 25: \(charged) vs \(rawSum(history))")
    }

    /// A short conversation fits entirely, so measured ≈ raw. Guards against the gate being
    /// over-applied and zeroing prose that really does ship.
    func testShortCarryingConversationIsChargedInFull() {
        let history = conversation(pairs: 2, replyChars: 100)
        let charged = PromptFitCheck.estimatedHistoryProseChars(
            in: history, carriesProse: true, strategy: .recentHistory, contextWindow: window
        )
        XCTAssertGreaterThan(charged, rawSum(history) / 2,
                             "a 2-turn chat ships essentially all of its prose")
    }

    /// The char budget trims oldest-first, so a tiny window charges less than a large one for
    /// the same conversation.
    func testASmallerWindowChargesLessProse() {
        let history = conversation(pairs: 25)
        let big = PromptFitCheck.estimatedHistoryProseChars(
            in: history, carriesProse: true, strategy: .recentHistory, contextWindow: 200_000
        )
        let small = PromptFitCheck.estimatedHistoryProseChars(
            in: history, carriesProse: true, strategy: .recentHistory, contextWindow: 4_096
        )
        XCTAssertLessThan(small, big, "the budget must bite on a small window: \(small) vs \(big)")
    }

    /// Strategy-aware: pointer ships skeletons, so it charges far less than full inline turns.
    func testPointerChargesLessThanRecent() {
        let history = conversation(pairs: 25)
        func chars(_ s: HistoryStrategy) -> Int {
            PromptFitCheck.estimatedHistoryProseChars(
                in: history, carriesProse: true, strategy: s, contextWindow: window)
        }
        XCTAssertLessThan(chars(.pointer), chars(.recentHistory))
    }

    func testEmptyHistoryCostsNothing() {
        XCTAssertEqual(
            PromptFitCheck.estimatedHistoryProseChars(
                in: [], carriesProse: true, strategy: .recentHistory, contextWindow: window), 0)
    }

    // MARK: - Alignment with what ships

    /// The measurement must BE the built turns, not an approximation. If anyone reintroduces
    /// a parallel estimate, this fails.
    func testMeasurementEqualsTheBuiltNativeTurns() {
        let history = conversation(pairs: 6)

        for strategy in HistoryStrategy.allCases {
            let measured = PromptFitCheck.estimatedHistoryProseChars(
                in: history, carriesProse: true, strategy: strategy, contextWindow: window
            )
            let shipped = NativeHistoryConverter.build(
                strategy: strategy,
                from: history,
                charBudget: PromptFitCheck.historyCharBudget(forContextWindow: window),
                includeImages: false,
                // Matches the gauge call above, which takes the default. If these ever diverge
                // the assertion below is comparing two different renderings and proves nothing.
                toolsAvailable: true
            ).reduce(0) { $0 + $1.text.count }

            XCTAssertEqual(measured, shipped, "\(strategy.rawValue): gauge and request must agree")
        }
    }

    /// Nil strategy (bot / code) resolves to `.recentHistory`, matching AgentConnect's own
    /// non-agent fallback — and bots are hard-locked to that strategy anyway.
    func testNilStrategyMatchesRecentHistory() {
        let history = conversation(pairs: 4)
        XCTAssertEqual(
            PromptFitCheck.estimatedHistoryProseChars(
                in: history, carriesProse: true, strategy: nil, contextWindow: window),
            PromptFitCheck.estimatedHistoryProseChars(
                in: history, carriesProse: true, strategy: .recentHistory, contextWindow: window)
        )
    }
}
