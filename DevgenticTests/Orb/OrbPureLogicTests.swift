// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
//
//  OrbPureLogicTests.swift
//  DevgenticTests
//
//  Phase 0 (2026-09-04): the FIRST tests for anything under Devgentic/Orb/ — the audit
//  found zero. Every function here is a `static` on `OrbSessionController` deliberately
//  written to be pure, so none of this needs WhisperKit, AVFoundation, a microphone, or a
//  running panel. Loading a Whisper model in tests is forbidden (see MEMORY.md); nothing
//  here comes near one.
//
//  `OrbSessionController` is `@MainActor`, so its statics inherit that isolation — hence
//  the `@MainActor` on each suite rather than an `await` at every call site.
//

import XCTest
@testable import devgentic

// MARK: - Wake-word matching and command extraction

@MainActor
final class OrbWakeWordTests: XCTestCase {

    func testCanonicalWakeWordIsLiveNotDeadCode() {
        // Regression: `wakeWord` was unreferenced while all matching went through the
        // variant list, so editing it changed nothing. The variants now derive from it.
        XCTAssertEqual(OrbSessionController.wakeWordVariants(for: "zephyr").first, "zephyr")
    }

    func testMatchesEveryAcceptedHomophone() {
        let word = OrbConfigManager.defaultWakeWord
        for variant in OrbSessionController.wakeWordVariants(for: word) {
            XCTAssertNotNil(
                OrbSessionController.wakeWordRange(in: "hey \(variant) do the thing", wakeWord: word),
                "variant \"\(variant)\" must match")
        }
    }

    func testMatchingIsCaseInsensitive() {
        XCTAssertNotNil(OrbSessionController.wakeWordRange(in: "ORB run the tests"))
    }

    func testNoWakeWordReturnsNil() {
        XCTAssertNil(OrbSessionController.wakeWordRange(in: "just talking to a colleague"))
    }

    func testEarliestVariantWins() {
        // Documents the known hazard: the FIRST match anchors extraction, so a false positive
        // early in a cumulative transcript prefixes everything spoken after it onto the command.
        let text = "orba said hello then orb run the tests"
        let command = OrbSessionController.extractCommand(from: text)
        XCTAssertEqual(command, "said hello then orb run the tests")
    }

    func testExtractCommandTakesTextAfterTheWakeWord() {
        XCTAssertEqual(OrbSessionController.extractCommand(from: "orb, run the tests"), "run the tests")
    }

    func testRepeatedLeadingWakeWordIsFullyStripped() {
        // ⚠️ Observed on device 2026-09-04: the user said "Orb" twice because the first
        // attempt did not visibly register, and the second one reached the model inside the
        // query. Users repeat a wake word whenever the UI gives them no feedback, so this is
        // the common case, not an edge case.
        XCTAssertEqual(
            OrbSessionController.extractCommand(from: "Orb. Orb, write an essay on technology."),
            "write an essay on technology"
        )
        XCTAssertEqual(
            OrbSessionController.extractCommand(from: "orb orb orb run the tests"),
            "run the tests"
        )
    }

    func testAWakeWordLATERInTheSentenceSurvives() {
        // Stripping is LEADING-only: a wake word inside the request is part of what was asked.
        XCTAssertEqual(
            OrbSessionController.extractCommand(from: "Orb, remind me to tell Orb about it"),
            "remind me to tell Orb about it"
        )
    }

    func testExtractCommandFallsBackToWholeTranscriptWhenWakeWordWasRewrittenOut() {
        // WhisperKit rewrites confirmed segments, and the wake word can vanish from the final
        // text. Falling back to the whole transcript is what keeps the command from being lost.
        XCTAssertEqual(OrbSessionController.extractCommand(from: "run the tests"), "run the tests")
    }

