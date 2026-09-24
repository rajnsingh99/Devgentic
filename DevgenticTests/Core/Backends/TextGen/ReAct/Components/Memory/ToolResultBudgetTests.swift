// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
//
//  ToolResultBudgetTests.swift
//  DevgenticTests
//
//  The defect: every tool result in Chat, Code and workflow agents reached an 8K model as its first
//  200 characters. A seven-task `command_output` listing arrived as three lines, a 17-entry
//  `list_directory` as three names and "(truncated listing)". See `ToolResultBudget`.
//

import XCTest
@testable import devgentic

final class ToolResultBudgetTests: XCTestCase {

    /// The payload budget `AgentConnect` actually hands an 8K model.
    private let budget8K = PromptFitCheck.nativePayloadCharBudget(forContextWindow: 8192)

    // MARK: - The regression, as the user saw it

    /// ⚠️⚠️ THE DEVICE CASE. Seven background tasks, one line each — what `command_output` with no
    /// task_id returns. On 2026-09-24 the model received three of them.
    func testASevenTaskListingReachesAn8KModelWhole() {
        let listing = "Background tasks:\n" + (1...7).map {
            "bg_\($0) \"Switch test\" — finished (exit 0), 45s — sleep 45 && echo \"switched ok\""
        }.joined(separator: "\n")
        let limit = ToolResultBudget.limit(payloadBudgetChars: budget8K, protectedChars: 10_000,
                                           resultsInBatch: 1)

        XCTAssertEqual(ToolResultBudget.fit(listing, limit: limit), listing,
                       "the task listing was cut — the model will report tasks as missing")
    }

    /// The same session's `list_directory`: 17 entries, answered as "CONTRIBUTING... (truncated
    /// listing)".
    func testASeventeenEntryDirectoryListingReachesAn8KModelWhole() {
        let listing = (1...17).map { "file   \($0 * 1024) bytes   /Users/dev/Project/SomeFile\($0).swift" }
            .joined(separator: "\n")
        let limit = ToolResultBudget.limit(payloadBudgetChars: budget8K, protectedChars: 10_000,
                                           resultsInBatch: 1)

        XCTAssertEqual(ToolResultBudget.fit(listing, limit: limit), listing)
    }

    // MARK: - The limit

    /// ⚠️ NO LIMIT BELOW WHAT FITS (user, 2026-09-24): one result alone may take ALL the free room.
    /// There used to be a second ceiling at a third of the budget that cut even with room to spare.
    func testOneResultMayUseAllTheFreeRoom() {
        let limit = ToolResultBudget.limit(payloadBudgetChars: 30_000, protectedChars: 0, resultsInBatch: 1)
        XCTAssertEqual(limit, 30_000)
    }

    /// ⚠️ The room compaction can never free is the budget minus the protected prefix. A result
    /// bigger than that overflows no matter how many old exchanges are dropped.
    func testALargePrefixShrinksTheRoom() {
        let limit = ToolResultBudget.limit(payloadBudgetChars: 30_000, protectedChars: 26_000, resultsInBatch: 1)
        XCTAssertEqual(limit, 4_000)
    }

    /// Parallel results share the room rather than each claiming all of it.
    func testParallelResultsShareTheRoom() {
        let alone = ToolResultBudget.limit(payloadBudgetChars: 30_000, protectedChars: 24_000, resultsInBatch: 1)
        let shared = ToolResultBudget.limit(payloadBudgetChars: 30_000, protectedChars: 24_000, resultsInBatch: 3)
        XCTAssertEqual(alone, 6_000)
        XCTAssertEqual(shared, 2_000)
    }

    /// A prefix already over budget must not drive the limit to zero or below.
    func testThereIsAFloor() {
        let limit = ToolResultBudget.limit(payloadBudgetChars: 20_000, protectedChars: 50_000, resultsInBatch: 4)
        XCTAssertEqual(limit, ToolResultBudget.minimumChars)
    }

    /// No budget means no window to measure against — and guessing one is how the 200-char cap
    /// happened. Nothing is cut.
    func testNoBudgetMeansNoCut() {
        XCTAssertEqual(ToolResultBudget.limit(payloadBudgetChars: 0, protectedChars: 0, resultsInBatch: 1), Int.max)
    }

    // MARK: - The cut

    func testAResultThatFitsIsUntouched() {
        let text = String(repeating: "a", count: 500)
        XCTAssertEqual(ToolResultBudget.fit(text, limit: 500), text)
    }

    /// ⚠️ Middle-out: a traceback's cause is at the start and its final error at the end. Keeping
    /// only the head — what the old cap did — drops the line that says what went wrong.
    func testTheStartAndTheEndBothSurvive() {
        let text = "START-" + String(repeating: "m", count: 20_000) + "-END"
        let fitted = ToolResultBudget.fit(text, limit: 2_000)

        XCTAssertTrue(fitted.hasPrefix("START-"), "the head was lost")
        XCTAssertTrue(fitted.hasSuffix("-END"), "the tail was lost — a build's final error would vanish")
    }

    func testTheCutNeverExceedsTheLimit() {
        for size in [1_001, 5_000, 99_999, 1_000_000] {
            let text = String(repeating: "z", count: size)
            for limit in [300, 1_000, 2_048, 6_144] {
                XCTAssertLessThanOrEqual(ToolResultBudget.fit(text, limit: limit).count, limit,
                                         "size \(size) at limit \(limit) overran")
            }
        }
    }

