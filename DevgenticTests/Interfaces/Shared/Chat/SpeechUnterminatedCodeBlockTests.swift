// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2026 Raj Singh
//
//  SpeechUnterminatedCodeBlockTests.swift
//  DevgenticTests
//
//  [CF-20] `SpeechService.parseSegments` appended a `.codeBlock` from ONE place: the branch
//  that sees a CLOSING ``` fence. A response that ends inside a block — cancelled mid-stream,
//  or a model that never wrote the closing fence — therefore had its code lines dropped on the
//  floor after the loop, with no log, and `totalSegmentCount` short by one.
//
//  The bubble does not agree with that: the finalized render runs
//  `preprocessStreamResilientMarkdown`, which appends the missing fence, so the user is looking
//  at a code block Read Aloud behaves as though does not exist. These tests pin the repair, and
//  pin the agreement between the two parsers that the row is really about.
//

import XCTest
@testable import devgentic

@MainActor
final class SpeechUnterminatedCodeBlockTests: XCTestCase {

    // MARK: - The repair

    /// The row's case: prose, then a fence that never closes.
    func testTrailingUnterminatedCodeBlockStillBecomesASegment() {
        let markdown = """
        Here is how you do it:
        ```swift
        let x = 1
        print(x)
        """

        let segments = SpeechService.parseSegments(from: markdown)

        XCTAssertEqual(segments.count, 2, "Prose + the auto-closed block; before the fix this was 1 and the code was gone")
        guard case .text(let prose) = segments[0] else {
            return XCTFail("First segment must be the prose before the fence, got \(segments[0])")
        }
        XCTAssertTrue(prose.contains("Here is how you do it"), "Prose before the fence must survive, got '\(prose)'")

        guard case .codeBlock(let language, let code) = segments[1] else {
            return XCTFail("The unterminated block must still become a .codeBlock — it is what the bubble renders")
        }
        XCTAssertEqual(language, "swift", "The opening fence's language tag is still the block's language")
        XCTAssertEqual(code, "let x = 1\nprint(x)", "Every line after the fence belongs to the block")
    }

    /// A response that is nothing but an unterminated block — the shape a cancellation right
    /// after the fence produces. There is no prose to fall back on, so before the fix
    /// `parseSegments` returned an EMPTY array and `speak` bailed on its `guard !segments.isEmpty`:
    /// Read Aloud did nothing at all, silently.
    func testUnterminatedBlockWithNoProseStillYieldsOneSegment() {
        let markdown = """
        ```python
        print("hi")
        """

        let segments = SpeechService.parseSegments(from: markdown)

        XCTAssertEqual(segments.count, 1)
        guard case .codeBlock(let language, let code) = segments[0] else {
            return XCTFail("Expected a single .codeBlock, got \(segments[0])")
        }
        XCTAssertEqual(language, "python")
        XCTAssertEqual(code, "print(\"hi\")")
    }

    /// An unlabelled fence keeps working — the language is optional, not a precondition of the
    /// repair.
    func testUnterminatedBlockWithNoLanguageTagIsRepairedWithNilLanguage() {
        let segments = SpeechService.parseSegments(from: "Look:\n```\nsome code")

        XCTAssertEqual(segments.count, 2)
        guard case .codeBlock(let language, let code) = segments[1] else {
            return XCTFail("Expected a .codeBlock, got \(segments[1])")
        }
        XCTAssertNil(language)
        XCTAssertEqual(code, "some code")
    }

    // MARK: - What the repair must NOT do

    /// An opened fence with nothing after it carries nothing to announce or show. The prose
    /// BEFORE it must still be spoken rather than lost with it — the fall-through case in the
    /// repair, and the one a "just always append" version would get wrong by adding an empty
    /// code segment (which then speaks an announcement for nothing and opens a blank viewer).
    func testEmptyUnterminatedBlockKeepsTheProseAndAddsNoCodeSegment() {
        let segments = SpeechService.parseSegments(from: "All done.\n```swift\n")

        XCTAssertEqual(segments.count, 1)
        guard case .text(let prose) = segments[0] else {
            return XCTFail("Expected only the prose, got \(segments[0])")
        }
        XCTAssertTrue(prose.contains("All done."))
    }

    /// Control: a properly closed block is unchanged by the repair. If this breaks, the fix
    /// has moved the normal path, not just the tail.
    func testTerminatedBlockIsUnaffected() {
        let segments = SpeechService.parseSegments(from: "Intro\n```swift\nlet x = 1\n```\nOutro")

        XCTAssertEqual(segments.count, 3)
        guard case .text = segments[0], case .codeBlock(let language, let code) = segments[1],
              case .text(let outro) = segments[2] else {
            return XCTFail("Expected text / codeBlock / text, got \(segments)")
        }
        XCTAssertEqual(language, "swift")
        XCTAssertEqual(code, "let x = 1")
        XCTAssertTrue(outro.contains("Outro"))
    }

    // MARK: - Agreement with what the user is looking at

    /// The row's actual complaint: the reader and the renderer disagreed about whether a code
    /// block was there. `preprocessStreamResilientMarkdown` is what the finalized bubble runs,
    /// and it closes the dangling fence — so parsing the raw text and parsing the repaired text
    /// must now produce the SAME segments. Before the fix the raw text yielded one fewer.
    func testSpeechSegmentsAgreeWithTheRenderersFenceRepair() {
        let raw = "Here you go:\n```swift\nlet x = 1\n"

        let fromRaw = SpeechService.parseSegments(from: raw)
        let fromRendered = SpeechService.parseSegments(from: preprocessStreamResilientMarkdown(raw))

        XCTAssertEqual(fromRaw, fromRendered,
                       "Read Aloud must describe the same response the bubble shows; the renderer closes the fence, so the reader has to as well")
        XCTAssertEqual(fromRaw.count, 2)
    }

    /// The legacy `stripCodeBlocks` helper reads through `parseSegments`, so the repair reaches
    /// it too: an unterminated block is now spoken as a marker instead of vanishing.
    func testStripCodeBlocksMarksTheUnterminatedBlock() {
        let stripped = SpeechService.stripCodeBlocks(from: "Intro\n```swift\nlet x = 1\n")

        XCTAssertTrue(stripped.contains("Intro"))
        XCTAssertTrue(stripped.contains("Code block."), "Got '\(stripped)'")
    }
}
