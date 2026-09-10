// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2026 Raj Singh
//
//  JarvisStreamingSpeakerTests.swift
//  DevgenticTests
//
//  Phase 1 segmentation. `cut` is the piece that decides what Jarvis says out loud and when,
//  and it runs against a stream that arrives in arbitrary fragments — the exact shape that is
//  impractical to verify by talking to a device. All of it is pure.
//

import XCTest
@testable import devgentic

@MainActor
final class JarvisSegmentationTests: XCTestCase {

    // MARK: Sentence boundaries

    func testUnterminatedTextIsHeldBackNotSpoken() {
        // Speaking a half sentence is the failure mode this whole design exists to avoid.
        let result = JarvisStreamingSpeaker.cut("The build succeeded and", fenceOpen: false, isFinal: false)
        XCTAssertTrue(result.segments.isEmpty)
        XCTAssertEqual(result.remainder, "The build succeeded and")
    }

    func testCompleteSentenceIsSpokenAndConsumed() {
        let result = JarvisStreamingSpeaker.cut("The build succeeded.\n", fenceOpen: false, isFinal: false)
        XCTAssertEqual(result.segments, ["The build succeeded."])
        XCTAssertEqual(result.remainder, "")
    }

    func testFinalFlushSpeaksAnUnterminatedTail() {
        // A model that ends without punctuation must still be heard.
        let result = JarvisStreamingSpeaker.cut("All done", fenceOpen: false, isFinal: true)
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
            let result = JarvisStreamingSpeaker.cut(carry, fenceOpen: fence, isFinal: isFinal)
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
        let result = JarvisStreamingSpeaker.cut(text, fenceOpen: false, isFinal: true)
        XCTAssertFalse(result.segments.contains { $0.contains("compute") },
                       "a voice assistant must never read a code fence aloud")
        XCTAssertTrue(result.segments.contains(JarvisStreamingSpeaker.codeAnnouncement))
        XCTAssertTrue(result.segments.contains("Here is the fix."))
        XCTAssertTrue(result.segments.contains("That should do it."))
    }

    func testFenceStateCarriesAcrossPasses() {
        // A fence that opens in one chunk and closes in a later one must stay open in between,
        // or the code body leaks into speech.
        let first = JarvisStreamingSpeaker.cut("Here:\n```swift\nlet x = 1\n", fenceOpen: false, isFinal: false)
        XCTAssertTrue(first.fenceOpen)
        XCTAssertFalse(first.segments.contains { $0.contains("let x") })

        let second = JarvisStreamingSpeaker.cut("let y = 2\n```\nDone.\n", fenceOpen: true, isFinal: false)
        XCTAssertFalse(second.fenceOpen)
        XCTAssertFalse(second.segments.contains { $0.contains("let y") })
        XCTAssertEqual(second.segments, [JarvisStreamingSpeaker.codeAnnouncement, "Done."])
    }

    func testAnswerEndingInsideAnUnclosedFenceStillAnnouncesTheCode() {
        // Truncated answers really do end mid-fence; silence there reads as a fault.
        let result = JarvisStreamingSpeaker.cut("```swift\nlet x = 1\n", fenceOpen: false, isFinal: true)
        XCTAssertEqual(result.segments, [JarvisStreamingSpeaker.codeAnnouncement])
    }

    func testEmptyFenceProducesNoAnnouncement() {
        let result = JarvisStreamingSpeaker.cut("```\n```\n", fenceOpen: false, isFinal: true)
        XCTAssertTrue(result.segments.isEmpty)
    }

    // MARK: Markdown cleaning

    func testMarkdownDecorationIsStrippedButWordsSurvive() {
        XCTAssertEqual(JarvisStreamingSpeaker.cleanForSpeech("## The Result"), "The Result")
        XCTAssertEqual(JarvisStreamingSpeaker.cleanForSpeech("It **passed** cleanly"), "It passed cleanly")
        XCTAssertEqual(JarvisStreamingSpeaker.cleanForSpeech("Run `make test` now"), "Run make test now")
        XCTAssertEqual(JarvisStreamingSpeaker.cleanForSpeech("- a bullet"), "a bullet")
        XCTAssertEqual(JarvisStreamingSpeaker.cleanForSpeech("See [the docs](https://example.com)"), "See the docs")
    }

    func testSnakeCaseIdentifiersAreNotCorrupted() {
        // ⚠️ Regression guard. SpeechService's private cleaner treats `_…_` as emphasis and
        // collapses any identifier with two or more underscores — in a developer tool that is
        // precisely the text most worth pronouncing correctly.
        XCTAssertEqual(JarvisStreamingSpeaker.cleanForSpeech("call fs_smart_search first"),
                       "call fs_smart_search first")
        XCTAssertEqual(JarvisStreamingSpeaker.cleanForSpeech("__init__ runs first"), "__init__ runs first")
    }

    // MARK: Boundary helper

    func testLastSentenceBoundaryIgnoresATerminatorMidWord() {
        // "3.5" must not be treated as the end of a sentence.
        let text = "Version 3.5 shipped"
        XCTAssertEqual(JarvisStreamingSpeaker.lastSentenceBoundary(in: text), text.startIndex)
    }

    func testLastSentenceBoundaryFindsTheFinalTerminator() {
        let text = "One. Two. Three"
        let boundary = JarvisStreamingSpeaker.lastSentenceBoundary(in: text)
        XCTAssertEqual(String(text[..<boundary]).trimmingCharacters(in: .whitespaces), "One. Two.")
    }
}

// MARK: - Spoken-response modes

@MainActor
final class JarvisSpokenResponseModeTests: XCTestCase {

    func testSilentModeSpeaksNothing() {
        XCTAssertFalse(JarvisSpokenResponses.preferSilent.speaksAnswer)
        XCTAssertEqual(JarvisSpokenResponses.preferSilent.sentenceCap, 0)
    }

    func testPreferSpokenHasNoCap() {
        XCTAssertTrue(JarvisSpokenResponses.preferSpoken.speaksAnswer)
        XCTAssertNil(JarvisSpokenResponses.preferSpoken.sentenceCap)
    }

    func testAutomaticSpeaksButBoundsALongAnswer() {
        XCTAssertTrue(JarvisSpokenResponses.automatic.speaksAnswer)
        XCTAssertEqual(JarvisSpokenResponses.automatic.sentenceCap, 6)
    }

    func testSilenceAndTheZeroCapAlwaysAgree() {
        // ⚠️ Regression guard for a real bug: `begin()` returned early in silent mode, but
        // `ingest` did not know that — so a silent run still reached `enqueue`, hit the zero
        // sentence cap, and spoke the truncation notice. The one phrase the user had just
        // asked not to hear. The invariant that makes that unreachable is that "does not speak"
        // and "cap of zero" are the same state, never one without the other.
        for mode in JarvisSpokenResponses.allCases {
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
        let saved = UserDefaults.standard.object(forKey: AppSettings.jarvisSpokenResponsesKey)
        UserDefaults.standard.removeObject(forKey: AppSettings.jarvisSpokenResponsesKey)
        defer {
            if let saved { UserDefaults.standard.set(saved, forKey: AppSettings.jarvisSpokenResponsesKey) }
        }
        XCTAssertEqual(JarvisConfigManager.shared.spokenResponses, .automatic)
    }
}