    /// The note must be exact and actionable — "(status truncated in output)" was the model's
    /// answer when the old marker told it nothing.
    func testTheNoteSaysHowMuchWasOmittedAndHowToGetIt() {
        // "#" because it never appears in the note — counting a letter would count the note too.
        let text = String(repeating: "#", count: 10_000)
        let fitted = ToolResultBudget.fit(text, limit: 2_000)
        let kept = fitted.filter { $0 == "#" }.count

        XCTAssertTrue(fitted.contains("\(10_000 - kept) characters omitted"),
                      "the omitted count is wrong: \(fitted.replacingOccurrences(of: "#", with: ""))")
        XCTAssertTrue(fitted.contains("since_line"), "the note no longer tells the model how to get the rest")
    }

    func testATinyLimitStillLabelsTheCut() {
        let fitted = ToolResultBudget.fit(String(repeating: "q", count: 5_000), limit: 250)
        XCTAssertLessThanOrEqual(fitted.count, 250)
        XCTAssertTrue(fitted.contains("truncated"))
    }

    // MARK: - The build-log regression (device test, 2026-09-21), moved from `truncateOutput`

    /// ~1,500 long xcodebuild lines with the verdict in the last few — the shape that made the old
    /// head-only cut discard every outcome marker.
    private func buildLogShaped(lines: Int = 1_525) -> String {
        let noise = (1...(lines - 4)).map { n in
            "    /Users/raj/Library/Developer/Xcode/DerivedData/Devgentic-efeujvswqpzhtqcbqergxvhfjkdc/"
            + "SourcePackages/checkouts/CodeEditSourceEditor/Sources/CodeEditSourceEditor/File\(n).swift "
            + "(in target 'CodeEditSourceEditor' from project 'CodeEdit') step \(n)"
        }
        return (noise + [
            "** TEST BUILD SUCCEEDED **",
            "The following build commands failed:",
            "\tRunning SwiftLint for CodeEditSourceEditor",
            "(2 failures)",
        ]).joined(separator: "\n")
    }

    /// ⚠️⚠️ THE REGRESSION. The model once received 2.1% of a 374 KB log and EVERY outcome marker
    /// was lost; it could not tell whether the build passed. The verdict is at the END.
    func testABuildVerdictAtTheEndSurvives() {
        let fitted = ToolResultBudget.fit(buildLogShaped(), limit: 6_000)
        XCTAssertTrue(fitted.contains("** TEST BUILD SUCCEEDED **"), "the verdict was cut away")
        XCTAssertTrue(fitted.contains("(2 failures)"), "the failure summary was cut away")
        XCTAssertTrue(fitted.contains("File1.swift"), "the head is gone")
    }

    /// `Linting 'RangeStore+F` was the last thing the model got. Whole lines cannot be misread.
    func testNeitherHalfIsCutMidLine() {
        let fitted = ToolResultBudget.fit(buildLogShaped(), limit: 6_000)
        let parts = fitted.components(separatedBy: "characters omitted from the middle")
        guard parts.count == 2 else { return XCTFail("expected exactly one omission note") }
        let headLines = parts[0].components(separatedBy: "\n").filter { $0.contains("File") }
        let tailStart = parts[1].components(separatedBy: "\n").dropFirst()
            .first { !$0.trimmingCharacters(in: .whitespaces).isEmpty && !$0.contains("[") && !$0.contains("line range") }
        XCTAssertTrue(headLines.last?.contains("step ") ?? true, "head ended mid-line: \(headLines.last ?? "")")
        if let tailStart, tailStart.contains("File") {
            XCTAssertTrue(tailStart.hasPrefix("    /Users/"), "tail started mid-line: \(tailStart.prefix(60))")
        }
    }

    /// One enormous line with no newline: snapping to a boundary must not reduce it to nothing.
    func testASingleEnormousLineIsStillDelivered() {
        let fitted = ToolResultBudget.fit(String(repeating: "#", count: 50_000), limit: 6_000)
        XCTAssertGreaterThan(fitted.filter { $0 == "#" }.count, 4_000)
        XCTAssertTrue(fitted.contains("characters omitted"))
    }

    // MARK: - The wiring

    /// ⚠️⚠️ EVERY TEST ABOVE PASSES IF THE NATIVE PATH STOPS CALLING THIS. The executor's native-turn
    /// block has no seam short of a full run, so this reads the source: the fitted observations must
    /// come from `ToolResultBudget`, and the scratchpad cap must not have crept back in.
    func testTheNativePathFitsResultsWithThisBudget() throws {
        // EIGHT components: file → Memory → Components → ReAct → TextGen → Backends → Core → DevgenticTests → root.
        let repoRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let source = repoRoot.appendingPathComponent("Devgentic/Core/Backends/TextGen/ReAct/ReActAgentExecutor.swift")
        try XCTSkipUnless(FileManager.default.fileExists(atPath: source.path),
                          "sources not reachable at \(source.path) — running outside a checkout")

        let code = try String(contentsOf: source, encoding: .utf8)
            .components(separatedBy: "\n")
            .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
            .joined(separator: "\n")

        XCTAssertTrue(code.contains("ToolResultBudget.limit("), "the native path no longer sizes results by the payload budget")
        XCTAssertTrue(code.contains("ToolResultBudget.fit(obs.result"), "the native path no longer fits each result")
        XCTAssertTrue(code.contains("toolResultTurns(observations: truncatedObservations)"),
                      "the fitted observations are no longer what is sent")
        XCTAssertFalse(code.contains("truncatedResult(for:"),
                       "the scratchpad per-entry cap is back on the native path — every result would be cut to ~200 chars again")
    }
}
