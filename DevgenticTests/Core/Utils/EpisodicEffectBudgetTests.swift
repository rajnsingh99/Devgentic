// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
//
//  EpisodicEffectBudgetTests.swift
//  DevgenticTests
//
//  Created by Raj Singh.
//

import XCTest
@testable import devgentic

final class EpisodicEffectBudgetTests: XCTestCase {

    private let convID = UUID()
    private let t0 = Date(timeIntervalSince1970: 2_000_000)

    // MARK: - Fixtures

    /// A diff of a known, controllable size so budget arithmetic is exact.
    private func diff(chars: Int) -> String {
        String(repeating: "x", count: chars)
    }

    private func effect(_ fileName: String, diff body: String?, truncated: Bool = false) -> ActionEffect {
        ActionEffect(path: "/Users/me/\(fileName)", linesAdded: 14, linesRemoved: 5,
                     diff: body, isTruncated: truncated)
    }

    private func writeAction(_ fileName: String, effect: ActionEffect) -> ToolExecutionData {
        var data = ToolExecutionData(
            id: UUID(), name: "write_file",
            params: #"{"path":"/Users/me/\#(fileName)"}"#,
            output: "Successfully wrote", isSuccess: true, isExecuting: false
        )
        data.effect = effect
        return data
    }

    /// One turn per file, each carrying a single write of `diffChars`.
    private func turns(files: [String], diffChars: Int) -> [ChatMessage] {
        var history: [ChatMessage] = []
        for (index, name) in files.enumerated() {
            history.append(ChatMessage(id: UUID(), conversationId: convID,
                                       timestamp: t0.addingTimeInterval(TimeInterval(index * 2)),
                                       sender: .user, content: .plainText("Edit \(name)")))
            let agent = ChatMessage(id: UUID(), conversationId: convID,
                                    timestamp: t0.addingTimeInterval(TimeInterval(index * 2 + 1)),
                                    sender: .agent, content: .plainText("Done."))
            agent.timelineEvents = [.toolExecution(
                writeAction(name, effect: effect(name, diff: diff(chars: diffChars)))
            )]
            history.append(agent)
        }
        return history
    }

    // MARK: - The budget bites, oldest first

    /// Four 1,000-char diffs against a 2,500-char budget: the two newest fit, the two
    /// oldest are elided. Newest-first because "undo that" refers to the most recent write.
    func testBudgetElidesOldestFirst() {
        let history = turns(files: ["A.java", "B.java", "C.java", "D.java"], diffChars: 1_000)
        let xml = EpisodicHistoryFormatter.buildRecentHistoryString(
            from: history, limit: 10, effectBudget: 2_500
        )

        func elided(_ file: String) -> Bool {
            guard let range = xml.range(of: "file=\"\(file)\"") else {
                XCTFail("\(file) missing entirely from:\n\(xml)"); return false
            }
            let element = xml[range.lowerBound...].prefix(220)
            return element.contains("diff=\"elided\"")
        }

        XCTAssertTrue(elided("A.java"), "oldest must be elided first")
        XCTAssertTrue(elided("B.java"), "second oldest must be elided too")
        XCTAssertFalse(elided("C.java"), "the newest two fit the budget")
        XCTAssertFalse(elided("D.java"), "the newest must always be carried")
    }

    /// The budget is AGGREGATE, not per action — that was the whole defect. Two turns of
    /// 1,000 chars against a budget of 1,500 must elide one, even though each individually
    /// is well under both the budget and `diffCharacterLimit`.
    func testBudgetIsAggregateNotPerAction() {
        let history = turns(files: ["A.java", "B.java"], diffChars: 1_000)
        let xml = EpisodicHistoryFormatter.buildRecentHistoryString(
            from: history, limit: 10, effectBudget: 1_500
        )
        XCTAssertEqual(xml.components(separatedBy: "diff=\"elided\"").count - 1, 1,
                       "exactly one of the two must be elided:\n\(xml)")
    }

    /// An elided effect keeps its element and its counts. Dropping the whole element would
    /// read as "nothing happened" — the exact failure `<effect>` was introduced to fix.
    func testElidedEffectKeepsElementAndCounts() {
        let history = turns(files: ["Big.java"], diffChars: 5_000)
        let xml = EpisodicHistoryFormatter.buildRecentHistoryString(
            from: history, limit: 10, effectBudget: 100
        )

        XCTAssertTrue(xml.contains("<effect file=\"Big.java\""), "the element must survive")
        XCTAssertTrue(xml.contains("added=\"14\""), "counts are real and must survive")
        XCTAssertTrue(xml.contains("removed=\"5\""))
        XCTAssertTrue(xml.contains("diff=\"elided\""))
        XCTAssertFalse(xml.contains("xxxxx"), "the body itself must be gone")
    }

    /// No budget → nothing elided. The default path is unchanged.
    func testNilBudgetCarriesEveryDiff() {
        let history = turns(files: ["A.java", "B.java", "C.java"], diffChars: 4_000)
        let xml = EpisodicHistoryFormatter.buildRecentHistoryString(from: history, limit: 10)

        XCTAssertFalse(xml.contains("diff=\"elided\""))
        XCTAssertEqual(xml.components(separatedBy: "<effect ").count - 1, 3)
    }

