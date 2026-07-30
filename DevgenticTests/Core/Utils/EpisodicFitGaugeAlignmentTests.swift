//
//  EpisodicFitGaugeAlignmentTests.swift
//  DevgenticTests
//
//  Both fit gauges measured history as `content.textContent`. Episodic payload — tool
//  params, outcomes, and `<effect>` diffs — lives on timeline `ToolExecutionData`, so
//  `textContent` is nil for all of it and an edit-heavy conversation was charged ZERO for
//  the largest thing in its prompt. The only allowance was a flat `layerOverheadChars`
//  of 2,000, whose own comment claimed to cover "episodic wrappers".
//
//  The fix measures the REAL blob through the same dispatch `AgentConnect` builds with, so
//  gauge and request agree by construction. These tests exist to keep it that way: if
//  anyone reintroduces a parallel estimator, the alignment test fails.
//

import XCTest
@testable import devgentic

final class EpisodicFitGaugeAlignmentTests: XCTestCase {

    private let convID = UUID()
    private let t0 = Date(timeIntervalSince1970: 4_000_000)
    private let window = 32_768

    // MARK: - Fixtures

    private func write(_ fileName: String, diffChars: Int) -> ToolExecutionData {
        var data = ToolExecutionData(
            id: UUID(), name: "write_file",
            params: #"{"path":"/Users/me/\#(fileName)"}"#,
            output: "Successfully wrote", isSuccess: true, isExecuting: false
        )
        data.effect = ActionEffect(
            path: "/Users/me/\(fileName)", linesAdded: 40, linesRemoved: 12,
            diff: String(repeating: "x", count: diffChars), isTruncated: false
        )
        return data
    }

    /// Terse prose, fat diffs — the shape that used to read as an almost-empty conversation.
    private func editHistory(files: [String], diffChars: Int) -> [ChatMessage] {
        var messages: [ChatMessage] = []
        for (index, name) in files.enumerated() {
            messages.append(ChatMessage(id: UUID(), conversationId: convID,
                                        timestamp: t0.addingTimeInterval(TimeInterval(index * 2)),
                                        sender: .user, content: .plainText("fix \(name)")))
            let agent = ChatMessage(id: UUID(), conversationId: convID,
                                    timestamp: t0.addingTimeInterval(TimeInterval(index * 2 + 1)),
                                    sender: .agent, content: .plainText("Done."))
            agent.timelineEvents = [.toolExecution(write(name, diffChars: diffChars))]
            messages.append(agent)
        }
        return messages
    }

    private func textContentChars(_ messages: [ChatMessage]) -> Int {
        messages.reduce(0) { $0 + ($1.content.textContent?.count ?? 0) }
    }

    // MARK: - The defect

    /// Four 2,000-char diffs are ~8 KB of prompt that the gauge valued at nothing. The prose
    /// in this fixture is under 100 chars total, so the gap is the whole point.
    func testEditHeavyHistoryIsNoLongerCountedAsNearlyEmpty() {
        let history = editHistory(files: ["A.java", "B.java", "C.java", "D.java"], diffChars: 2_000)

        let prose = textContentChars(history)
        let episodic = PromptFitCheck.estimatedEpisodicChars(
            in: history, strategy: .recentHistory, contextWindow: window
        )

        XCTAssertLessThan(prose, 100, "sanity: this conversation is almost entirely diffs")
        XCTAssertGreaterThan(episodic, 8_000, "the diffs must be charged: \(episodic) chars")
        XCTAssertGreaterThan(episodic, prose * 50,
                             "the invisible payload dwarfs the visible text (\(episodic) vs \(prose))")
    }

    /// Bigger diffs must cost more. A gauge that ignores diff size is the original bug.
    func testLargerDiffsCostMore() {
        let small = PromptFitCheck.estimatedEpisodicChars(
            in: editHistory(files: ["A.java"], diffChars: 100), strategy: .recentHistory, contextWindow: window
        )
        let large = PromptFitCheck.estimatedEpisodicChars(
            in: editHistory(files: ["A.java"], diffChars: 3_000), strategy: .recentHistory, contextWindow: window
        )
        XCTAssertGreaterThan(large - small, 2_500, "the extra diff bytes must show up")
    }

    // MARK: - Alignment with what actually ships

    /// The estimate must BE the rendered blob, not an approximation of it. If someone
    /// reintroduces a parallel estimator with its own copy of the render rules, this fails.
    func testEstimateEqualsTheRenderedBlobExactly() {
        let history = editHistory(files: ["A.java", "B.java"], diffChars: 500)

        for strategy in HistoryStrategy.allCases {
            let measured = PromptFitCheck.estimatedEpisodicChars(
                in: history, strategy: strategy, contextWindow: window
            )
            let shipped = EpisodicHistoryFormatter.build(
                strategy: strategy,
                from: history,
                effectBudget: ActionEffect.diffBudget(
                    forHistoryCharBudget: PromptFitCheck.historyCharBudget(forContextWindow: window)
                )
            ).count

            XCTAssertEqual(measured, shipped, "\(strategy.rawValue): gauge and request must agree")
        }
    }