    func testNoHomophoneOfTheOldNameSurvives() {
        // Regression (2026-09-19): the wake word was renamed from a six-letter name to "orb", and
        // the OLD name's Whisper homophones stayed in `wakeWordVariants` because none contained the
        // old name literally — so "Travis" armed the orb while the new name's own mishearing was
        // mangled. Pinned so the next rename cannot repeat it.
        for stale in ["jarvis", "jarvus", "jervis", "javis", "jarves", "charvis", "travis"] {
            XCTAssertNil(OrbSessionController.wakeWordRange(in: "hey \(stale) do the thing"),
                         "\"\(stale)\" is a homophone of the OLD wake word and must not match")
        }
    }

    func testWakeWordIsMatchedAsAWholeWordNotASubstring() {
        // A three-letter wake word matched by bare substring fires inside ordinary words.
        for sentence in ["absorb the cost", "that is forbidden", "put it in orbit", "a morbid thought"] {
            XCTAssertNil(OrbSessionController.wakeWordRange(in: sentence), "\"\(sentence)\" must not wake the orb")
        }
        for sentence in ["orb", "Orb.", "ORB, run the tests", "hey orb", "Orba"] {
            XCTAssertNotNil(OrbSessionController.wakeWordRange(in: sentence), "\"\(sentence)\" must wake the orb")
        }
    }

    func testHomophoneWithATrailingLetterIsStrippedWhole() {
        // ⚠️ Observed on device 2026-09-19: Whisper rendered "Orb. Orb." as "Orba. Orba.", the
        // substring "orb" matched INSIDE "Orba", extraction sliced after the substring, and the
        // model received "a. Orba" — which it answered as a question about a puzzle game.
        XCTAssertEqual(OrbSessionController.extractCommand(from: "Orba. Orba."), "")
        XCTAssertEqual(OrbSessionController.extractCommand(from: "Orba, write an essay on technology."),
                       "write an essay on technology")
    }

    func testClickArmedCaptureAlsoDropsLeadingWakeWords() {
        // ⚠️ Observed on device 2026-09-19: the user said the wake word three times with no visible
        // response, clicked the orb, and finished the sentence. The click path only stripped the
        // pre-arm baseline — and Whisper had rewritten that baseline out of the final transcript —
        // so "Orba, Orba, Orba. Write in essay, you know" reached the model in full.
        let rewritten = OrbSessionController.commandPreview(
            liveTranscript: "Orba, Orba, Orba. Write in essay, you know.",
            manualBaseline: "Or, or, or"
        )
        XCTAssertEqual(rewritten, "Write in essay, you know")

        // Baseline intact: text after the arm point, then any wake word repeated after the click.
        let kept = OrbSessionController.commandPreview(
            liveTranscript: "Orba, Orba, Orba. Write in essay, you know.",
            manualBaseline: "Orba, Orba,"
        )
        XCTAssertEqual(kept, "Write in essay, you know")

        // No baseline = armed by the wake word — the existing path, unchanged.
        XCTAssertEqual(
            OrbSessionController.commandPreview(liveTranscript: "Orb, run the tests", manualBaseline: nil),
            "run the tests"
        )
    }
}

// MARK: - A configurable wake word

/// ⚠️ These pin the SETTING, not just the matcher. The wake word was a `static let` derived once
/// at type-initialization until 2026-09-19 — a word typed in Settings could never have reached a
/// running orb, and no test would have noticed, because every test used the default.
@MainActor
final class OrbWakeWordConfigurationTests: XCTestCase {

    func testTheConfiguredWordIsWhatMatches() {
        XCTAssertNotNil(OrbSessionController.wakeWordRange(in: "zephyr run the tests", wakeWord: "zephyr"))
        // ...and the shipped default is NOT still quietly in force alongside it.
        XCTAssertNil(OrbSessionController.wakeWordRange(in: "orb run the tests", wakeWord: "zephyr"))
    }

