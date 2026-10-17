// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
//
//  OrbStreamingSpeakerTests.swift
//  DevgenticTests
//
//  Phase 1 segmentation. `cut` is the piece that decides what Orb says out loud and when,
//  and it runs against a stream that arrives in arbitrary fragments — the exact shape that is
//  impractical to verify by talking to a device. All of it is pure.
//

import XCTest
@testable import devgentic

@MainActor
final class OrbSegmentationTests: XCTestCase {

    // MARK: Sentence boundaries

    func testUnterminatedTextIsHeldBackNotSpoken() {
        // Speaking a half sentence is the failure mode this whole design exists to avoid.
        let result = OrbStreamingSpeaker.cut("The build succeeded and", fenceOpen: false, isFinal: false)
        XCTAssertTrue(result.segments.isEmpty)
        XCTAssertEqual(result.remainder, "The build succeeded and")
    }

    func testCompleteSentenceIsSpokenAndConsumed() {
        let result = OrbStreamingSpeaker.cut("The build succeeded.\n", fenceOpen: false, isFinal: false)
        XCTAssertEqual(result.segments, ["The build succeeded."])
        XCTAssertEqual(result.remainder, "")
    }

    func testFinalFlushSpeaksAnUnterminatedTail() {
        // A model that ends without punctuation must still be heard.
        let result = OrbStreamingSpeaker.cut("All done", fenceOpen: false, isFinal: true)
        XCTAssertEqual(result.segments, ["All done"])
        XCTAssertEqual(result.remainder, "")
    }

    func testStreamingInFragmentsSpeaksEachSentenceExactlyOnce() {
        // The load-bearing test: feed an answer in awkward fragments and assert the spoken text
        // equals the answer — nothing duplicated, nothing dropped.
        let fragments = ["The tests ", "passed. Two files ", "changed.\nNothing else ", "to report.\n"]
        var carry = ""
        var fence = false
        var spoken: [String] = []

        for (index, fragment) in fragments.enumerated() {
            carry += fragment
            let isFinal = index == fragments.count - 1
            let result = OrbStreamingSpeaker.cut(carry, fenceOpen: fence, isFinal: isFinal)
            carry = result.remainder
            fence = result.fenceOpen
            spoken.append(contentsOf: result.segments)
        }

        XCTAssertEqual(spoken, ["The tests passed.", "Two files changed.", "Nothing else to report."])
        XCTAssertEqual(carry, "", "everything should have been consumed by the final pass")
    }

    // MARK: Code fences

    func testCodeBlockBodyIsNeverSpoken() {
        let text = """
        Here is the fix.
        ```swift
        let x = compute(a, b)
        print(x)
        ```
        That should do it.
        """
        let result = OrbStreamingSpeaker.cut(text, fenceOpen: false, isFinal: true)
        XCTAssertFalse(result.segments.contains { $0.contains("compute") },
                       "a voice assistant must never read a code fence aloud")
        XCTAssertTrue(result.segments.contains(OrbStreamingSpeaker.codeAnnouncement))
        XCTAssertTrue(result.segments.contains("Here is the fix."))
        XCTAssertTrue(result.segments.contains("That should do it."))
    }

    func testFenceStateCarriesAcrossPasses() {
        // A fence that opens in one chunk and closes in a later one must stay open in between,
        // or the code body leaks into speech.
        let first = OrbStreamingSpeaker.cut("Here:\n```swift\nlet x = 1\n", fenceOpen: false, isFinal: false)
        XCTAssertTrue(first.fenceOpen)
        XCTAssertFalse(first.segments.contains { $0.contains("let x") })

        let second = OrbStreamingSpeaker.cut("let y = 2\n```\nDone.\n", fenceOpen: true, isFinal: false)
        XCTAssertFalse(second.fenceOpen)
        XCTAssertFalse(second.segments.contains { $0.contains("let y") })
        XCTAssertEqual(second.segments, [OrbStreamingSpeaker.codeAnnouncement, "Done."])
    }

    func testAnswerEndingInsideAnUnclosedFenceStillAnnouncesTheCode() {
        // Truncated answers really do end mid-fence; silence there reads as a fault.
        let result = OrbStreamingSpeaker.cut("```swift\nlet x = 1\n", fenceOpen: false, isFinal: true)
        XCTAssertEqual(result.segments, [OrbStreamingSpeaker.codeAnnouncement])
    }

