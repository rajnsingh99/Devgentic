//
//  JarvisPureLogicTests.swift
//  DevgenticTests
//
//  Phase 0 (2026-09-04): the FIRST tests for anything under Devgentic/Jarvis/ — the audit
//  found zero. Every function here is a `static` on `JarvisSessionController` deliberately
//  written to be pure, so none of this needs WhisperKit, AVFoundation, a microphone, or a
//  running panel. Loading a Whisper model in tests is forbidden (see MEMORY.md); nothing
//  here comes near one.
//
//  `JarvisSessionController` is `@MainActor`, so its statics inherit that isolation — hence
//  the `@MainActor` on each suite rather than an `await` at every call site.
//

import XCTest
@testable import devgentic

// MARK: - Wake-word matching and command extraction

@MainActor
final class JarvisWakeWordTests: XCTestCase {

    func testCanonicalWakeWordIsLiveNotDeadCode() {
        // Regression: `wakeWord` was unreferenced while all matching went through the
        // variant list, so editing it changed nothing. The variants now derive from it.
        XCTAssertEqual(JarvisSessionController.wakeWordVariants.first, JarvisSessionController.wakeWord)
    }

    func testMatchesEveryAcceptedHomophone() {
        for variant in JarvisSessionController.wakeWordVariants {
            XCTAssertNotNil(JarvisSessionController.wakeWordRange(in: "hey \(variant) do the thing"),
                            "variant \"\(variant)\" must match")
        }
    }

    func testMatchingIsCaseInsensitive() {
        XCTAssertNotNil(JarvisSessionController.wakeWordRange(in: "JARVIS run the tests"))
    }

    func testNoWakeWordReturnsNil() {
        XCTAssertNil(JarvisSessionController.wakeWordRange(in: "just talking to a colleague"))
    }

    func testEarliestVariantWins() {
        // Documents the known hazard: the FIRST match anchors extraction, so a false positive
        // early in a cumulative transcript prefixes everything spoken after it onto the command.
        let text = "travis said hello then jarvis run the tests"
        let command = JarvisSessionController.extractCommand(from: text)
        XCTAssertEqual(command, "said hello then jarvis run the tests")
    }

    func testExtractCommandTakesTextAfterTheWakeWord() {
        XCTAssertEqual(JarvisSessionController.extractCommand(from: "jarvis, run the tests"), "run the tests")
    }

    func testRepeatedLeadingWakeWordIsFullyStripped() {
        // ⚠️ Observed on device 2026-09-04: the user said "Jarvis" twice because the first
        // attempt did not visibly register, and the second one reached the model inside the
        // query. Users repeat a wake word whenever the UI gives them no feedback, so this is
        // the common case, not an edge case.
        XCTAssertEqual(
            JarvisSessionController.extractCommand(from: "Jarvis. Jarvis, write an essay on technology."),
            "write an essay on technology"
        )
        XCTAssertEqual(
            JarvisSessionController.extractCommand(from: "jarvis jarvis jarvis run the tests"),
            "run the tests"
        )
    }

    func testAWakeWordLATERInTheSentenceSurvives() {
        // Stripping is LEADING-only: a wake word inside the request is part of what was asked.
        XCTAssertEqual(
            JarvisSessionController.extractCommand(from: "Jarvis, remind me to tell Jarvis about it"),
            "remind me to tell Jarvis about it"
        )
    }

    func testExtractCommandFallsBackToWholeTranscriptWhenWakeWordWasRewrittenOut() {
        // WhisperKit rewrites confirmed segments, and the wake word can vanish from the final
        // text. Falling back to the whole transcript is what keeps the command from being lost.
        XCTAssertEqual(JarvisSessionController.extractCommand(from: "run the tests"), "run the tests")
    }
}

// MARK: - Stability normalization

@MainActor
final class JarvisStabilityNormalizationTests: XCTestCase {