    func testACustomWordGetsNoInventedHomophones() {
        // Homophones are observations, not derivations: only a word someone has heard mis-heard
        // gets alternatives. Inventing them would widen every custom user's match on a hunch.
        XCTAssertEqual(OrbSessionController.wakeWordVariants(for: "zephyr"), ["zephyr"])
        XCTAssertEqual(OrbSessionController.wakeWordVariants(for: OrbConfigManager.defaultWakeWord),
                       [OrbConfigManager.defaultWakeWord, "orba", "orbs"])
    }

    func testAMultiWordWakePhraseMatchesAndIsStripped() {
        // The documented escape hatch from a short word the recognizer keeps missing.
        XCTAssertEqual(
            OrbSessionController.extractCommand(from: "Hey orb, write an essay on technology.",
                                                wakeWord: "hey orb"),
            "write an essay on technology"
        )
        XCTAssertNil(OrbSessionController.wakeWordRange(in: "the orb is glowing", wakeWord: "hey orb"),
                     "a two-word phrase must not match on its second word alone")
    }

    func testACustomWordIsStrippedOnTheClickPathToo() {
        // The device case: Whisper REWROTE the pre-arm text, so the baseline is no longer a prefix
        // of the final transcript, `strippingPrefix` correctly falls back to the whole thing — and
        // the wake words the user said before clicking are still sitting at the front of it.
        XCTAssertEqual(
            OrbSessionController.commandPreview(liveTranscript: "Zephyr. Zephyr. Run the tests.",
                                                manualBaseline: "Zeph, zeph",
                                                wakeWord: "zephyr"),
            "Run the tests"
        )

        // Baseline intact: everything after the arm point, with nothing left to strip.
        XCTAssertEqual(
            OrbSessionController.commandPreview(liveTranscript: "Zephyr. Zephyr. Run the tests.",
                                                manualBaseline: "Zephyr. Zephyr.",
                                                wakeWord: "zephyr"),
            "Run the tests"
        )
    }

    // MARK: Sanitizing

    func testSanitizingLowercasesAndDropsPunctuation() {
        XCTAssertEqual(OrbConfigManager.sanitizedWakeWord("  Zephyr!  "), "zephyr")
        XCTAssertEqual(OrbConfigManager.sanitizedWakeWord("Hey,   Orb."), "hey orb")
    }

    func testSanitizingRejectsWhatCannotBeMatched() {
        // Below the floor, or nothing left after stripping — the getter falls back to the default,
        // so the orb stays usable rather than going deaf or matching every sentence in the room.
        for unusable in ["", "   ", "a", "!", "...", "?"] {
            XCTAssertNil(OrbConfigManager.sanitizedWakeWord(unusable), "\(unusable.debugDescription) must be rejected")
        }
    }

    func testARegexMetacharacterEntryCannotBecomeAPattern() {
        // ⚠️ The entry is compiled into a regular expression. ".*" would match every transcript
        // and arm capture on silence; it must never survive sanitizing as metacharacters.
        XCTAssertNil(OrbConfigManager.sanitizedWakeWord(".*"))
        XCTAssertEqual(OrbConfigManager.sanitizedWakeWord("or(b)"), "or b")

        // And a word that merely CONTAINS metacharacters is matched literally, not as a pattern.
        XCTAssertNil(OrbSessionController.wakeWordRange(in: "anything at all", wakeWord: "a.b"))
        XCTAssertNotNil(OrbSessionController.wakeWordRange(in: "say a.b now", wakeWord: "a.b"))
    }

    func testTheWakeWordSettingIsCoveredByReset() {
        // The Phase 6 keys escaped `resetAll` unnoticed; this is the same guard for this one.
        XCTAssertTrue(OrbConfigManager.allResettableKeys.contains(AppSettings.orbWakeWordKey))
    }
}


// MARK: - Stability normalization

@MainActor
final class OrbStabilityNormalizationTests: XCTestCase {

