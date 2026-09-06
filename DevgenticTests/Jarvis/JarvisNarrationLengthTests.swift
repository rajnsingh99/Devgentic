//
//  JarvisNarrationLengthTests.swift
//  DevgenticTests
//
//  "Just the gist" + "tell me more". The point of these two together is that brevity becomes a
//  CHOICE rather than a severed sentence — so what is pinned here is that the length request and
//  the cap agree, and that the held-back part is recoverable.
//

import XCTest
@testable import devgentic

@MainActor
final class JarvisNarrationLengthTests: XCTestCase {

    /// ⚠️ THE WHOLE DESIGN. A cap can only truncate; it cannot make the model concise. A "gist"
    /// mode implemented as a smaller cap over the same six-sentence request would end every turn
    /// in "there's more in the chat window" — the failure that forced the automatic cap from 4 up
    /// to 6 after the 2026-09-04 device test.
    func testGistAsksForABriefAnswerRatherThanTruncatingALongOne() {
        let gist = JarvisSessionController.spokenStyleHint(for: .gist).lowercased()
        XCTAssertTrue(gist.contains("one or two sentences"), gist)
        XCTAssertFalse(gist.contains("six sentences"), "The gist mode must not ask for six: \(gist)")
    }

    func testEverySpeakingModeStillAsksForSpeakableProse() {
        for mode in JarvisSpokenResponses.allCases where mode.speaksAnswer {
            let hint = JarvisSessionController.spokenStyleHint(for: mode).lowercased()
            XCTAssertTrue(hint.contains("no markdown"), "\(mode) lost the markdown ban")
            XCTAssertTrue(hint.contains("text-to-speech"), "\(mode) lost the spoken framing")
        }
    }

    /// The cap is a backstop behind the length request, not the mechanism — but it must still be
    /// small enough to bound a model that ignores the request.
    func testGistIsCappedButNotSilent() {
        guard let cap = JarvisSpokenResponses.gist.sentenceCap else {
            return XCTFail("Gist needs a backstop cap for a model that ignores the length request.")
        }
        XCTAssertGreaterThan(cap, 0, "A zero cap is 'Stay silent', which already exists.")
        XCTAssertLessThan(cap, JarvisSpokenResponses.automatic.sentenceCap ?? .max,
                          "Gist must be shorter than Automatic or it is not a distinct choice.")
    }

    func testTheSilentModeStillSpeaksNothing() {
        XCTAssertFalse(JarvisSpokenResponses.preferSilent.speaksAnswer)
        XCTAssertEqual(JarvisSpokenResponses.preferSilent.sentenceCap, 0)
    }

    func testReadTheWholeAnswerStillHasNoCap() {
        XCTAssertNil(JarvisSpokenResponses.preferSpoken.sentenceCap)
    }

    /// Every mode needs a distinct, non-empty title — a picker with two identical rows is broken.
    func testEveryModeIsDistinctlyLabelled() {
        let titles = JarvisSpokenResponses.allCases.map { "\($0.localizedTitle)" }
        XCTAssertEqual(Set(titles).count, titles.count, "Duplicate titles: \(titles)")
    }

    // MARK: - "tell me more"

    func testTheContinuationPhrasesAreRecognised() {
        for phrase in ["tell me more", "go on", "continue", "read the rest", "What else?"] {
            XCTAssertEqual(JarvisSessionController.voiceCommand(in: phrase), .tellMeMore,
                           "\(phrase) should ask for the rest of the answer")
        }
    }

    /// ⚠️ The standing rule for this vocabulary: a real request that merely CONTAINS a control
    /// phrase must reach the model rather than being swallowed as a command.
    func testARealRequestContainingAContinuationPhraseStillReachesTheModel() {
        XCTAssertNil(JarvisSessionController.voiceCommand(in: "tell me more about the deployment"))
        XCTAssertNil(JarvisSessionController.voiceCommand(in: "what else did the tests cover"))
    }

    /// The continuation must not collide with the existing vocabulary.
    func testContinuationDoesNotShadowAnotherCommand() {
        XCTAssertEqual(JarvisSessionController.voiceCommand(in: "repeat that"), .repeatAnswer)
        XCTAssertEqual(JarvisSessionController.voiceCommand(in: "what went wrong"), .whatWentWrong)
        XCTAssertEqual(JarvisSessionController.voiceCommand(in: "new conversation"), .newConversation)
    }
}

// MARK: - The remainder arithmetic

