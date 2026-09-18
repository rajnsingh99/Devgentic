// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
//
//  SystemAlertDedupeTests.swift
//  DevgenticTests
//
//  `WindowedLinearMemory.renderableAlerts` — byte-identical alerts collapse to one line carrying
//  their repeat count, then cap to the most recent N.
//
//  ⚠️ WHY THIS FILE EXISTS SEPARATELY. Every pre-existing alert test in
//  `WindowedLinearMemoryTests` / `WindowedLinearMemoryEdgeCaseTests` uses PAIRWISE-DISTINCT alert
//  strings ("Alert 1"…"Alert 5"), so not one of them can distinguish keep-first from keep-last, or
//  dedupe-before-cap from cap-before-dedupe. All 55 stay green against a keep-first implementation
//  that silently drops the newest alert. The cases below are the ones that can fail.
//

import XCTest
@testable import devgentic

final class SystemAlertDedupeTests: XCTestCase {

    private func makeMemory(totalBudget: Int = 10_000, perEntryCap: Int = 500,
                            fullFidelityWindow: Int = 3, maxAlerts: Int = 3) -> WindowedLinearMemory {
        WindowedLinearMemory(config: MemoryBudgetConfig(
            totalBudgetChars: totalBudget, perEntryCap: perEntryCap,
            fullFidelityWindow: fullFidelityWindow, maxSystemAlerts: maxAlerts))
    }

    // MARK: - Keep-last (the case no existing test can see)

    /// ⚠️ THE TRAP. The forward-iterating `Set` idiom — `for a in all where seen.insert(a).inserted`
    /// — keeps the FIRST occurrence, reads identically, and passes every other test in the suite.
    /// On this shape it drops `X`, which is the run's MOST RECENT alert, because dedupe-before-cap
    /// then trims from the front. Only a repeat whose re-occurrence is the newest entry exposes it.
    func testARepeatWhoseLatestOccurrenceIsNewestSurvivesTheCap() {
        let rendered = WindowedLinearMemory.renderableAlerts(["X", "B", "C", "D", "X"], cap: 3)

        XCTAssertTrue(rendered.contains { $0.hasPrefix("X") },
                      "the most recent alert was dropped — this is the keep-first bug. Got: \(rendered)")
        XCTAssertEqual(rendered.count, 3)
        // Keep-last means X's slot is its LAST position, i.e. after D.
        XCTAssertEqual(rendered.map { String($0.prefix(1)) }, ["C", "D", "X"], "got: \(rendered)")
    }

    /// A re-raised alert reclaims recency rather than staying pinned behind staler ones.
    func testARepeatedAlertTakesItsMostRecentPosition() {
        let rendered = WindowedLinearMemory.renderableAlerts(["A", "B", "A"], cap: 3)
        XCTAssertEqual(rendered.map { String($0.prefix(1)) }, ["B", "A"],
                       "A was re-raised after B, so it must render after B. Got: \(rendered)")
    }

    // MARK: - Dedupe before cap

    /// ⚠️ The arithmetic that justifies the ordering. `[A, P, P, P, M]` with cap 3:
    ///   cap-then-dedupe → suffix(3) = [P,P,M] → [P,M]      : 2 distinct, A lost, a slot wasted
    ///   dedupe-then-cap → [A,P,M] → suffix(3) = [A,P,M]    : 3 distinct
    func testDedupeRunsBeforeTheCapSoSlotsAreNotSpentOnRepeats() {
        let rendered = WindowedLinearMemory.renderableAlerts(["A", "P", "P", "P", "M"], cap: 3)

        XCTAssertEqual(rendered.count, 3, "all three slots should carry DISTINCT alerts: \(rendered)")
        XCTAssertTrue(rendered.contains { $0.hasPrefix("A") },
                      "capping first would have lost A entirely: \(rendered)")
        XCTAssertTrue(rendered.contains { $0.hasPrefix("M") })
        XCTAssertTrue(rendered.contains { $0.hasPrefix("P") })
    }

    // MARK: - The count is preserved

    /// ⚠️ Without this the collapse would be the first LOSSY one in the file — its two siblings
    /// keep their evidence (`failed Nx` at :400, `IDENTICAL TO Step M` at :404). The count is the
    /// escalation signal, and for the skip/fallback alerts the repeat IS the message.
    func testRepeatsRenderTheirCountRatherThanDisappearing() {
        let rendered = WindowedLinearMemory.renderableAlerts(["P", "P", "P"], cap: 3)

        XCTAssertEqual(rendered.count, 1)
        XCTAssertEqual(rendered[0], "P (repeated 3x)",
                       "a collapsed repeat must say how many times: \(rendered)")
    }

    /// The inverse — a once-only alert must not acquire a marker.
    func testASingleOccurrenceCarriesNoMarker() {
        XCTAssertEqual(WindowedLinearMemory.renderableAlerts(["P"], cap: 3), ["P"])
        XCTAssertEqual(WindowedLinearMemory.renderableAlerts(["A", "B"], cap: 3), ["A", "B"])
    }