    func testPunctuationAndCaseChurnNormalizeToTheSameForm() {
        // The whole point: Whisper's temperature-fallback re-decodes reshuffle punctuation and
        // casing every pass, and raw-text comparison never settles, so the commit timer resets
        // forever (observed on device as a capture that ran 54s).
        let a = OrbSessionController.normalizedForStability("Run the tests.")
        let b = OrbSessionController.normalizedForStability("run the tests")
        XCTAssertEqual(a, b)
    }

    func testCollapsesRepeatedSeparators() {
        XCTAssertEqual(OrbSessionController.normalizedForStability("run   the -- tests!!"), "run the tests")
    }

    func testEmptyStaysEmpty() {
        XCTAssertEqual(OrbSessionController.normalizedForStability("  ...  "), "")
    }
}

// MARK: - Manual-capture prefix stripping

@MainActor
final class OrbPrefixStrippingTests: XCTestCase {

    func testReturnsOnlyTextAfterTheArmPoint() {
        XCTAssertEqual(
            OrbSessionController.strippingPrefix("some earlier chatter", from: "some earlier chatter run the tests"),
            "run the tests"
        )
    }

    func testFallsBackToWholeTextWhenTheEarlierPortionWasRewritten() {
        // Documents the sharp edge: when Whisper rewrites the already-spoken portion the prefix
        // no longer matches, and the WHOLE cumulative transcript becomes the command.
        XCTAssertEqual(
            OrbSessionController.strippingPrefix("some earlier chatter", from: "Some earlier chatter, run the tests"),
            "Some earlier chatter, run the tests"
        )
    }

    func testEmptyPrefixReturnsTrimmedText() {
        XCTAssertEqual(OrbSessionController.strippingPrefix("", from: ", run the tests"), "run the tests")
    }
}

// MARK: - D-2: the dispatch floor

@MainActor
final class OrbDispatchGateTests: XCTestCase {

    func testSingleHallucinatedTokenIsNotDispatchable() {
        // "Thank you." is Whisper's canonical silence hallucination. Before the floor, the only
        // gate was `!command.isEmpty`, so it could start a run on a profile with shell tools.
        XCTAssertFalse(OrbSessionController.isDispatchable("Thanks"))
        XCTAssertFalse(OrbSessionController.isDispatchable(""))
        XCTAssertFalse(OrbSessionController.isDispatchable("   "))
    }

    func testTwoWordsIsDispatchable() {
        XCTAssertTrue(OrbSessionController.isDispatchable("run tests"))
        XCTAssertTrue(OrbSessionController.isDispatchable("Thank you."))  // documented cost of the floor
    }

    func testWordCountIgnoresWhitespaceRuns() {
        XCTAssertEqual(OrbSessionController.wordCount("  run   the\ntests "), 3)
        XCTAssertEqual(OrbSessionController.wordCount(""), 0)
    }
}

// MARK: - D-1: spoken cancel

@MainActor
final class OrbCancelPhraseTests: XCTestCase {

    func testEveryCancelPhraseIsRecognized() {
        for phrase in OrbSessionController.cancelPhrases {
            XCTAssertTrue(OrbSessionController.isCancelPhrase(phrase), "\"\(phrase)\" must cancel")
        }
    }

    func testRecognizedThroughPunctuationAndCaseChurn() {
        XCTAssertTrue(OrbSessionController.isCancelPhrase("Never mind!"))
    }

    func testTrailingCancelAbortsACommandAlreadyInFlight() {
        // The realistic shape: the user starts asking, sees the transcription go wrong, and says
        // "never mind" — the capture must abort rather than sending the whole thing.
        XCTAssertTrue(OrbSessionController.isCancelPhrase("delete the build folder never mind"))
    }

    func testOrdinaryCommandsAreNotCancels() {
        XCTAssertFalse(OrbSessionController.isCancelPhrase("run the tests"))
        XCTAssertFalse(OrbSessionController.isCancelPhrase(""))
        XCTAssertFalse(OrbSessionController.isCancelPhrase("never minding the warnings"))
    }
}

// MARK: - D-3: wake word vs. speech language