/// "Tell me more" recovers the held-back text by re-cutting the FINISHED answer and dropping what
/// was already heard. The offset is the whole feature, and it was wrong on the second call.
///
/// ⚠️ WHAT THESE DO NOT COVER, said plainly: `speakRemainder` itself reaches `AVSpeechSynthesizer`,
/// so driving it in a unit test would speak aloud. What is pinned here is the arithmetic and the
/// exact multi-call sequence that broke. The one live wire — that `speakRemainder` passes
/// `sentencesHeard` and not the per-pass counter — is guarded structurally instead: that counter is
/// `private` and named `sentencesThisPass`, so the wrong call site reads as wrong. A mutation check
/// confirmed these pure tests do NOT catch that substitution on their own.
@MainActor
final class JarvisRemainderArithmeticTests: XCTestCase {

    /// Ten sentences, each its own line so `cut` sees complete ones.
    private let answer = (1...10).map { "Sentence number \($0)." }.joined(separator: "\n") + "\n"

    private func remainder(alreadyHeard: Int) -> [String] {
        JarvisStreamingSpeaker.remainingSentences(of: answer, alreadyHeard: alreadyHeard)
    }

    func testTheAnswerCutsIntoTheSentencesTheseTestsAssume() {
        XCTAssertEqual(remainder(alreadyHeard: 0).count, 10)
    }

    /// ⚠️⚠️ THE REGRESSION. Gist speaks 2 of 10; the first "tell me more" speaks the other 8. The
    /// SECOND one must find nothing left — it used to drop by the previous pass's length (8),
    /// re-reading sentences 9 and 10 and never saying the answer was finished.
    func testASecondTellMeMoreFindsNothingLeft() {
        let firstPass = remainder(alreadyHeard: 2)
        XCTAssertEqual(firstPass.count, 8)
        XCTAssertEqual(firstPass.first, "Sentence number 3.")

        // The cumulative count after that pass — 2 heard + 8 spoken — not the pass's own length.
        let secondPass = remainder(alreadyHeard: 2 + firstPass.count)
        XCTAssertTrue(secondPass.isEmpty,
                      "A second 'tell me more' must find nothing left. Got: \(secondPass)")
    }

    /// The bug, stated as the value that used to be passed. Kept so the wrong offset can never be
    /// mistaken for a harmless off-by-a-few.
    func testTheOldPerPassOffsetWouldHaveReplayedHeardSentences() {
        let replayed = remainder(alreadyHeard: 8)   // what the per-pass counter held
        XCTAssertEqual(replayed, ["Sentence number 9.", "Sentence number 10."],
                       "This is what the user used to hear a second time — the test exists to name it.")
    }

    func testTheRemainderStartsExactlyWhereTheNarrationStopped() {
        XCTAssertEqual(remainder(alreadyHeard: 6).first, "Sentence number 7.")
        XCTAssertEqual(remainder(alreadyHeard: 6).count, 4)
    }

    func testNothingHeardYetYieldsTheWholeAnswer() {
        XCTAssertEqual(remainder(alreadyHeard: 0).count, 10)
    }

    /// An offset past the end is "nothing left", never a crash — `dropFirst` tolerates it, but the
    /// guard is explicit because a closing phrase used to inflate the count past the segment list.
    func testAnOffsetPastTheEndIsEmptyNotACrash() {
        XCTAssertTrue(remainder(alreadyHeard: 10).isEmpty)
        XCTAssertTrue(remainder(alreadyHeard: 99).isEmpty)
        XCTAssertTrue(remainder(alreadyHeard: -1).isEmpty)
    }

    func testAnEmptyAnswerHasNoRemainder() {
        XCTAssertTrue(JarvisStreamingSpeaker.remainingSentences(of: "", alreadyHeard: 0).isEmpty)
    }

    /// The remainder must be cut the same way the narration was, or the offsets refer to different
    /// things — a code fence collapses to ONE announcement in both, so the counts stay aligned.
    func testACodeFenceCountsAsOneSegmentInBothDirections() {
        let withCode = "First line.\n```\nlet x = 1\n```\nLast line.\n"
        let all = JarvisStreamingSpeaker.remainingSentences(of: withCode, alreadyHeard: 0)
        XCTAssertEqual(all, ["First line.", JarvisStreamingSpeaker.codeAnnouncement, "Last line."])
        XCTAssertEqual(JarvisStreamingSpeaker.remainingSentences(of: withCode, alreadyHeard: 2),
                       ["Last line."])
    }

    /// ⚠️ The wiring invariant, as far as it can be reached without instantiating a speech
    /// synthesiser: a fresh speaker has heard nothing, and `sentencesHeard` is the ONLY counter
    /// visible from outside — the per-pass one is private precisely so it cannot be mistaken for
    /// this. Driving the live path would create an `AVSpeechSynthesizer`, and a stray CoreAudio
    /// client is what wedged `coreaudiod` on this project twice; that is not worth a test.
    func testTheCumulativeCounterIsTheOneExposedToCutFrom() {
        let speaker = JarvisStreamingSpeaker()
        XCTAssertEqual(speaker.sentencesHeard, 0)
        XCTAssertFalse(speaker.heldSomethingBack)
    }
}
