// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
//
//  ChatAccessibilitySemanticsTests.swift
//  DevgenticTests
//
//  What VoiceOver is TOLD, for the parts that are pure logic.
//
//  Scope is deliberate: a SwiftUI `.accessibilityLabel` / `.accessibilityHeading` cannot be
//  read back from a hosted view — measured, not assumed (hosting a view and walking
//  `accessibilityChildren()` returns `[]`; the tree is built lazily when a real assistive
//  client attaches). So these tests pin the STRINGS and LEVELS we hand to the modifiers.
//  That the modifiers are attached to the right views still needs VoiceOver (⌘F5).
//

import XCTest
import SwiftUI
@testable import devgentic

final class ChatAccessibilitySemanticsTests: XCTestCase {

    // MARK: - Headings

    /// The rotor navigates by LEVEL. `fontForHeading` collapses h3–h6 into one size, so the
    /// spoken level is the only place the real document structure survives.
    func testHeadingLevelsMapToTheirTrueLevelNotTheFontBucket() {
        XCTAssertEqual(ContentBlockView.headingLevel(1), .h1)
        XCTAssertEqual(ContentBlockView.headingLevel(2), .h2)
        XCTAssertEqual(ContentBlockView.headingLevel(3), .h3)
        XCTAssertEqual(ContentBlockView.headingLevel(4), .h4)
        XCTAssertEqual(ContentBlockView.headingLevel(5), .h5)
        XCTAssertEqual(ContentBlockView.headingLevel(6), .h6)
    }

    func testOutOfRangeHeadingLevelIsUnspecifiedRatherThanWrong() {
        XCTAssertEqual(ContentBlockView.headingLevel(0), .unspecified)
        XCTAssertEqual(ContentBlockView.headingLevel(7), .unspecified)
        XCTAssertEqual(ContentBlockView.headingLevel(-1), .unspecified)
    }

    /// The mapping is worthless if the parser doesn't produce distinct levels.
    func testParserProducesTheHeadingLevelsTheMappingExpects() {
        let blocks = parseMarkdown("# One\n\n## Two\n\n#### Four")
        let levels = blocks.compactMap { block -> Int? in
            guard case .heading(let level, _) = block.type else { return nil }
            return level
        }
        XCTAssertEqual(levels, [1, 2, 4])
    }

    // MARK: - Tables

    func testTableSummaryDescribesShapeAndColumns() {
        let summary = TableSpeech.tableSummary(
            rowCount: 12, columnCount: 2, headers: ["File", "Purpose"], truncatedTo: nil
        )
        XCTAssertEqual(summary, "Table, 12 rows, 2 columns. Columns: File, Purpose")
    }

    func testTableSummaryUsesSingularForOneRowAndColumn() {
        XCTAssertTrue(
            TableSpeech.tableSummary(rowCount: 1, columnCount: 1, headers: [], truncatedTo: nil)
                .hasPrefix("Table, 1 row, 1 column")
        )
    }

    /// The renderer caps at 50 rows; VoiceOver must be told it's seeing a subset, or "12 of
    /// 200" rows reads as the whole table.
    func testTableSummarySaysWhenRowsAreTruncated() {
        let summary = TableSpeech.tableSummary(
            rowCount: 200, columnCount: 1, headers: ["File"], truncatedTo: 50
        )
        XCTAssertTrue(summary.contains("Showing first 50"), summary)
    }

    func testTableSummaryOmitsTruncationNoteWhenEverythingFits() {
        let summary = TableSpeech.tableSummary(
            rowCount: 3, columnCount: 1, headers: ["File"], truncatedTo: 50
        )
        XCTAssertFalse(summary.contains("Showing first"), summary)
    }

    /// Ragged LLM tables pad with "" — an unnamed column shouldn't be announced as one.
    func testTableSummarySkipsEmptyHeaders() {
        let summary = TableSpeech.tableSummary(
            rowCount: 1, columnCount: 3, headers: ["File", "", "  "], truncatedTo: nil
        )
        XCTAssertEqual(summary, "Table, 1 row, 3 columns. Columns: File")
    }

    /// The whole point of cell labels: a value alone is meaningless.
    func testCellLabelLeadsWithItsColumn() {
        XCTAssertEqual(TableSpeech.cellLabel(value: "failed", header: "Status"), "Status, failed")
        XCTAssertEqual(TableSpeech.cellLabel(value: "42", header: "Count"), "Count, 42")
    }

    /// Silence is indistinguishable from a bug — an empty cell must say so.
    func testEmptyCellSaysEmpty() {
        XCTAssertEqual(TableSpeech.cellLabel(value: "", header: "Notes"), "Notes, empty")
        XCTAssertEqual(TableSpeech.cellLabel(value: "   ", header: "Notes"), "Notes, empty")
        XCTAssertEqual(TableSpeech.cellLabel(value: "", header: ""), "empty")
    }

    func testCellWithoutAColumnNameJustSaysItsValue() {
        XCTAssertEqual(TableSpeech.cellLabel(value: "orphan", header: ""), "orphan")
    }

    func testHeaderCellsAnnounceThemselvesAsHeaders() {
        XCTAssertEqual(TableSpeech.headerCellLabel(value: "Purpose"), "Purpose, column header")
        XCTAssertEqual(TableSpeech.headerCellLabel(value: ""), "Unnamed column")
    }