    /// A budget nobody exceeds must not mark anything.
    func testGenerousBudgetElidesNothing() {
        let history = turns(files: ["A.java", "B.java"], diffChars: 100)
        let xml = EpisodicHistoryFormatter.buildRecentHistoryString(
            from: history, limit: 10, effectBudget: 100_000
        )
        XCTAssertFalse(xml.contains("diff=\"elided\""))
    }

    // MARK: - Marker distinctness (the part that must not be got wrong)

    /// `baseline="none"` means the pre-image was never captured — unrecoverable, counts are
    /// placeholders. `diff="elided"` means measured, counts real, body dropped to fit. They
    /// describe opposite situations and must never appear on the same element.
    func testElidedAndBaselineNoneNeverCoOccur() {
        let measured = EpisodicHistoryFormatter.renderEffect(
            effect("Small.java", diff: "+new\n-old"), diff: .elided
        )
        XCTAssertTrue(measured.contains("diff=\"elided\""))
        XCTAssertFalse(measured.contains("baseline=\"none\""),
                       "an elided diff was measured — it must not claim no baseline:\n\(measured)")
    }

    /// An unmeasured write has no body to elide, so budget pressure must not relabel it.
    /// Reporting it as "elided" would tell the model a recoverable diff exists somewhere.
    func testUnmeasuredWriteIsNeverMarkedElided() {
        let unmeasured = EpisodicHistoryFormatter.renderEffect(
            effect("Big.java", diff: nil), diff: .elided
        )
        XCTAssertTrue(unmeasured.contains("baseline=\"none\""))
        XCTAssertFalse(unmeasured.contains("diff=\"elided\""),
                       "nothing was elided — there was never a diff:\n\(unmeasured)")
    }

    /// `truncated` describes the body; with no body it contradicts `elided`.
    func testTruncatedIsSuppressedOnceElided() {
        let clipped = effect("Big.java", diff: "+partial", truncated: true)

        let carried = EpisodicHistoryFormatter.renderEffect(clipped)
        XCTAssertTrue(carried.contains("truncated=\"true\""), "carried: the body IS partial")

        let elided = EpisodicHistoryFormatter.renderEffect(clipped, diff: .elided)
        XCTAssertTrue(elided.contains("diff=\"elided\""))
        XCTAssertFalse(elided.contains("truncated=\"true\""),
                       "no body left for 'partial' to describe:\n\(elided)")
    }

    /// Default stays complete, so an unbudgeted caller can never silently lose a diff.
    func testRenderEffectDefaultsToIncludingTheBody() {
        let xml = EpisodicHistoryFormatter.renderEffect(effect("A.java", diff: "+added"))
        XCTAssertTrue(xml.contains("+added"))
        XCTAssertFalse(xml.contains("diff=\"elided\""))
    }

    // MARK: - Strategy parity under budget

    /// Hybrid budgets its inline segment exactly as recent budgets its window.
    func testHybridElidesIdenticallyToRecent() {
        let history = turns(files: ["A.java", "B.java", "C.java"], diffChars: 1_000)

        let recent = EpisodicHistoryFormatter.buildRecentHistoryString(
            from: history, limit: 3, effectBudget: 1_500
        )
        let hybrid = EpisodicHistoryFormatter.buildHybridHistoryString(
            from: history, inlineCount: 3, effectBudget: 1_500
        )

        XCTAssertEqual(recent.components(separatedBy: "diff=\"elided\"").count,
                       hybrid.components(separatedBy: "diff=\"elided\"").count,
                       "same turns, same budget → same elisions\nrecent:\n\(recent)\nhybrid:\n\(hybrid)")
    }

    /// The pointer segment carries no effect bodies, so it must not consume the budget the
    /// inline segment needs. Four turns, inlineCount 2: the two pointer turns are free.
    func testHybridPointerSegmentDoesNotConsumeTheBudget() {
        let history = turns(files: ["A.java", "B.java", "C.java", "D.java"], diffChars: 1_000)
        let xml = EpisodicHistoryFormatter.buildHybridHistoryString(
            from: history, inlineCount: 2, effectBudget: 2_000
        )
        XCTAssertFalse(xml.contains("diff=\"elided\""),
                       "both inline diffs fit 2000 chars; the pointer turns cost nothing:\n\(xml)")
    }

    // MARK: - Budget derivation

    /// Both channels ride the same prompt, so the effect budget is a SPLIT of the history
    /// char budget, never a second independent allocation.
    func testDiffBudgetIsAQuarterOfTheHistoryBudget() {
        XCTAssertEqual(ActionEffect.diffBudget(forHistoryCharBudget: 480_000), 120_000)
    }

    /// The floor must always clear one whole ordinary write, or a tiny context window would
    /// elide every diff and the feature would silently switch itself off.
    func testDiffBudgetFloorClearsOneFullDiff() {
        let tiny = ActionEffect.diffBudget(forHistoryCharBudget: 4_000)
        XCTAssertGreaterThan(tiny, ActionEffect.diffCharacterLimit,
                             "a maximum-size single diff must still fit at the floor")
    }
}
