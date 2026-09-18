// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
//
//  VoiceLifecycleTests.swift
//  DevgenticTests
//
//  Voice cluster (chat hardening round 3, 2026-07-19): V1/V2/V6 are guarded by
//  `VoiceSessionLedger` — the pure bookkeeping for the app-wide single Whisper
//  stream slot — tested here WITHOUT WhisperKit (loading a Whisper model in tests
//  is forbidden; see MEMORY.md). V7's transcript join is pinned against the live
//  display's rule (RED proven standalone: final gave "there.How" while the overlay
//  showed "there. How"). V5's synthesizer release is pinned via SpeechService's
//  `isSynthesizerLoaded` seam.
//
//  NOT covered here (needs the real engine → on-device): that the forced teardown
//  actually closes the AVAudioEngine, and the ⌘⇧V key-window gate.
//

import XCTest
@testable import devgentic

// MARK: - V2 / V6 / V1: the single-slot ledger

final class VoiceSessionLedgerTests: XCTestCase {

    private var ledger = VoiceSessionLedger()

    override func setUp() {
        super.setUp()
        ledger = VoiceSessionLedger()
    }

    // V2: one slot app-wide

    func testBeginClaimsFreeSlot() {
        let session = ledger.begin(owner: .mainComposer)
        XCTAssertNotNil(session)
        XCTAssertEqual(session?.owner, .mainComposer)
        XCTAssertTrue(ledger.isBusy)
    }

    func testSecondBeginIsRejectedWhileBusy() {
        _ = ledger.begin(owner: .mainComposer)

        XCTAssertNil(ledger.begin(owner: .quickAccess),
                     "A second surface must be REJECTED, not allowed to overwrite the live session — the overwrite is what orphaned a transcriber into a permanent decode loop (V2).")
        XCTAssertEqual(ledger.active?.owner, .mainComposer, "The original holder keeps the slot")
    }

    func testBeginWorksAgainAfterEnd() {
        let first = ledger.begin(owner: .mainComposer)!
        XCTAssertEqual(ledger.end(first.id), .finalized)

        let second = ledger.begin(owner: .orb)
        XCTAssertNotNil(second, "Ending the active session frees the slot")
        XCTAssertNotEqual(second?.id, first.id)
    }

    // V6: teardown is keyed to the session that started it

    func testEndOfStaleSessionIsRefused() {
        let first = ledger.begin(owner: .mainComposer)!
        XCTAssertEqual(ledger.end(first.id), .finalized)
        _ = ledger.begin(owner: .quickAccess)

        XCTAssertEqual(ledger.end(first.id), .stale,
                       "A stop resuming after its await must not clobber a session that no longer belongs to it (V6)")
        XCTAssertTrue(ledger.isBusy, "The successor session survives the stale teardown attempt")
    }

    func testDoubleEndIsStale() {
        let session = ledger.begin(owner: .mainComposer)!
        XCTAssertEqual(ledger.end(session.id), .finalized)
        XCTAssertEqual(ledger.end(session.id), .stale, "Double-stop race: only ONE teardown is authoritative")
    }

    // V1: telling a requested end apart from WhisperKit's swallowed-error break

    func testUnrequestedEndIsDetected() {
        let session = ledger.begin(owner: .mainComposer)!

        XCTAssertTrue(ledger.isUnrequestedEnd(session.id),
                      "Stream returned with no stop on record = WhisperKit broke its loop on a swallowed decode error with the mic still open (V1)")
    }

    func testRequestedStopIsNotAnAbnormalEnd() {
        let session = ledger.begin(owner: .mainComposer)!
        XCTAssertEqual(ledger.markStopRequested()?.id, session.id)

        XCTAssertFalse(ledger.isUnrequestedEnd(session.id),
                       "A stop on record means the return is the NORMAL path — flagging it would break every manual stop (control for the V1 detector)")
    }

    func testEndAfterFinalizeIsNotAbnormal() {
        let session = ledger.begin(owner: .mainComposer)!
        _ = ledger.markStopRequested()
        _ = ledger.end(session.id)

        XCTAssertFalse(ledger.isUnrequestedEnd(session.id),
                       "After the authoritative teardown, the blocking call's late return must be a no-op")
    }

    func testMarkStopRequestedOnIdleLedgerReturnsNil() {
        XCTAssertNil(ledger.markStopRequested(), "Stop with nothing active is a no-op, not a crash")
    }
}

// MARK: - V7: final transcript matches the live display

final class TranscriptJoinTests: XCTestCase {

    func testConfirmedAndPartialJoinWithSpace() {
        // RED proven standalone: raw concatenation gave "there.How" while the
        // overlay the user watched showed "there. How".
        let joined = StreamingTranscriptionState.joined(
            confirmed: "Send the report over there.",
            partial: "How about tomorrow"
        )
        XCTAssertEqual(joined, "Send the report over there. How about tomorrow")
    }