    func testPunctuationAndCaseChurnNormalizeToTheSameForm() {
        // The whole point: Whisper's temperature-fallback re-decodes reshuffle punctuation and
        // casing every pass, and raw-text comparison never settles, so the commit timer resets
        // forever (observed on device as a capture that ran 54s).
        let a = JarvisSessionController.normalizedForStability("Run the tests.")
        let b = JarvisSessionController.normalizedForStability("run the tests")
        XCTAssertEqual(a, b)
    }

    func testCollapsesRepeatedSeparators() {
        XCTAssertEqual(JarvisSessionController.normalizedForStability("run   the -- tests!!"), "run the tests")
    }

    func testEmptyStaysEmpty() {
        XCTAssertEqual(JarvisSessionController.normalizedForStability("  ...  "), "")
    }
}

// MARK: - Manual-capture prefix stripping

@MainActor
final class JarvisPrefixStrippingTests: XCTestCase {

    func testReturnsOnlyTextAfterTheArmPoint() {
        XCTAssertEqual(
            JarvisSessionController.strippingPrefix("some earlier chatter", from: "some earlier chatter run the tests"),
            "run the tests"
        )
    }

    func testFallsBackToWholeTextWhenTheEarlierPortionWasRewritten() {
        // Documents the sharp edge: when Whisper rewrites the already-spoken portion the prefix
        // no longer matches, and the WHOLE cumulative transcript becomes the command.
        XCTAssertEqual(
            JarvisSessionController.strippingPrefix("some earlier chatter", from: "Some earlier chatter, run the tests"),
            "Some earlier chatter, run the tests"
        )
    }

    func testEmptyPrefixReturnsTrimmedText() {
        XCTAssertEqual(JarvisSessionController.strippingPrefix("", from: ", run the tests"), "run the tests")
    }
}

// MARK: - D-2: the dispatch floor

@MainActor
final class JarvisDispatchGateTests: XCTestCase {

    func testSingleHallucinatedTokenIsNotDispatchable() {
        // "Thank you." is Whisper's canonical silence hallucination. Before the floor, the only
        // gate was `!command.isEmpty`, so it could start a run on a profile with shell tools.
        XCTAssertFalse(JarvisSessionController.isDispatchable("Thanks"))
        XCTAssertFalse(JarvisSessionController.isDispatchable(""))
        XCTAssertFalse(JarvisSessionController.isDispatchable("   "))
    }

    func testTwoWordsIsDispatchable() {
        XCTAssertTrue(JarvisSessionController.isDispatchable("run tests"))
        XCTAssertTrue(JarvisSessionController.isDispatchable("Thank you."))  // documented cost of the floor
    }

    func testWordCountIgnoresWhitespaceRuns() {
        XCTAssertEqual(JarvisSessionController.wordCount("  run   the\ntests "), 3)
        XCTAssertEqual(JarvisSessionController.wordCount(""), 0)
    }
}

// MARK: - D-1: spoken cancel

@MainActor
final class JarvisCancelPhraseTests: XCTestCase {

    func testEveryCancelPhraseIsRecognized() {
        for phrase in JarvisSessionController.cancelPhrases {
            XCTAssertTrue(JarvisSessionController.isCancelPhrase(phrase), "\"\(phrase)\" must cancel")
        }
    }

    func testRecognizedThroughPunctuationAndCaseChurn() {
        XCTAssertTrue(JarvisSessionController.isCancelPhrase("Never mind!"))
    }

    func testTrailingCancelAbortsACommandAlreadyInFlight() {
        // The realistic shape: the user starts asking, sees the transcription go wrong, and says
        // "never mind" — the capture must abort rather than sending the whole thing.
        XCTAssertTrue(JarvisSessionController.isCancelPhrase("delete the build folder never mind"))
    }

    func testOrdinaryCommandsAreNotCancels() {
        XCTAssertFalse(JarvisSessionController.isCancelPhrase("run the tests"))
        XCTAssertFalse(JarvisSessionController.isCancelPhrase(""))
        XCTAssertFalse(JarvisSessionController.isCancelPhrase("never minding the warnings"))
    }
}

// MARK: - D-3: wake word vs. speech language

