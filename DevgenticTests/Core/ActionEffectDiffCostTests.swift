// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
//
//  ActionEffectDiffCostTests.swift
//  DevgenticTests
//
//  Register codeviewer/cv-5 — every file-mutating tool completion ran the line-level LCS TWICE
//  on the main actor (`changeCounts` and then `generateDiff` inside `changedLines`) and paid for
//  `generateDiff`'s intra-line refinement, whose `segments` nothing in `ActionEffectBuilder`
//  reads. These pin the cost, not just the output: one line-level pass, zero refinements.
//

import XCTest
@testable import devgentic

/// `@MainActor` so these serialise with the two production callers that diff on the main actor
/// (tool completion in `ActiveStreamManager` / `CapabilityCardRouter`) — the counters are
/// process-global, and a stray main-actor completion between reset and assertion would read
/// as a spurious second pass.
@MainActor
final class ActionEffectDiffCostTests: XCTestCase {

    private func writeExecution(content: String, preWrite: String?) -> ToolExecutionData {
        var data = ToolExecutionData(
            id: UUID(), name: "write_file",
            params: "{}", output: "Successfully wrote", isSuccess: true, isExecuting: false
        )
        let params = try! JSONSerialization.data(
            withJSONObject: ["path": "/Users/me/Project/Main.java", "content": content]
        )
        data.params = String(data: params, encoding: .utf8)!
        data.preWriteContent = preWrite
        return data
    }

    private func resetCounters() {
        DiffUtility.lineLevelDiffCallsForTesting = 0
        DiffUtility.refineIntraLineCallsForTesting = 0
    }

    /// THE pin: a changed write costs exactly ONE line-level pass and NO refinement.
    func testAChangedWriteCostsOneLinePassAndNoRefinement() throws {
        let before = (1...40).map { "line \($0)" }.joined(separator: "\n") + "\n"
        let after = before.replacingOccurrences(of: "line 3\n", with: "line three\n")
            .replacingOccurrences(of: "line 38\n", with: "line thirty-eight\n")
        resetCounters()

        let effect = try XCTUnwrap(ActionEffect.from(toolExecution: writeExecution(content: after, preWrite: before)))

        XCTAssertEqual(DiffUtility.lineLevelDiffCallsForTesting, 1,
                       "counts and diff text must come from ONE line-level pass — a second pass is the defect")
        XCTAssertEqual(DiffUtility.refineIntraLineCallsForTesting, 0,
                       "nothing here reads `segments`; the char-level refinement is pure waste on the main actor")
        // And the output is what the two-pass version produced.
        XCTAssertEqual(effect.linesAdded, 2)
        XCTAssertEqual(effect.linesRemoved, 2)
        XCTAssertTrue(effect.diff?.contains("-line 3\n") == true)
        XCTAssertTrue(effect.diff?.contains("+line three\n") == true)
        XCTAssertTrue(effect.diff?.contains("…") == true, "two distant hunks must be separated by an elision")
    }

    /// An identical rewrite exits at the counts guard — still one pass, and still nothing refined.
    func testAnIdenticalRewriteCostsOnePassAndNoRefinement() {
        let text = "a\nb\nc\n"
        resetCounters()

        XCTAssertNil(ActionEffect.from(toolExecution: writeExecution(content: text, preWrite: text)))

        XCTAssertEqual(DiffUtility.lineLevelDiffCallsForTesting, 1)
        XCTAssertEqual(DiffUtility.refineIntraLineCallsForTesting, 0)
    }

    /// The seam is live: `generateDiff` — the preview's path, which DOES render segments —
    /// still refines. Without this, a counter that never incremented would pass the pins above.
    func testGenerateDiffStillRefines() {
        resetCounters()

        _ = DiffUtility.generateDiff(original: "foo(a, b)\n", modified: "foo(x, y)\n")

        XCTAssertEqual(DiffUtility.lineLevelDiffCallsForTesting, 1)
        XCTAssertEqual(DiffUtility.refineIntraLineCallsForTesting, 1)
    }

    /// The rows overload and the string overload agree — the counts cannot drift from the rows.
    func testChangeCountsFromRowsMatchesTheStringOverload() {
        let before = "a\nb\nc\n", after = "a\nx\ny\nc\n"
        let rows = DiffUtility.lineLevelDiff(original: before, modified: after)
        let fromRows = DiffUtility.changeCounts(rows: rows)
        let fromStrings = DiffUtility.changeCounts(original: before, modified: after)
        XCTAssertEqual(fromRows.added, fromStrings.added)
        XCTAssertEqual(fromRows.deleted, fromStrings.deleted)
        XCTAssertEqual(fromRows.added, 2)
        XCTAssertEqual(fromRows.deleted, 1)
    }
}