    /// The count is of ALL occurrences, including ones the cap would otherwise have trimmed.
    func testTheCountSpansOccurrencesOlderThanTheCapWindow() {
        let rendered = WindowedLinearMemory.renderableAlerts(["P", "P", "P", "P", "P"], cap: 3)
        XCTAssertEqual(rendered, ["P (repeated 5x)"], "got: \(rendered)")
    }

    // MARK: - Exact match only

    /// ⚠️ No trimming, no casefolding. `unknownToolName` echoes the model's attempted spelling, so
    /// normalising would merge two genuinely different hallucinated names — matching a payload by
    /// shape instead of identity is this codebase's recidivist defect.
    func testNearIdenticalAlertsAreNotMerged() {
        let rendered = WindowedLinearMemory.renderableAlerts(
            ["Tool `reed_file` does not exist.", "Tool `read_flie` does not exist.", "tool `reed_file` does not exist."],
            cap: 5)
        XCTAssertEqual(rendered.count, 3, "different bytes are different alerts: \(rendered)")
        XCTAssertFalse(rendered.contains { $0.contains("repeated") }, "nothing should collapse: \(rendered)")
    }

    func testEmptyAndZeroCapAreHandled() {
        XCTAssertEqual(WindowedLinearMemory.renderableAlerts([], cap: 3), [])
        XCTAssertEqual(WindowedLinearMemory.renderableAlerts(["A"], cap: 0), [])
    }

    // MARK: - Through the real compile path

    func testCompiledPromptCollapsesIdenticalAlertsWithACount() {
        var memory = makeMemory()
        for _ in 1...3 { memory.recordSystemAlert(msg: "Correct your JSON shape.") }

        let compiled = memory.compileForPrompt()
        XCTAssertEqual(compiled.components(separatedBy: "[SYSTEM ALERT]").count - 1, 1,
                       "three identical alerts must render as ONE line:\n\(compiled)")
        XCTAssertTrue(compiled.contains("(repeated 3x)"), "the count must survive:\n\(compiled)")
    }

    func testDistinctAlertsAreStillAllRendered() {
        var memory = makeMemory()
        memory.recordSystemAlert(msg: "First problem.")
        memory.recordSystemAlert(msg: "Second problem.")

        let compiled = memory.compileForPrompt()
        XCTAssertTrue(compiled.contains("First problem."))
        XCTAssertTrue(compiled.contains("Second problem."))
        XCTAssertFalse(compiled.contains("repeated"))
    }

    // MARK: - budgetUtilization mirrors what renders

    /// ⚠️ THE PHANTOM-INFLATION FIX. The estimator used to add every stored alert's bytes while
    /// `compileForPrompt` rendered at most `maxSystemAlerts`. A run recording 11 alerts charged the
    /// budget for 11 and rendered 3 — which is what reported "176% of scratchpad budget used" in a
    /// real 2026-09-13 run, crossing the 1.0 threshold that made the executor record ANOTHER alert.
    /// The file's own G10 comment (:195) already states this mirroring obligation for observations.
    func testUtilizationDoesNotGrowWithAlertsThatWillNeverRender() {
        var memory = makeMemory(totalBudget: 4_000)
        for _ in 1...3 { memory.recordSystemAlert(msg: "Identical pressure nudge.") }
        let afterThree = memory.budgetUtilization

        for _ in 1...8 { memory.recordSystemAlert(msg: "Identical pressure nudge.") }
        let afterEleven = memory.budgetUtilization

        // The rendered text changes only by the repeat count's digits ("3x" → "11x").
        XCTAssertEqual(afterEleven, afterThree, accuracy: 0.01,
                       "eight more copies of one alert must not inflate the estimate — they render "
                       + "as the same single line. got \(afterThree) → \(afterEleven)")
    }

    /// The inverse: distinct alerts up to the cap DO count, so the mirror isn't just "ignore alerts".
    func testUtilizationStillCountsTheAlertsThatDoRender() {
        var memory = makeMemory(totalBudget: 4_000)
        let empty = memory.budgetUtilization
        memory.recordSystemAlert(msg: String(repeating: "z", count: 300))
        let withOne = memory.budgetUtilization

        XCTAssertGreaterThan(withOne, empty, "a rendered alert must still cost budget")
    }

    /// Beyond the cap, extra DISTINCT alerts also stop counting — because they stop rendering.
    func testUtilizationIgnoresDistinctAlertsBeyondTheCap() {
        var memory = makeMemory(totalBudget: 8_000, maxAlerts: 3)
        for i in 1...3 { memory.recordSystemAlert(msg: "Alert \(i) " + String(repeating: "z", count: 200)) }
        let atCap = memory.budgetUtilization

        for i in 4...6 { memory.recordSystemAlert(msg: "Alert \(i) " + String(repeating: "z", count: 200)) }
        let overCap = memory.budgetUtilization

        XCTAssertEqual(overCap, atCap, accuracy: 0.02,
                       "only `maxSystemAlerts` render, so only those may be charged. "
                       + "got \(atCap) → \(overCap)")
    }
}