    /// Each strategy renders a different amount, so the gauge must be strategy-aware. Pointer
    /// carries counts only; recent carries every body.
    func testGaugeIsStrategyAware() {
        let history = editHistory(files: ["A.java", "B.java", "C.java", "D.java"], diffChars: 1_000)

        func chars(_ strategy: HistoryStrategy) -> Int {
            PromptFitCheck.estimatedEpisodicChars(in: history, strategy: strategy, contextWindow: window)
        }

        XCTAssertLessThan(chars(.pointer), chars(.hybrid), "skeletons are cheaper than inline turns")
        XCTAssertLessThan(chars(.hybrid), chars(.recentHistory),
                          "hybrid inlines 3 of 4 turns; recent inlines all 4")
    }

    /// Non-agent profiles report a nil strategy; `AgentConnect` falls back to `.recentHistory`
    /// for them, so the gauge must too or bots would be mispriced.
    func testNilStrategyMatchesRecentHistory() {
        let history = editHistory(files: ["A.java"], diffChars: 500)
        XCTAssertEqual(
            PromptFitCheck.estimatedEpisodicChars(in: history, strategy: nil, contextWindow: window),
            PromptFitCheck.estimatedEpisodicChars(in: history, strategy: .recentHistory, contextWindow: window)
        )
    }

    /// The gauge renders with `correlation: nil` (silent) and the request renders with one
    /// (logs). If logging ever changed the payload, the gauge would be measuring a different
    /// string than the one that ships — which is the entire failure this alignment work
    /// exists to prevent.
    func testMeasurementAndRequestRendersAreByteIdentical() {
        let history = editHistory(files: ["A.java", "B.java", "C.java"], diffChars: 1_200)
        let budget = ActionEffect.diffBudget(
            forHistoryCharBudget: PromptFitCheck.historyCharBudget(forContextWindow: window)
        )

        // Both budgets: the generous one takes the quiet path, the tight one takes the
        // elision path — where the logger does the most work and so has the most scope to
        // disturb the render it is describing.
        for effectBudget in [budget, 800] {
            for strategy in HistoryStrategy.allCases {
                let measured = EpisodicHistoryFormatter.build(
                    strategy: strategy, from: history, effectBudget: effectBudget, correlation: nil
                )
                let shipped = EpisodicHistoryFormatter.build(
                    strategy: strategy, from: history, effectBudget: effectBudget,
                    correlation: "conv:abc12345 trace:test-trace"
                )
                XCTAssertEqual(measured, shipped,
                               "\(strategy.rawValue) @ budget \(effectBudget): logging must not alter the payload")
            }
        }
    }

    // MARK: - Ordering (the trap the char sum hid)

    /// The chat view holds messages NEWEST-FIRST. `pairTurns` walks forward, so a descending
    /// array pairs each agent reply with the wrong question and loses turns. The old plain
    /// char sum was order-independent, which is exactly why nothing caught this.
    func testDescendingHistoryWouldMisreportSoCallersMustReverse() {
        let ascending = editHistory(files: ["A.java", "B.java", "C.java"], diffChars: 800)
        let descending = Array(ascending.reversed())

        let right = PromptFitCheck.estimatedEpisodicChars(
            in: ascending, strategy: .recentHistory, contextWindow: window
        )
        let wrong = PromptFitCheck.estimatedEpisodicChars(
            in: descending, strategy: .recentHistory, contextWindow: window
        )

        XCTAssertNotEqual(right, wrong,
                          "if these ever match, this test has stopped protecting anything")
        XCTAssertGreaterThan(right, wrong, "descending loses turns, so it UNDER-reports")
    }

    // MARK: - Budget interaction

    /// The gauge must respect Phase 2's elision, or it would charge for diff bodies the
    /// prompt will not carry — a phantom cost the user cannot clear.
    func testEstimateHonoursTheEffectBudget() {
        // Ten maximum-size diffs against a 32K window: the budget elides most of them.
        let history = editHistory(
            files: (1...10).map { "F\($0).java" }, diffChars: ActionEffect.diffCharacterLimit
        )
        let episodic = PromptFitCheck.estimatedEpisodicChars(
            in: history, strategy: .recentHistory, contextWindow: window
        )
        let unbudgeted = 10 * ActionEffect.diffCharacterLimit

        XCTAssertLessThan(episodic, unbudgeted,
                          "elided bodies must not be charged: \(episodic) vs \(unbudgeted)")
    }

    func testEmptyHistoryCostsNothing() {
        XCTAssertEqual(
            PromptFitCheck.estimatedEpisodicChars(in: [], strategy: .recentHistory, contextWindow: window), 0
        )
    }

