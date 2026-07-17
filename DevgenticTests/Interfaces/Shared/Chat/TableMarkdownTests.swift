//
//  TableMarkdownTests.swift
//  DevgenticTests
//
//  "Copy Table (Markdown)" used to emit markdown that wasn't a table any more:
//    - `|` inside a cell was never escaped, so one pipe split the cell in two
//    - the separator row was sized from `headers.count` while data rows used their own
//      length, so ragged input produced a separator that matched nothing
//    - a newline in a cell ended the row
//    - column alignment was dropped
//
//  The test that matters is the ROUND TRIP: paste it back and you must get the same table.
//

import XCTest
@testable import devgentic

final class TableMarkdownTests: XCTestCase {

    /// Re-parses serialized output through the app's own markdown parser.
    private func roundTrip(
        headers: [String], rows: [[String]], alignments: [ContentBlock.ColumnAlignment] = []
    ) -> (headers: [String], rows: [[String]], alignments: [ContentBlock.ColumnAlignment])? {
        let md = TableMarkdown.serialize(headers: headers, rows: rows, alignments: alignments)
        guard let block = parseMarkdown(md).first(where: { if case .table = $0.type { return true }; return false }),
              case .table(let h, let r, let a) = block.type else { return nil }
        return (h, r, a)
    }

    // MARK: - The round trip

    func testASimpleTableSurvivesTheRoundTrip() throws {
        let result = try XCTUnwrap(roundTrip(headers: ["File", "Purpose"],
                                             rows: [["a.swift", "parsing"], ["b.swift", "rendering"]]))
        XCTAssertEqual(result.headers, ["File", "Purpose"])
        XCTAssertEqual(result.rows, [["a.swift", "parsing"], ["b.swift", "rendering"]])
    }

    /// The headline bug: one `|` in a cell used to silently become a column break.
    func testCellsContainingPipesSurviveTheRoundTrip() throws {
        let result = try XCTUnwrap(roundTrip(headers: ["Expression", "Result"],
                                             rows: [["a | b", "true"], ["x || y", "false"]]))
        XCTAssertEqual(result.rows, [["a | b", "true"], ["x || y", "false"]],
                       "A pipe inside a cell must not split it")
        XCTAssertEqual(result.headers.count, 2, "The table must still have exactly 2 columns")
    }

    /// Alignment is part of the table; copying and pasting shouldn't quietly discard it.
    func testAlignmentSurvivesTheRoundTrip() throws {
        let result = try XCTUnwrap(roundTrip(headers: ["L", "C", "R"],
                                             rows: [["1", "2", "3"]],
                                             alignments: [.leading, .center, .trailing]))
        XCTAssertEqual(result.alignments, [.leading, .center, .trailing])
    }

    /// Ragged LLM output: a row longer than the header. The separator used to be sized
    /// from the header alone, so the result didn't parse as a table at all.
    func testRaggedRowsStillProduceAValidTable() throws {
        let result = try XCTUnwrap(roundTrip(headers: ["A", "B"],
                                             rows: [["1", "2", "3"], ["4"]]))
        XCTAssertEqual(result.headers.count, 3, "Column count comes from the widest row")
        XCTAssertEqual(result.rows.first?.count, 3)
        XCTAssertEqual(result.rows.last, ["4", "", ""], "Short rows pad rather than misalign")
    }

    // MARK: - Escaping

    func testPipesAndNewlinesAreEscaped() {
        XCTAssertEqual(TableMarkdown.escapeCell("a | b"), "a \\| b")
        XCTAssertEqual(TableMarkdown.escapeCell("one\ntwo"), "one<br>two", "GFM's only in-cell break")
        XCTAssertEqual(TableMarkdown.escapeCell("one\r\ntwo"), "one<br>two")
    }

    /// Escaping the escape character, or `\|` in a cell becomes an escaped pipe.
    func testBackslashesAreEscapedBeforePipes() {
        XCTAssertEqual(TableMarkdown.escapeCell("a \\ b"), "a \\\\ b")
        XCTAssertEqual(TableMarkdown.escapeCell("\\|"), "\\\\\\|")
    }

    func testOrdinaryTextIsUntouched() {
        XCTAssertEqual(TableMarkdown.escapeCell("plain text 42"), "plain text 42")
    }

    // MARK: - Shape

    /// The separator row is what makes it a table; it must match the header exactly.
    func testSeparatorMatchesTheColumnCount() {
        let md = TableMarkdown.serialize(headers: ["A", "B"], rows: [["1", "2", "3"]])
        let lines = md.components(separatedBy: "\n")
        let columns = { (line: String) in line.components(separatedBy: "|").count }
        XCTAssertEqual(columns(lines[0]), columns(lines[1]), "Separator must match the header row")
        XCTAssertEqual(columns(lines[1]), columns(lines[2]), "Separator must match the data rows")
    }

    func testEmptyTableSerializesToNothingRatherThanAStubbedRow() {
        XCTAssertEqual(TableMarkdown.serialize(headers: [], rows: []), "")
    }

    func testHeaderOnlyTableIsStillValid() throws {
        let result = try XCTUnwrap(roundTrip(headers: ["Only"], rows: []))
        XCTAssertEqual(result.headers, ["Only"])
        XCTAssertTrue(result.rows.isEmpty)
    }
}