    func testFinalEqualsLiveDisplayForSameInputs() {
        let state = StreamingTranscriptionState(
            confirmedText: "First part.", partialText: "second part",
            bufferEnergy: [], isRecording: true, isSilenceDetected: false
        )
        XCTAssertEqual(
            state.fullText,
            StreamingTranscriptionState.joined(confirmed: "First part.", partial: "second part"),
            "The live overlay and the final transcript share ONE join rule — they had drifted (V7)"
        )
    }

    func testEmptyPartialAddsNoTrailingSpace() {
        XCTAssertEqual(StreamingTranscriptionState.joined(confirmed: "Hello there.", partial: ""), "Hello there.")
    }

    func testEmptyConfirmedUsesPartialAlone() {
        XCTAssertEqual(StreamingTranscriptionState.joined(confirmed: "", partial: "Hello"), "Hello")
    }

    func testWhitespaceRunsCollapse() {
        XCTAssertEqual(StreamingTranscriptionState.joined(confirmed: "  a   b ", partial: " c  "), "a b c")
    }

    func testBothEmptyYieldsEmpty() {
        XCTAssertEqual(StreamingTranscriptionState.joined(confirmed: "", partial: ""), "")
    }
}

// MARK: - V5: TTS synthesizer is released when idle

@MainActor
final class SpeechServiceLifecycleTests: XCTestCase {

    func testSynthesizerCreatedOnSpeakAndReleasedOnStop() {
        let service = SpeechService.shared
        service.stop() // clean slate (also proves stop-when-idle is a safe no-op)
        XCTAssertFalse(service.isSynthesizerLoaded, "Idle service must hold no CoreAudio output context (V5)")

        service.speak("Hello world.", messageID: UUID())
        XCTAssertTrue(service.isSynthesizerLoaded, "Control: speaking requires a live synthesizer — proves the seam can observe it at all")
        XCTAssertTrue(service.isActive)

        service.stop()
        XCTAssertFalse(service.isSynthesizerLoaded,
                       "Stop must RELEASE the synthesizer — holding it for the app lifetime is the documented CoreAudio mic-wedge pattern (V5)")
        XCTAssertFalse(service.isActive)
    }

    func testRepeatedStopIsIdempotent() {
        let service = SpeechService.shared
        service.stop()
        service.stop()
        XCTAssertFalse(service.isSynthesizerLoaded)
    }
}

// MARK: - Dead-mic detection (ported from Orb, 2026-07-19)

final class DeadMicDetectorTests: XCTestCase {

    func testSilentLongSessionIsDead() {
        var detector = DeadMicDetector()
        detector.beginSession()

        XCTAssertTrue(detector.assessSessionEnd(duration: 3.0),
                      "≥1s with zero energy samples = the engine opened but delivered nothing (_StartIO error 35 class)")
        XCTAssertEqual(detector.consecutiveDeadSessions, 1)
    }

    func testAudioMakesSessionLive() {
        var detector = DeadMicDetector()
        detector.beginSession()
        detector.recordAudioArrived()

        XCTAssertFalse(detector.assessSessionEnd(duration: 3.0),
                       "Control: energy samples prove the engine worked — never flag a live session")
        XCTAssertEqual(detector.consecutiveDeadSessions, 0)
    }

    func testQuickTapIsNotDead() {
        var detector = DeadMicDetector()
        detector.beginSession()

        XCTAssertFalse(detector.assessSessionEnd(duration: 0.4),
                       "A sub-threshold silent session is a rapid manual stop, not an engine failure — no false alarms on tap-tap")
        XCTAssertEqual(detector.consecutiveDeadSessions, 0)
    }

    func testConsecutiveDeadSessionsAccumulate() {
        var detector = DeadMicDetector()
        for _ in 0..<3 {
            detector.beginSession()
            _ = detector.assessSessionEnd(duration: 2.0)
        }
        XCTAssertEqual(detector.consecutiveDeadSessions, 3,
                       "The streak mirrors the on-device repro: three dead sessions in a row")
    }

    func testLiveSessionResetsTheStreak() {
        var detector = DeadMicDetector()
        detector.beginSession()
        _ = detector.assessSessionEnd(duration: 2.0)          // dead #1
        detector.beginSession()
        detector.recordAudioArrived()                          // recovery
        _ = detector.assessSessionEnd(duration: 2.0)

        XCTAssertEqual(detector.consecutiveDeadSessions, 0, "A working session ends the streak")
    }

    func testBeginSessionResetsAudioFlagOnly() {
        var detector = DeadMicDetector()
        detector.beginSession()
        detector.recordAudioArrived()
        detector.beginSession()

        XCTAssertFalse(detector.sessionSawAudio, "Each session must prove audio afresh — a prior live session is not evidence")
    }
}