@MainActor
final class OrbWakeWordLanguageTests: XCTestCase {

    func testUnsetOrEnglishLanguageCanMatch() {
        XCTAssertTrue(OrbSessionController.wakeWordCanMatch(language: nil))
        XCTAssertTrue(OrbSessionController.wakeWordCanMatch(language: ""))
        XCTAssertTrue(OrbSessionController.wakeWordCanMatch(language: "en"))
        XCTAssertTrue(OrbSessionController.wakeWordCanMatch(language: "en-US"))
    }

    func testNonEnglishLanguageCannotMatch() {
        // The silent-death case: the recognizer returns text in another script, no English
        // variant can ever match, and the orb looks alive while ignoring the user forever.
        for language in ["ja", "hi", "ru", "zh", "ar"] {
            XCTAssertFalse(OrbSessionController.wakeWordCanMatch(language: language),
                           "\"\(language)\" must be reported as unable to match")
        }
    }
}

// MARK: - P0-1: the completion announcement must not lie

@MainActor
final class OrbAnnouncementTests: XCTestCase {

    func testSuccessKeepsTheEstablishedPhrase() {
        XCTAssertEqual(OrbSessionController.announcement(for: .completed, reason: nil),
                       OrbSessionController.completionPhrase)
    }

    func testFailureDoesNotClaimSuccess() {
        // The defect this exists to pin: only `.cancelled` was branched, so a FAILED run
        // announced "Your task is completed" to a user with no other channel.
        let spoken = OrbSessionController.announcement(for: .failed, reason: nil)
        XCTAssertNotEqual(spoken, OrbSessionController.completionPhrase)
        XCTAssertTrue(spoken.lowercased().contains("didn't work"))
    }

    func testFailureSurfacesTheReasonWhenThereIsOne() {
        let spoken = OrbSessionController.announcement(for: .failed, reason: "The model timed out")
        XCTAssertTrue(spoken.contains("The model timed out"))
    }

    /// ⚠️ Asserts the PROPERTY, not the literal. The exact wording changed in Phase 6 (it now
    /// offers the "what went wrong" follow-up); what must never change is that a blank reason
    /// produces a complete sentence instead of "That didn't work. ".
    func testBlankReasonDoesNotProduceADanglingSentence() {
        let spoken = OrbSessionController.announcement(for: .failed, reason: "   ")
        XCTAssertTrue(spoken.hasSuffix("."), "A blank reason must still end the sentence: \(spoken)")
        XCTAssertFalse(spoken.hasSuffix("work. "), "The reason was blank — nothing should dangle after it.")
        XCTAssertTrue(spoken.lowercased().contains("didn't work"))
    }

    /// The failure path is the one place a voice-only user most needs a next step, and Phase 6
    /// gave them one instead of only pointing at a window they may not be looking at.
    func testFailureOffersTheSpokenFollowUp() {
        let spoken = OrbSessionController.announcement(for: .failed, reason: nil)
        XCTAssertTrue(spoken.lowercased().contains("what went wrong"),
                      "A failed run should offer the spoken follow-up: \(spoken)")
    }

    func testWarningsOutcomeIsDistinctFromBothSuccessAndFailure() {
        let spoken = OrbSessionController.announcement(for: .completedWithWarnings, reason: nil)
        XCTAssertNotEqual(spoken, OrbSessionController.completionPhrase)
        XCTAssertNotEqual(spoken, OrbSessionController.announcement(for: .failed, reason: nil))
    }

    func testNilOutcomeReportsUncertaintyRatherThanSuccess() {
        let spoken = OrbSessionController.announcement(for: nil, reason: nil)
        XCTAssertNotEqual(spoken, OrbSessionController.completionPhrase)
    }

    func testEveryOutcomeProducesANonEmptyPhrase() {
        for outcome in ExecutionOutcome.allCases {
            XCTAssertFalse(OrbSessionController.announcement(for: outcome, reason: nil).isEmpty)
        }
    }
}