    func testEmptyFenceProducesNoAnnouncement() {
        let result = OrbStreamingSpeaker.cut("```\n```\n", fenceOpen: false, isFinal: true)
        XCTAssertTrue(result.segments.isEmpty)
    }

    // MARK: Markdown cleaning

    func testMarkdownDecorationIsStrippedButWordsSurvive() {
        XCTAssertEqual(OrbStreamingSpeaker.cleanForSpeech("## The Result"), "The Result")
        XCTAssertEqual(OrbStreamingSpeaker.cleanForSpeech("It **passed** cleanly"), "It passed cleanly")
        XCTAssertEqual(OrbStreamingSpeaker.cleanForSpeech("Run `make test` now"), "Run make test now")
        XCTAssertEqual(OrbStreamingSpeaker.cleanForSpeech("- a bullet"), "a bullet")
        XCTAssertEqual(OrbStreamingSpeaker.cleanForSpeech("See [the docs](https://example.com)"), "See the docs")
    }

    func testSnakeCaseIdentifiersAreNotCorrupted() {
        // ⚠️ Regression guard. SpeechService's private cleaner treats `_…_` as emphasis and
        // collapses any identifier with two or more underscores — in a developer tool that is
        // precisely the text most worth pronouncing correctly.
        XCTAssertEqual(OrbStreamingSpeaker.cleanForSpeech("call spotlight_search first"),
                       "call spotlight_search first")
        XCTAssertEqual(OrbStreamingSpeaker.cleanForSpeech("__init__ runs first"), "__init__ runs first")
    }

    // MARK: Boundary helper

    func testLastSentenceBoundaryIgnoresATerminatorMidWord() {
        // "3.5" must not be treated as the end of a sentence.
        let text = "Version 3.5 shipped"
        XCTAssertEqual(OrbStreamingSpeaker.lastSentenceBoundary(in: text), text.startIndex)
    }

    func testLastSentenceBoundaryFindsTheFinalTerminator() {
        let text = "One. Two. Three"
        let boundary = OrbStreamingSpeaker.lastSentenceBoundary(in: text)
        XCTAssertEqual(String(text[..<boundary]).trimmingCharacters(in: .whitespaces), "One. Two.")
    }
}

// MARK: - Spoken-response modes

@MainActor
final class OrbSpokenResponseModeTests: XCTestCase {

    func testSilentModeSpeaksNothing() {
        XCTAssertFalse(OrbSpokenResponses.preferSilent.speaksAnswer)
        XCTAssertEqual(OrbSpokenResponses.preferSilent.sentenceCap, 0)
    }

    func testPreferSpokenHasNoCap() {
        XCTAssertTrue(OrbSpokenResponses.preferSpoken.speaksAnswer)
        XCTAssertNil(OrbSpokenResponses.preferSpoken.sentenceCap)
    }

    func testAutomaticSpeaksButBoundsALongAnswer() {
        XCTAssertTrue(OrbSpokenResponses.automatic.speaksAnswer)
        XCTAssertEqual(OrbSpokenResponses.automatic.sentenceCap, 6)
    }

    func testSilenceAndTheZeroCapAlwaysAgree() {
        // ⚠️ Regression guard for a real bug: `begin()` returned early in silent mode, but
        // `ingest` did not know that — so a silent run still reached `enqueue`, hit the zero
        // sentence cap, and spoke the truncation notice. The one phrase the user had just
        // asked not to hear. The invariant that makes that unreachable is that "does not speak"
        // and "cap of zero" are the same state, never one without the other.
        for mode in OrbSpokenResponses.allCases {
            if mode.sentenceCap == 0 {
                XCTAssertFalse(mode.speaksAnswer, "\(mode.rawValue) has a zero cap so it must not claim to speak")
            }
            if !mode.speaksAnswer {
                XCTAssertEqual(mode.sentenceCap, 0, "\(mode.rawValue) does not speak so its cap must be zero")
            }
        }
    }

    func testAutomaticIsTheDefaultMode() {
        // Not `.preferSilent`: shipping Phase 1 with narration off by default would make the
        // whole phase invisible to anyone who never opens Settings.
        let saved = TestHost.defaults.object(forKey: AppSettings.orbSpokenResponsesKey)
        TestHost.defaults.removeObject(forKey: AppSettings.orbSpokenResponsesKey)
        defer {
            if let saved { TestHost.defaults.set(saved, forKey: AppSettings.orbSpokenResponsesKey) }
        }
        XCTAssertEqual(OrbConfigManager.shared.spokenResponses, .automatic)
    }
}
