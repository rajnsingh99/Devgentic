// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2026 Raj Singh
//
//  TimelineRowDetailTests.swift
//  DevgenticTests
//
//  Field-reported 2026-07-27: a write row's diff was permanently visible and its chevron
//  did nothing, while a read row expanded and collapsed correctly.
//
//  Cause: `ActionDetailView` asked THREE different questions about the same row. The chevron
//  and the tap target keyed on `data.output`; the body keyed on `data.effect`. A write has
//  both, so the body rendered its diff unconditionally and the chevron toggled a flag nothing
//  read. `TimelineRowDetail.resolve` is now the single answer all three consume — these tests
//  pin the answer for every row shape, so the three can never drift apart again.
//

import XCTest
@testable import devgentic

final class TimelineRowDetailTests: XCTestCase {

    // MARK: - Fixtures

    private func effect(diff: String?, added: Int = 3, removed: Int = 1) -> ActionEffect {
        ActionEffect(
            path: "/Users/me/Shape.java",
            linesAdded: added,
            linesRemoved: removed,
            diff: diff,
            isTruncated: false
        )
    }

    private func row(name: String = "write_file",
                     output: String?,
                     effect: ActionEffect? = nil,
                     isExecuting: Bool = false,
                     isSuccess: Bool? = true) -> ToolExecutionData {
        ToolExecutionData(
            id: UUID(),
            name: name,
            params: "{}",
            output: output,
            isSuccess: isSuccess,
            isExecuting: isExecuting,
            effect: effect
        )
    }

    private func assertDiff(_ detail: TimelineRowDetail?,
                            _ message: String,
                            file: StaticString = #filePath, line: UInt = #line) {
        guard case .diff? = detail else {
            return XCTFail("Expected .diff — \(message)", file: file, line: line)
        }
    }

    private func assertOutput(_ detail: TimelineRowDetail?,
                              _ expected: String,
                              _ message: String,
                              file: StaticString = #filePath, line: UInt = #line) {
        guard case .output(let out)? = detail else {
            return XCTFail("Expected .output — \(message)", file: file, line: line)
        }
        XCTAssertEqual(out, expected, message, file: file, line: line)
    }

    // MARK: - The reported defect

    /// THE FIELD CASE. A successful write has BOTH an effect and "Successfully wrote to X".
    /// The diff must win — but as a resolved detail the chevron can toggle, not as an
    /// unconditional branch in the body.
    func testWriteRowResolvesToItsDiffNotItsRedundantOutput() {
        let detail = TimelineRowDetail.resolve(
            row(output: "Successfully wrote to /Users/me/Shape.java", effect: effect(diff: "+ new line"))
        )
        assertDiff(detail, "the diff is the write's real output")
    }

    /// The whole point of routing all three call sites through one value: a row that resolves
    /// to a detail is expandable, and one that doesn't is inert. There is no third state where
    /// a chevron shows but the body has nothing, or a body shows with no chevron.
    func testExpandableRowsAndInertRowsAreExactlyTheOnesWithADetail() {
        // Expandable
        XCTAssertNotNil(TimelineRowDetail.resolve(row(name: "read_file", output: "file contents")))
        XCTAssertNotNil(TimelineRowDetail.resolve(row(output: "ok", effect: effect(diff: "+ x"))))
        // Inert — nothing to reveal, so no chevron and no tap.
        XCTAssertNil(TimelineRowDetail.resolve(row(output: nil)))
        XCTAssertNil(TimelineRowDetail.resolve(row(output: "")))
    }

    /// The MIRROR of the reported bug. An effect with no output string used to render a diff
    /// under no chevron at all — visible with no way to collapse it. It must be expandable.
    func testEffectWithNoOutputIsStillExpandable() {
        assertDiff(
            TimelineRowDetail.resolve(row(output: nil, effect: effect(diff: "+ new line"))),
            "a diff with no output string still needs a chevron"
        )
        assertDiff(
            TimelineRowDetail.resolve(row(output: "", effect: effect(diff: "+ new line"))),
            "an empty output string must not suppress the diff"
        )
    }

    // MARK: - Fall-through cases

    /// A no-op write has an effect but no diff to show. It falls through to its output rather
    /// than resolving to an empty diff box — "No changes" is already on the chip.
    func testNoOpWriteFallsThroughToItsOutput() {
        assertOutput(
            TimelineRowDetail.resolve(
                row(output: "Successfully wrote to /Users/me/Shape.java",
                    effect: effect(diff: nil, added: 0, removed: 0))
            ),
            "Successfully wrote to /Users/me/Shape.java",
            "a 0/0 write has no diff to disclose"
        )
    }