@MainActor
final class JarvisWakeWordLanguageTests: XCTestCase {

    func testUnsetOrEnglishLanguageCanMatch() {
        XCTAssertTrue(JarvisSessionController.wakeWordCanMatch(language: nil))
        XCTAssertTrue(JarvisSessionController.wakeWordCanMatch(language: ""))
        XCTAssertTrue(JarvisSessionController.wakeWordCanMatch(language: "en"))
        XCTAssertTrue(JarvisSessionController.wakeWordCanMatch(language: "en-US"))
    }

    func testNonEnglishLanguageCannotMatch() {
        // The silent-death case: the recognizer returns text in another script, no English
        // variant can ever match, and the orb looks alive while ignoring the user forever.
        for language in ["ja", "hi", "ru", "zh", "ar"] {
            XCTAssertFalse(JarvisSessionController.wakeWordCanMatch(language: language),
                           "\"\(language)\" must be reported as unable to match")
        }
    }
}

// MARK: - P0-1: the completion announcement must not lie

@MainActor
final class JarvisAnnouncementTests: XCTestCase {

    func testSuccessKeepsTheEstablishedPhrase() {
        XCTAssertEqual(JarvisSessionController.announcement(for: .completed, reason: nil),
                       JarvisSessionController.completionPhrase)
    }

    func testFailureDoesNotClaimSuccess() {
        // The defect this exists to pin: only `.cancelled` was branched, so a FAILED run
        // announced "Your task is completed" to a user with no other channel.
        let spoken = JarvisSessionController.announcement(for: .failed, reason: nil)
        XCTAssertNotEqual(spoken, JarvisSessionController.completionPhrase)
        XCTAssertTrue(spoken.lowercased().contains("didn't work"))
    }

    func testFailureSurfacesTheReasonWhenThereIsOne() {
        let spoken = JarvisSessionController.announcement(for: .failed, reason: "The model timed out")
        XCTAssertTrue(spoken.contains("The model timed out"))
    }

    /// ⚠️ Asserts the PROPERTY, not the literal. The exact wording changed in Phase 6 (it now
    /// offers the "what went wrong" follow-up); what must never change is that a blank reason
    /// produces a complete sentence instead of "That didn't work. ".
    func testBlankReasonDoesNotProduceADanglingSentence() {
        let spoken = JarvisSessionController.announcement(for: .failed, reason: "   ")
        XCTAssertTrue(spoken.hasSuffix("."), "A blank reason must still end the sentence: \(spoken)")
        XCTAssertFalse(spoken.hasSuffix("work. "), "The reason was blank — nothing should dangle after it.")
        XCTAssertTrue(spoken.lowercased().contains("didn't work"))
    }

    /// The failure path is the one place a voice-only user most needs a next step, and Phase 6
    /// gave them one instead of only pointing at a window they may not be looking at.
    func testFailureOffersTheSpokenFollowUp() {
        let spoken = JarvisSessionController.announcement(for: .failed, reason: nil)
        XCTAssertTrue(spoken.lowercased().contains("what went wrong"),
                      "A failed run should offer the spoken follow-up: \(spoken)")
    }

    func testWarningsOutcomeIsDistinctFromBothSuccessAndFailure() {
        let spoken = JarvisSessionController.announcement(for: .completedWithWarnings, reason: nil)
        XCTAssertNotEqual(spoken, JarvisSessionController.completionPhrase)
        XCTAssertNotEqual(spoken, JarvisSessionController.announcement(for: .failed, reason: nil))
    }

    func testNilOutcomeReportsUncertaintyRatherThanSuccess() {
        let spoken = JarvisSessionController.announcement(for: nil, reason: nil)
        XCTAssertNotEqual(spoken, JarvisSessionController.completionPhrase)
    }

    func testEveryOutcomeProducesANonEmptyPhrase() {
        for outcome in ExecutionOutcome.allCases {
            XCTAssertFalse(JarvisSessionController.announcement(for: outcome, reason: nil).isEmpty)
        }
    }
}
