// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
//
//  OrbConversationalTests.swift
//  DevgenticTests
//
//  Phase 2: the follow-up window, earcons, voice commands, and the spoken-style hint.
//  All pure — the parts that decide whether a spoken phrase reaches the model or is swallowed
//  by Orb are exactly the parts that must not be verified by talking at a laptop and hoping.
//

import XCTest
@testable import devgentic

// MARK: - Follow-up window

@MainActor
final class OrbFollowUpTests: XCTestCase {

    func testOffMeansNoWindow() {
        XCTAssertNil(OrbFollowUp.off.seconds)
    }

    func testWindowsAreOrderedAndBounded() {
        guard let short = OrbFollowUp.short.seconds, let long = OrbFollowUp.long.seconds else {
            return XCTFail("both windows should have a duration")
        }
        XCTAssertLessThan(short, long)
        // A window longer than the passive recycle interval could be cut short by the recycle
        // itself, which would look like Orb losing interest mid-sentence.
        XCTAssertLessThan(long, 45)
    }

    func testDefaultIsOnButShort() {
        // On by default: re-uttering the wake word before every sentence is the single most
        // conspicuous thing separating a voice trigger from a voice assistant. Short by default
        // because the microphone is open for the whole window.
        let saved = TestHost.defaults.object(forKey: AppSettings.orbFollowUpKey)
        TestHost.defaults.removeObject(forKey: AppSettings.orbFollowUpKey)
        defer { if let saved { TestHost.defaults.set(saved, forKey: AppSettings.orbFollowUpKey) } }
        XCTAssertEqual(OrbConfigManager.shared.followUp, .short)
    }
}

// MARK: - Earcons

@MainActor
final class OrbEarconTests: XCTestCase {

    func testOffPlaysNothing() {
        for cue in [OrbEarcon.listening, .captured, .failed, .interrupted] {
            XCTAssertFalse(OrbEarcons.off.plays(cue))
        }
    }

    func testSubtleAnswersOnlyDidItHearMe() {
        XCTAssertTrue(OrbEarcons.subtle.plays(.listening))
        XCTAssertTrue(OrbEarcons.subtle.plays(.captured))
        XCTAssertFalse(OrbEarcons.subtle.plays(.failed))
        XCTAssertFalse(OrbEarcons.subtle.plays(.interrupted))
    }

    func testFullPlaysEveryCue() {
        for cue in [OrbEarcon.listening, .captured, .failed, .interrupted] {
            XCTAssertTrue(OrbEarcons.full.plays(cue))
        }
    }

    func testEveryCueNamesADistinctSystemSound() {
        let names = [OrbEarcon.listening, .captured, .failed, .interrupted].map(\.systemSoundName)
        XCTAssertEqual(Set(names).count, names.count, "two cues that sound identical convey nothing")
    }
}

// MARK: - Voice commands

@MainActor
final class OrbVoiceCommandTests: XCTestCase {

    func testEveryDeclaredPhraseIsRecognized() {
        for phrase in OrbSessionController.repeatPhrases {
            XCTAssertEqual(OrbSessionController.voiceCommand(in: phrase), .repeatAnswer, phrase)
        }
        for phrase in OrbSessionController.newConversationPhrases {
            XCTAssertEqual(OrbSessionController.voiceCommand(in: phrase), .newConversation, phrase)
        }
    }

    func testRecognizedThroughPunctuationAndCasing() {
        XCTAssertEqual(OrbSessionController.voiceCommand(in: "Repeat that."), .repeatAnswer)
        XCTAssertEqual(OrbSessionController.voiceCommand(in: "  New Conversation!  "), .newConversation)
    }

    func testARealRequestContainingAControlWordIsNotSwallowed() {
        // ⚠️ The assertion that justifies whole-utterance matching. Suffix or substring matching
        // would send "repeat the test that failed" nowhere — the user would watch their request
        // vanish into a re-read of the previous answer, with no way to tell why.
        XCTAssertNil(OrbSessionController.voiceCommand(in: "repeat the test that failed"))
        XCTAssertNil(OrbSessionController.voiceCommand(in: "start over from the beginning of the file"))
        XCTAssertNil(OrbSessionController.voiceCommand(in: "say that again in the commit message"))
    }

    func testOrdinaryCommandsAreNotControlPhrases() {
        XCTAssertNil(OrbSessionController.voiceCommand(in: "run the tests"))
        XCTAssertNil(OrbSessionController.voiceCommand(in: ""))
    }

    func testControlPhrasesDoNotCollideWithCancelPhrases() {
        // Both are matched on the same normalized form; an overlap would make one unreachable
        // and which one wins would depend purely on check order.
        for phrase in OrbSessionController.cancelPhrases {
            XCTAssertNil(OrbSessionController.voiceCommand(in: phrase),
                         "\(phrase) is a cancel phrase and must not also be a control phrase")
        }
        for phrase in OrbSessionController.repeatPhrases + OrbSessionController.newConversationPhrases {
            XCTAssertFalse(OrbSessionController.isCancelPhrase(phrase),
                           "\(phrase) is a control phrase and must not also cancel")
        }
    }
}

// MARK: - Spoken-style hint

@MainActor
final class OrbSpokenStyleHintTests: XCTestCase {

    func testHintIsAppendedOnlyWhenTheAnswerWillBeSpoken() {
        let plain = OrbSessionController.decoratedQuery(for: "run the tests", mode: .preferSilent)
        XCTAssertEqual(plain, "run the tests", "a silent run must not pay for instructions nobody hears")

        let spoken = OrbSessionController.decoratedQuery(for: "run the tests", mode: .automatic)
        XCTAssertNotEqual(spoken, plain)
    }

    func testTheUsersOwnWordsSurviveVerbatimAtTheFront() {
        // ⚠️ The persisted message is the clean command; only the model's copy is decorated. If
        // the hint were prepended or interleaved the chat window and the model would disagree
        // about what was asked.
        let command = "delete the build folder"
        let decorated = OrbSessionController.decoratedQuery(for: command, mode: .automatic)
        XCTAssertTrue(decorated.hasPrefix(command))
    }

    func testHintActuallyAsksForSpeakableProse() {
        let hint = OrbSessionController.spokenStyleHint(for: .automatic).lowercased()
        XCTAssertTrue(hint.contains("no markdown"))
        XCTAssertTrue(hint.contains("bullet"))
        XCTAssertTrue(hint.contains("text-to-speech"))
    }

    func testHintAsksForBrevityAtTheSource() {
        // ⚠️ A sentence cap can only TRUNCATE; it cannot make the model concise. The 2026-09-04
        // device test hit the cap on BOTH turns because the answers ran to ~10 sentences, so the
        // narration always ended in "there's more in the chat window" — which reads as broken
        // narration rather than as a deliberate bound.
        XCTAssertTrue(OrbSessionController.spokenStyleHint(for: .automatic).lowercased().contains("six sentences"))
        // ⚠️ And "Just the gist" asks for a SHORT ANSWER, not the same answer with a smaller cap —
        // otherwise every turn ends in "there's more in the chat window".
        let gist = OrbSessionController.spokenStyleHint(for: .gist).lowercased()
        XCTAssertTrue(gist.contains("one or two sentences"), gist)
        XCTAssertFalse(gist.contains("six sentences"), gist)
    }
}
