// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
//
//  SourceFidelityTests.swift
//  DevgenticTests
//
//  Created by Raj Singh.
//

import XCTest
@testable import devgentic

final class SourceFidelityTests: XCTestCase {

    // MARK: - Smart punctuation stays off

    /// The RAG-index bug, exactly as observed: the model emitted straight quotes and the
    /// embedding logs showed `print(“ALPHA 1”)`.
    func testQuotesInProseStayStraight() {
        let blocks = parseMarkdown("The output was print(\"ALPHA 1\") as expected.")
        let text = blocks.first?.plainText ?? ""
        XCTAssertTrue(text.contains("print(\"ALPHA 1\")"), "Got: \(text)")
        XCTAssertFalse(text.contains("\u{201C}") || text.contains("\u{201D}"),
                       "Curly quotes must not be introduced by parsing: \(text)")
    }

    /// `--save-dev` → `—save-dev` was the dash half of the corruption.
    func testDoubleDashesInProseStayLiteral() {
        let text = parseMarkdown("Run npm install --save-dev to add it.").first?.plainText ?? ""
        XCTAssertTrue(text.contains("--save-dev"), "Got: \(text)")
        XCTAssertFalse(text.contains("\u{2014}"), "Em dash must not be introduced: \(text)")
    }

    func testEllipsesStayAsThreeDots() {
        let text = parseMarkdown("Loading... done.").first?.plainText ?? ""
        XCTAssertTrue(text.contains("..."), "Got: \(text)")
        XCTAssertFalse(text.contains("\u{2026}"), "Typographic ellipsis must not be introduced: \(text)")
    }

    /// The streaming parser has its own two `Document(parsing:)` calls; a fix at only the
    /// full-parse site would leave streamed text curled until the completion heal.
    func testStreamingParserAlsoKeepsStraightQuotes() {
        let parser = StreamingMarkdownParser()
        let blocks = parser.parse("First paragraph with \"quoted\" text.\n\nSecond paragraph --flag.\n\nThird.")
        let all = blocks.map(\.plainText).joined(separator: " ")
        XCTAssertTrue(all.contains("\"quoted\""), "Got: \(all)")
        XCTAssertTrue(all.contains("--flag"), "Got: \(all)")
    }

    // MARK: - File marker: both eras must keep working

    /// New era: with smart opts off the marker arrives as LITERAL dashes.
    func testLiteralDashMarkerStillAttachesFilename() {
        let snippets = CodeSnippetExtractor.extract(from: "--- Start of file: main.swift ---\n\n```swift\nprint(1)\n```")
        XCTAssertEqual(snippets.first?.potentialFileName, "main.swift")
    }

    /// Legacy era: messages persisted while smart punctuation (or the composer's smart
    /// dashes) was rewriting `---` carry a real em dash. Dropping that branch would
    /// orphan their filename badges.
    func testLegacyEmDashMarkerStillAttachesFilename() {
        let snippets = CodeSnippetExtractor.extract(from: "\u{2014} Start of file: legacy.swift \u{2014}\n\n```swift\nprint(1)\n```")
        XCTAssertEqual(snippets.first?.potentialFileName, "legacy.swift")
    }

    // MARK: - Outcome label

    /// The bug: every clean bot run printed PARTIAL because it called no tools.
    func testCompletedIsSuccessRegardlessOfToolCount() {
        XCTAssertEqual(
            EvaluationLogger.outcomeLabel(reported: ExecutionOutcome.completed.rawValue,
                                          didFinishSuccessfully: true),
            "SUCCESS ✅"
        )
    }

    /// PARTIAL survives for what it actually means: the executor itself reported
    /// degraded success.
    func testPartialIsReservedForCompletedWithWarnings() {
        XCTAssertEqual(
            EvaluationLogger.outcomeLabel(reported: ExecutionOutcome.completedWithWarnings.rawValue,
                                          didFinishSuccessfully: true),
            "PARTIAL ⚠️"
        )
    }

    func testFailedAndCancelledMapDirectly() {
        XCTAssertEqual(EvaluationLogger.outcomeLabel(reported: ExecutionOutcome.failed.rawValue,
                                                     didFinishSuccessfully: false), "FAIL ❌")
        XCTAssertEqual(EvaluationLogger.outcomeLabel(reported: ExecutionOutcome.cancelled.rawValue,
                                                     didFinishSuccessfully: false), "CANCELLED 🚫")
    }

    /// Legacy executors that report nothing: finishing is success, not PARTIAL.
    func testLegacyPathNoLongerDowngradesZeroToolRuns() {
        XCTAssertEqual(EvaluationLogger.outcomeLabel(reported: nil, didFinishSuccessfully: true), "SUCCESS ✅")
        XCTAssertEqual(EvaluationLogger.outcomeLabel(reported: nil, didFinishSuccessfully: false), "FAIL ❌")
    }
}
