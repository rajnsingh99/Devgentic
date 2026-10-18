// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
//
//  StreamingFenceBoundaryTests.swift
//  DevgenticTests
//
//  Created by Raj Singh.
//

import XCTest
@testable import devgentic

final class StreamingFenceBoundaryTests: XCTestCase {

    private func settled(_ text: String) -> String? {
        let tail = text[text.startIndex...]
        guard let cut = StreamingMarkdownParser.lastSafeBoundary(in: tail) else { return nil }
        return String(tail[tail.startIndex..<cut])
    }

    // MARK: - The fence rule

    func testFenceMarkerReportsRunLengthAndInfoString() {
        XCTAssertEqual(markdownFenceMarker(inTrimmedLine: "```")?.run, 3)
        XCTAssertEqual(markdownFenceMarker(inTrimmedLine: "````")?.run, 4)
        XCTAssertEqual(markdownFenceMarker(inTrimmedLine: "```swift")?.run, 3)
        XCTAssertEqual(markdownFenceMarker(inTrimmedLine: "```")?.hasInfo, false)
        XCTAssertEqual(markdownFenceMarker(inTrimmedLine: "```swift")?.hasInfo, true)
        XCTAssertNil(markdownFenceMarker(inTrimmedLine: "``"), "two backticks is an inline span, not a fence")
        XCTAssertNil(markdownFenceMarker(inTrimmedLine: "let x = `a`"))
        XCTAssertNil(markdownFenceMarker(inTrimmedLine: ""))
    }

    // MARK: - Nested fences (the serious half)

    /// ⚠️ THE pin. A model showing you markdown writes ````` ````markdown ````` around an inner
    /// ```` ```swift ```` fence. The old boolean toggle read that inner fence as a CLOSE, so the
    /// blank line inside the outer block looked like a safe boundary and the settled region was
    /// cut mid-fence — cmark then swallowed it as one unterminated code block and the remaining
    /// code lines rendered as prose, for the rest of the stream.
    func testABlankLineInsideAnOuterFenceIsNotABoundary() {
        let text = "intro\n\n````markdown\n```swift\nlet a = 1\n\nlet b = 2"

        let cut = settled(text)

        XCTAssertEqual(cut, "intro\n\n")
        XCTAssertFalse(cut?.contains("let a = 1") ?? false,
                       "the settled region must not reach inside the ````` ```` ````` block")
    }

    /// An equal-or-longer BARE run does close it, so a completed outer block settles normally.
    func testAnEqualLengthBareRunClosesTheOuterFence() {
        let text = "intro\n\n````markdown\n```swift\nlet a = 1\n```\n````\n\nafter\n\nmore"

        let cut = settled(text)

        XCTAssertNotNil(cut)
        XCTAssertTrue(cut?.contains("````\n\n") ?? false, "the outer block is closed and settles")
        XCTAssertTrue(cut?.contains("after") ?? false)
    }

    /// A run with an info string cannot close — CommonMark's rule, and the reason the inner
    /// ```` ```swift ```` above is content rather than a terminator.
    func testARunWithAnInfoStringDoesNotClose() {
        XCTAssertNil(settled("```swift\nlet a = 1\n\nlet b = 2\n```swift\n\nafter\n"),
                     "nothing outside a fence has closed, so nothing can settle")
    }

    // MARK: - Line endings

    /// ⚠️ `"\r\n"` is ONE Swift Character, so `firstIndex(of: "\n")` found NOTHING in an
    /// all-CRLF tail: the whole tail read as a single line, no boundary was ever returned, and
    /// the streaming parser silently degraded to a full re-parse per flush. The render stayed
    /// correct, which is why it could sit there unnoticed.
    func testACRLFTailStillSettles() {
        XCTAssertEqual(settled("a\r\nb\r\n\r\nc\r\n"), "a\r\nb\r\n\r\n")
        XCTAssertEqual(settled("a\nb\n\nc\n"), "a\nb\n\n", "LF is unchanged")
    }