    /// 1-based: "Row 0 of 12" is not a thing a person says.
    func testRowLabelIsOneBased() {
        XCTAssertEqual(TableSpeech.rowLabel(index: 0, of: 12), "Row 1 of 12")
        XCTAssertEqual(TableSpeech.rowLabel(index: 11, of: 12), "Row 12 of 12")
    }

    // MARK: - Table column alignment

    /// cmark parsed `:--` / `:-:` / `--:` all along and the parser dropped it, so an
    /// author's right-aligned numeric column rendered left like everything else.
    func testTableColumnAlignmentsAreParsed() {
        let md = """
        | Left | Center | Right |
        | :--- | :----: | ----: |
        | a    | b      | 42    |
        """
        guard let block = parseMarkdown(md).first,
              case .table(_, _, let alignments) = block.type else {
            return XCTFail("No table parsed")
        }
        XCTAssertEqual(alignments, [.leading, .center, .trailing])
    }

    /// An unspecified column (`---`, no colons) is leading in GFM.
    func testUnspecifiedColumnsDefaultToLeading() {
        let md = """
        | A | B |
        | --- | ---: |
        | x | 1 |
        """
        guard let block = parseMarkdown(md).first,
              case .table(_, _, let alignments) = block.type else {
            return XCTFail("No table parsed")
        }
        XCTAssertEqual(alignments, [.leading, .trailing])
    }

    /// Alignment is presentation only — it must not leak into RAG text or previews.
    func testAlignmentDoesNotAffectPlainTextFlattening() {
        let md = "| A | B |\n| ---: | :--- |\n| 1 | x |"
        XCTAssertEqual(parseMarkdown(md).first?.plainText, "A | B\n1 | x")
    }

    // MARK: - Workflow run cards

    private func makeRun(
        status: WorkflowRunRecord.RunStatus = .completed,
        duration: TimeInterval = 12.4,
        userInput: String = "",
        finalOutput: String = "",
        error: String? = nil
    ) -> WorkflowRunRecord {
        WorkflowRunRecord(
            id: UUID(),
            conversationID: UUID(),
            workflowProfileID: UUID(),
            workflowName: "Test",
            timestamp: Date(timeIntervalSince1970: 0),
            userInput: userInput,
            nodeResults: [],
            finalOutput: finalOutput,
            variables: [:],
            status: status,
            duration: duration,
            error: error
        )
    }

    /// The card used to read as a pile of fragments; the fix is one ordered sentence.
    func testRunCardReadsAsOneOrderedSentence() {
        let label = RunCardSpeech.label(
            for: makeRun(status: .failed, userInput: "Summarize the docs", error: "Timed out"),
            totalNodes: 3, failedNodes: 2
        )
        XCTAssertTrue(label.hasPrefix("Failed, "), label)
        XCTAssertTrue(label.contains("Input: Summarize the docs"), label)
        XCTAssertTrue(label.contains("Error: Timed out"), label)
        XCTAssertTrue(label.contains("3 nodes, 2 failed"), label)
    }

    /// A running run's elapsed time is stale the moment it's spoken, and re-announcing it
    /// every second would make the list unusable — the start time is stable and useful.
    func testRunningCardSaysWhenItStartedRatherThanATickingElapsed() {
        let label = RunCardSpeech.label(for: makeRun(status: .running), totalNodes: 1, failedNodes: 0)
        XCTAssertTrue(label.hasPrefix("Running since "), label)
        XCTAssertFalse(label.contains("12.4"), "A ticking duration must not be baked into the label: \(label)")
    }

    /// The card shows an error OR an output, never both.
    func testErrorWinsOverOutput() {
        let label = RunCardSpeech.label(
            for: makeRun(status: .failed, finalOutput: "partial result", error: "Boom"),
            totalNodes: 1, failedNodes: 1
        )
        XCTAssertTrue(label.contains("Error: Boom"), label)
        XCTAssertFalse(label.contains("partial result"), label)
    }

    func testEmptySectionsAreOmittedNotSpokenAsEmpty() {
        let label = RunCardSpeech.label(for: makeRun(), totalNodes: 1, failedNodes: 0)
        XCTAssertFalse(label.contains("Input:"), label)
        XCTAssertFalse(label.contains("Output:"), label)
        XCTAssertFalse(label.contains("Error:"), label)
        XCTAssertTrue(label.hasSuffix("1 node"), "Singular, and no trailing failure count: \(label)")
    }

    /// Reading a multi-kilobyte output aloud for one row of a list is its own failure.
    func testLongPreviewsAreTruncatedLikeTheCardIs() {
        let long = String(repeating: "x", count: 500)
        let preview = RunCardSpeech.spokenPreview(long)
        XCTAssertEqual(preview.count, 121, "120 chars plus the ellipsis")
        XCTAssertTrue(preview.hasSuffix("…"))
    }

    /// Newlines would otherwise be read as pauses mid-sentence.
    func testPreviewsAreFlattenedToOneLine() {
        XCTAssertEqual(RunCardSpeech.spokenPreview("line one\nline two"), "line one line two")
    }

    func testShortPreviewsArePassedThroughUntouched() {
        XCTAssertEqual(RunCardSpeech.spokenPreview("  short  "), "short")
    }
}