    /// An effect whose diff could not be reconstructed (no pre-write snapshot) must not
    /// swallow the output — that would leave the row looking empty when expanded.
    func testEffectWithoutADiffDoesNotSwallowTheOutput() {
        assertOutput(
            TimelineRowDetail.resolve(row(output: "wrote 40 lines", effect: effect(diff: nil))),
            "wrote 40 lines",
            "a nil diff falls back rather than resolving to nothing"
        )
    }

    /// A read row is the reference behaviour the user compared against — it must be unchanged.
    func testReadRowResolvesToItsContent() {
        assertOutput(
            TimelineRowDetail.resolve(row(name: "read_file", output: "public class Shape {}")),
            "public class Shape {}",
            "reads disclose what they read"
        )
    }

    /// A failed write still has an error to show. Suppressing it would hide the only
    /// explanation of what went wrong.
    func testFailedRowStillDisclosesItsError() {
        assertOutput(
            TimelineRowDetail.resolve(
                row(output: "Error: permission denied", effect: nil, isSuccess: false)
            ),
            "Error: permission denied",
            "failures must stay readable"
        )
    }

    // MARK: - Partial failures riding alongside the diff

    /// `edit_code_batch` writes the file when even ONE edit lands, and reports the rest as
    /// "Applied 1/3 edit(s)…\nErrors:\n…" — which `isSemanticFailure` classifies as SUCCESS.
    /// The row therefore gets a real diff, and letting the diff displace that output hid the
    /// only report of the two edits that never applied. Found by the 2026-07-27 audit.
    func testPartiallyFailedBatchKeepsItsErrorListAlongsideTheDiff() {
        let output = """
        Applied 1/3 edit(s) to /Users/me/Shape.java.
        Errors:
        Edit 2: no match for "public double area()"
        Edit 3: ambiguous match (4 occurrences)
        """
        guard case .diff(_, let note)? = TimelineRowDetail.resolve(
            row(name: "edit_code_batch", output: output, effect: effect(diff: "+ changed"))
        ) else {
            return XCTFail("A partial batch still has a diff to show")
        }
        let note1 = try? XCTUnwrap(note)
        XCTAssertTrue(note1?.contains("Edit 2") ?? false, "the failed edits must remain visible")
        XCTAssertTrue(note1?.contains("Applied 1/3") ?? false, "…as must the count that flags it partial")
    }

    /// The common case must stay clean: a one-line success string carries nothing the diff
    /// doesn't already say, so it is dropped rather than printed under every write.
    func testOrdinaryWriteCarriesNoRedundantNote() {
        guard case .diff(_, let note)? = TimelineRowDetail.resolve(
            row(output: "Successfully wrote to /Users/me/Shape.java", effect: effect(diff: "+ a"))
        ) else {
            return XCTFail("Expected .diff")
        }
        XCTAssertNil(note, "\"Successfully wrote to X\" only restates the row header")
    }

    /// Trailing newlines are whitespace, not a second line — a success string that happens to
    /// end in "\n" must not be mistaken for a partial-failure report.
    func testTrailingNewlineDoesNotCountAsMultiLine() {
        guard case .diff(_, let note)? = TimelineRowDetail.resolve(
            row(output: "Created file 'Shape.java' (40 lines, 812 chars).\n\n",
                effect: effect(diff: "+ a"))
        ) else {
            return XCTFail("Expected .diff")
        }
        XCTAssertNil(note, "surrounding whitespace is not content")
    }

    // MARK: - Lifecycle

    /// A row is executing (no output yet) and then completes. Resolution is derived from the
    /// data each render, not latched, so the detail appears as soon as the output does —
    /// the chevron's `!isExecuting` gate handles the in-flight half.
    func testDetailAppearsWhenAnExecutingRowCompletes() {
        XCTAssertNil(TimelineRowDetail.resolve(row(output: nil, isExecuting: true, isSuccess: nil)),
                     "nothing to disclose while it runs")
        assertDiff(
            TimelineRowDetail.resolve(row(output: "Successfully wrote", effect: effect(diff: "+ a"))),
            "the completed row discloses its diff"
        )
    }
}