    /// The mixed-endings shape that produced a genuinely WRONG cut: a CRLF line immediately
    /// before an opening fence. The scanner missed the line break, so the fence line was never
    /// seen as a fence at all and the blank line INSIDE it was accepted as a boundary — the old
    /// result was `"intro\r\n```\nlet a = 1\n\n"`, cut mid-fence.
    func testACRLFLineBeforeAFenceDoesNotCutInsideIt() {
        // Unclosed: there is no boundary after the opener at all.
        XCTAssertEqual(settled("intro\r\n```\nlet a = 1\n\nlet b = 2"), nil)

        // Closed: the cut lands after the COMPLETE fence, never inside it.
        XCTAssertEqual(settled("intro\r\n```\nlet a = 1\n\nlet b = 2\n```\n\nafter\n"),
                       "intro\r\n```\nlet a = 1\n\nlet b = 2\n```\n\n")
    }

    func testATailWithNoBlankLineHasNoBoundary() {
        XCTAssertNil(settled("just one line"))
        XCTAssertNil(settled("a\nb\nc\n"))
    }

    // MARK: - The two stages agree

    /// The boundary scanner and the stream preprocessor must decide "is a fence open?" the same
    /// way. They did not: the scanner split lines with `firstIndex(of: "\n")` and the
    /// preprocessor with `components(separatedBy: .newlines)`, which disagree on CRLF — while a
    /// doc comment on the scanner claimed the two "can't disagree about what's inside a fence".
    func testTheStreamPreprocessorClosesWithTheOpeningRunLength() {
        XCTAssertEqual(preprocessStreamResilientMarkdown("````markdown\n```swift\nlet a = 1"),
                       "````markdown\n```swift\nlet a = 1\n````\n",
                       "a hard-coded ``` cannot close a ```` block — the old closer left it open")
        XCTAssertEqual(preprocessStreamResilientMarkdown("```swift\nlet a = 1"),
                       "```swift\nlet a = 1\n```\n")
    }

    func testTheStreamPreprocessorLeavesBalancedTextAlone() {
        let balanced = "````markdown\n```swift\nlet a = 1\n```\n````\n"
        XCTAssertEqual(preprocessStreamResilientMarkdown(balanced), balanced)
        XCTAssertEqual(preprocessStreamResilientMarkdown("no fences here"), "no fences here")
    }

    /// ⚠️ THE INVARIANT the whole row rests on, stated directly: **a settled region is always
    /// balanced.** It is parsed with `Document(parsing:)` and NO stream preprocessor, on the
    /// strength of a comment claiming fences inside it are "balanced by construction" — so a cut
    /// that leaves a fence open hands cmark an unterminated code block and locks the result in
    /// permanently. Asserted by running the preprocessor over the settled prefix: if it wants to
    /// append a closer, the prefix was not balanced.
    func testEverySettledRegionIsBalanced() {
        let streams = [
            "intro\n\n````markdown\n```swift\nlet a = 1\n\nlet b = 2",
            "intro\n\n````markdown\n```swift\nlet a = 1\n```\n````\n\nafter\n\nmore",
            "intro\r\n```\nlet a = 1\n\nlet b = 2\n```\n\nafter\n",
            "a\r\nb\r\n\r\nc\r\n",
            "one\n\n```\ncode\n```\n\ntail",
            "```swift\ncode\n```swift\nmore\n\ntail",
            "prose\n\n``````\nsix\n\nbackticks",
        ]
        for text in streams {
            guard let prefix = settled(text) else { continue }
            XCTAssertEqual(preprocessStreamResilientMarkdown(prefix), prefix,
                           "settled region of \(text.debugDescription) is NOT balanced: \(prefix.debugDescription)")
        }
    }

    // MARK: - Nothing else moved

    /// A plain stream settles exactly where it always did — the block ids downstream are
    /// positional, so a moved boundary changes which blocks lock in.
    func testAnOrdinaryStreamSettlesAtTheLastBlankLine() {
        XCTAssertEqual(settled("one\n\ntwo\n\nthree"), "one\n\ntwo\n\n")
        XCTAssertEqual(settled("one\n\n```\ncode\n```\n\ntail"), "one\n\n```\ncode\n```\n\n")
    }
}
