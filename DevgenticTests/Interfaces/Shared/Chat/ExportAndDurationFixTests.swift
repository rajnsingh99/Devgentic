// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
//
//  ExportAndDurationFixTests.swift
//  DevgenticTests
//
//  Created by Raj Singh.
//

import XCTest
@testable import devgentic

@MainActor
final class ExportAndDurationFixTests: XCTestCase {

    private func agentMessage(_ content: MessageContent) -> ChatMessage {
        ChatMessage(conversationId: UUID(), sender: .agent, content: content)
    }

    // MARK: - CH56 (fence escaping)

    /// A hardcoded ``` is closed by the first matching run INSIDE the content, so the rest of
    /// the block escapes into document structure. Reachable on the ordinary `.codeBlock` path,
    /// not only in the file-embedding branch: any answer that quotes a fence trips it.
    func testCodeBlockContainingAFenceIsNotBrokenByTheExport() async {
        let code = "before\n```\nstill inside\n```\nafter"
        let markdown = await ConversationExporter.toMarkdown(
            title: "T", messages: [agentMessage(.codeBlock(language: "markdown", code: code))]
        )

        // The whole body must survive intact inside one block.
        XCTAssertTrue(markdown.contains(code), "the code must be exported verbatim")
        // The opening fence must be longer than the longest run inside the content.
        XCTAssertTrue(markdown.contains("````markdown"),
                      "a 3-backtick run in the content requires at least a 4-backtick fence")
    }

    /// Control: ordinary code keeps the plain three-backtick fence.
    func testOrdinaryCodeBlockKeepsAThreeBacktickFence() async {
        let markdown = await ConversationExporter.toMarkdown(
            title: "T", messages: [agentMessage(.codeBlock(language: "swift", code: "let x = 1"))]
        )
        XCTAssertTrue(markdown.contains("```swift"))
        XCTAssertFalse(markdown.contains("````"), "no longer fence than necessary")
    }

    /// Nested runs longer than three must widen the fence further.
    func testFenceGrowsPastTheLongestRunInTheContent() async {
        let code = "a\n`````\nb"
        let markdown = await ConversationExporter.toMarkdown(
            title: "T", messages: [agentMessage(.codeBlock(language: nil, code: code))]
        )
        XCTAssertTrue(markdown.contains("``````"), "a 5-backtick run requires a 6-backtick fence")
    }

    // MARK: - CH59 (silent truncation)

    /// The export fetched the newest 10,000 messages against a newest-first sort, so hitting
    /// the cap dropped the conversation's EARLIEST turns — with no log and nothing in the file.
    func testTruncatedExportSaysSoInTheDocument() async {
        let markdown = await ConversationExporter.toMarkdown(
            title: "T", messages: [agentMessage(.plainText("hi"))], isTruncated: true
        )
        XCTAssertTrue(markdown.contains("most recent 1 messages"),
                      "a partial export must state that it is partial")
        XCTAssertTrue(markdown.contains("not included"))
    }

    /// Control: a complete export carries no notice.
    func testCompleteExportCarriesNoTruncationNotice() async {
        let markdown = await ConversationExporter.toMarkdown(
            title: "T", messages: [agentMessage(.plainText("hi"))]
        )
        XCTAssertFalse(markdown.contains("not included"))
    }

    // MARK: - CH58 (duration drift)

    /// Two helpers collapsed a zero remainder to "1m"; the third printed "1m 0s". They are
    /// consolidated in one file whose header says they were unified precisely because the
    /// copies had drifted.
    func testWholeMinutesRenderTheSameAcrossAllThreeHelpers() {
        XCTAssertEqual(DurationFormat.seconds(60), "1m")
        XCTAssertEqual(DurationFormat.milliseconds(60_000), "1m")
        XCTAssertEqual(DurationFormat.elapsed(from: Date(timeIntervalSince1970: 0),
                                              to: Date(timeIntervalSince1970: 60)), "1m")
    }

    func testPartialMinutesKeepSeconds() {
        XCTAssertEqual(DurationFormat.seconds(125), "2m 5s")
        XCTAssertEqual(DurationFormat.milliseconds(125_000), "2m 5s")
        XCTAssertEqual(DurationFormat.elapsed(from: Date(timeIntervalSince1970: 0),
                                              to: Date(timeIntervalSince1970: 125)), "2m 5s")
    }

    /// None of them rolled over to hours, so a long run read "90m 0s".
    func testHoursRollOver() {
        XCTAssertEqual(DurationFormat.seconds(3600), "1h")
        XCTAssertEqual(DurationFormat.seconds(5400), "1h 30m")
        XCTAssertEqual(DurationFormat.milliseconds(3_600_000), "1h")
        XCTAssertEqual(DurationFormat.elapsed(from: Date(timeIntervalSince1970: 0),
                                              to: Date(timeIntervalSince1970: 5400)), "1h 30m")
    }

    /// `elapsed` clamped negatives; `milliseconds` printed "-42ms" as though it were a real
    /// measurement.
    func testNegativeDurationsAreClamped() {
        XCTAssertEqual(DurationFormat.milliseconds(-42), "0ms")
        XCTAssertEqual(DurationFormat.elapsed(from: Date(timeIntervalSince1970: 60),
                                              to: Date(timeIntervalSince1970: 0)), "0s")
        XCTAssertEqual(DurationFormat.seconds(-1), "", "seconds keeps its documented empty form")
    }

    /// Sub-minute forms are unchanged — each helper keeps its own vocabulary below 60s.
    func testSubMinuteFormsAreUnchanged() {
        XCTAssertEqual(DurationFormat.milliseconds(820), "820ms")
        XCTAssertEqual(DurationFormat.milliseconds(3_400), "3.4s")
        XCTAssertEqual(DurationFormat.seconds(0.5), "<1s")
        XCTAssertEqual(DurationFormat.seconds(3.4), "3.4s")
        XCTAssertEqual(DurationFormat.elapsed(from: Date(timeIntervalSince1970: 0),
                                              to: Date(timeIntervalSince1970: 45)), "45s")
    }
}