    // MARK: - Hoisted budget formula

    /// Both budgets are denominated at the SAME ratio the gauge prices with. They were not:
    /// budgets were built at 4.0 while `estimatedTokens` divided by 3.0.
    func testBudgetsAreDenominatedAtTheGaugesRatio() {
        for window in [8_192, 32_768, 200_000] {
            XCTAssertEqual(PromptFitCheck.historyCharBudget(forContextWindow: window),
                           max(4_000, Int(Double(window) * 0.6 * PromptFitCheck.charsPerToken)))
            XCTAssertEqual(PromptFitCheck.nativePayloadCharBudget(forContextWindow: window),
                           max(8_000, Int(Double(window) * 0.75 * PromptFitCheck.charsPerToken)))
        }
    }

    /// The invariant the mismatch broke, and the reason it mattered: a history filled to
    /// exactly the allowance the system granted it priced back at 0.6 × 4 ÷ 3 = 80% of the
    /// window — above the 75% overflow threshold. That posted an advisory with no
    /// attachments, no query and nothing the user could remove to clear it, because the cost
    /// came from history the composer cannot edit.
    func testHistoryAtItsOwnBudgetDoesNotTripTheOverflowBanner() {
        for window in [8_192, 32_768, 128_000, 200_000] {
            let budget = PromptFitCheck.historyCharBudget(forContextWindow: window)
            let priced = PromptFitCheck.estimatedTokens(
                attachmentChars: 0, knowledgeChars: 0, retrievalChars: 0,
                queryChars: 0, historyChars: budget
            )
            XCTAssertFalse(
                PromptFitCheck.exceeds(estimatedTokens: priced, windowTokens: window),
                "window \(window): a history at exactly its own budget priced at \(priced) tok, over the \(Int(Double(window) * 0.75)) threshold"
            )
        }
    }

    /// …and it prices back at the 60% the budget claims, not merely under the threshold.
    /// The fixed layer overhead is the only extra term.
    func testAtBudgetHistoryPricesAtSixtyPercentOfTheWindow() {
        for window in [8_192, 32_768, 200_000] {
            let budget = PromptFitCheck.historyCharBudget(forContextWindow: window)
            let overheadTokens = Double(PromptFitCheck.layerOverheadChars) / PromptFitCheck.charsPerToken
            let priced = Double(PromptFitCheck.estimatedTokens(
                attachmentChars: 0, knowledgeChars: 0, retrievalChars: 0,
                queryChars: 0, historyChars: budget
            )) - overheadTokens

            XCTAssertEqual(priced / Double(window), 0.6, accuracy: 0.01,
                           "window \(window): priced at \(priced / Double(window) * 100)% of the window")
        }
    }

    /// The image weight is spent AGAINST those budgets, so it has to share their
    /// denomination. Holding it at 4.0 against a 3.0 budget mis-charges every image by 33%.
    func testImageBudgetWeightTracksTheSameRatio() {
        XCTAssertEqual(ImageTokenHeuristic.budgetCharsPerToken, PromptFitCheck.charsPerToken)
    }

    /// The fixed overhead no longer stands in for episodic memory, so it must not have grown
    /// to compensate — that would double-charge now that the blob is measured.
    func testLayerOverheadStillCoversOnlyTheFixedLayers() {
        XCTAssertEqual(PromptFitCheck.layerOverheadChars, 2_000)
    }

    // MARK: - Delegated runs

    /// The budget invariant has to hold on the `call_agent` path too, and for a long time it
    /// did not: `CallAgentTool` hand-rolled `max(8000, Int(Double(8192) * 0.75) * 4)`.
    ///
    /// The `* 4` is what makes this more than a style point. The expression READS as "75% of
    /// the window", but 24,576 chars at the 3.0 the rest of the app prices by is 8,192
    /// tokens — the whole window. A cap whose job is to leave room for the response only
    /// engaged after history had eaten the room, which is indistinguishable from no cap.
    ///
    /// Stated as a property rather than a constant so it survives a change to `charsPerToken`.
    func testSpawnedAgentPayloadLeavesRoomForAResponse() {
        let window = CallAgentTool.spawnedContextWindow
        let budget = PromptFitCheck.nativePayloadCharBudget(forContextWindow: window)
        let tokens = Double(budget) / PromptFitCheck.charsPerToken

        XCTAssertLessThanOrEqual(tokens, Double(window) * 0.75 + 1,
                                 "\(budget) chars is \(tokens) tokens of a \(window)-token window")

        let handRolled = Double(max(8_000, Int(Double(window) * 0.75) * 4)) / PromptFitCheck.charsPerToken
        XCTAssertGreaterThan(handRolled, Double(window) * 0.75 + 1,
                             "the old expression must genuinely violate this, or the test proves nothing")
    }
}
