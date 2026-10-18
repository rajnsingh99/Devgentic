// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
//
//  SpeechLiveSettingsTests.swift
//  DevgenticTests
//
//  Created by Raj Singh.
//

import XCTest
@testable import devgentic

final class SpeechLiveSettingsTests: XCTestCase {

    // MARK: - Boundaries

    /// Nothing has been spoken yet — no word boundary has been reported — so a setting change
    /// must restart the whole utterance, not silently drop it.
    func testOffsetZeroReturnsTheWholeText() {
        XCTAssertEqual(SpeechService.remainder(of: "Hello there", spokenUpTo: 0), "Hello there")
    }

    /// Defensive: AVFoundation reporting a nonsense offset must not crash or truncate wrongly.
    func testNegativeOffsetReturnsTheWholeText() {
        XCTAssertEqual(SpeechService.remainder(of: "Hello there", spokenUpTo: -5), "Hello there")
    }

    /// Mid-utterance is the case the row was filed for: the user hits 2× halfway through a long
    /// answer and must hear the REST at the new speed, not the answer from the top.
    func testMidStringReturnsTheTail() {
        XCTAssertEqual(SpeechService.remainder(of: "Hello there", spokenUpTo: 6), "there")
    }

    /// At the end there is nothing left to re-speak; returning the whole text here would replay
    /// the segment the listener just finished.
    func testOffsetAtEndReturnsEmpty() {
        XCTAssertEqual(SpeechService.remainder(of: "Hello", spokenUpTo: 5), "")
    }

    func testOffsetPastEndReturnsEmpty() {
        XCTAssertEqual(SpeechService.remainder(of: "Hello", spokenUpTo: 99), "")
    }

    // MARK: - UTF-16 vs Character

    /// The offset is UTF-16 because it comes from an `NSRange`. An emoji is one `Character` and
    /// TWO UTF-16 units, so a `Character`-based implementation would cut in the wrong place here
    /// — this is the test that fails if someone "simplifies" the offset to `text.index(...)`
    /// over `Character`s.
    func testSurrogatePairOffsetsAreMeasuredInUTF16() {
        let text = "👋 hello"                       // 7 Characters, 8 UTF-16 units
        XCTAssertEqual(text.count, 7)
        XCTAssertEqual(text.utf16.count, 8, "The emoji is one Character and two UTF-16 units — that gap is the point.")
        XCTAssertEqual(SpeechService.remainder(of: text, spokenUpTo: 2), " hello",
                       "Offset 2 is just past the emoji's surrogate pair.")
    }

    /// A combining sequence has more UTF-16 units than Characters too; slicing must land on a
    /// scalar boundary rather than splitting the grapheme.
    func testCombiningSequenceDoesNotSplitMidScalar() {
        let text = "café latte"
        let remainder = SpeechService.remainder(of: text, spokenUpTo: 5)
        XCTAssertEqual(remainder, "latte")
    }

    /// An empty utterance is degenerate but reachable (a segment that trims to nothing); it must
    /// not trap.
    func testEmptyTextIsSafe() {
        XCTAssertEqual(SpeechService.remainder(of: "", spokenUpTo: 0), "")
        XCTAssertEqual(SpeechService.remainder(of: "", spokenUpTo: 3), "")
    }

    // MARK: - Declared gap

    /// The restart itself — `setRate`/`setVoice` stopping the synthesizer and speaking the
    /// remainder, and `resumeSpeaking` honouring `restartOnResume` — needs a real
    /// `AVSpeechSynthesizer` and audio output, which the test host does not have. What is pinned
    /// here is the offset arithmetic every one of those paths depends on. Verify on device:
    /// start Read Aloud on a long prose answer, change the speed halfway, and confirm the
    /// remaining audio changes speed without restarting the answer.
    func testUnobservable_restartNeedsRealAudio() throws {
        throw XCTSkip("Declared gap: the utterance restart needs a live AVSpeechSynthesizer; see the comment.")
    }
}
