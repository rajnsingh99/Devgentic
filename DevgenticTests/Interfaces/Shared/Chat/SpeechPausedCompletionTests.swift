// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
//
//  SpeechPausedCompletionTests.swift
//  DevgenticTests
//
//  [CF-22] `pauseSpeaking()` asks AVFoundation for `pauseSpeaking(at: .word)` and flips
//  `isPaused` immediately, but the request is only honoured at the NEXT word boundary. Press
//  Pause on the last word of a segment and the utterance FINISHES first — `didFinish` arrives
//  with `isPaused` already true, and `handleUtteranceFinished`'s only gate was `guard isActive`.
//  It spoke the next segment anyway: live audio under a transport showing Play, and the Play
//  the user then pressed found the synthesizer un-paused and spoke that same segment a SECOND
//  time (re-opening the Code Viewer with it, for a code block).
//
//  The decision is only reachable through a live `AVSpeechSynthesizer` delegate callback, so it
//  is extracted into `SpeechService.completionAction(...)` — a pure table — and that is what
//  these tests pin. That `handleUtteranceFinished` actually consults the table is covered in
//  `SpeechStaleCompletionTests`, which drives the handler through its test seam. What remains
//  unobservable is `resumeSpeaking` speaking the parked segment exactly once — that needs a real
//  synthesizer and audio output.
//

import XCTest
@testable import devgentic

@MainActor
final class SpeechPausedCompletionTests: XCTestCase {

    private typealias Action = SpeechService.UtteranceCompletionAction

    // MARK: - The row: a pause that lands as the segment ends

    /// The defect, stated: paused, more to say, nothing announced. Playback must move the
    /// playlist on but start NO audio. Before the fix this branch returned "speak it now".
    func testPausedWithMoreSegmentsHoldsInsteadOfSpeaking() {
        XCTAssertEqual(
            SpeechService.completionAction(hasPendingCodeBlock: false, isPaused: true,
                                           pauseOnCode: false, hasNextSegment: true),
            Action.holdAtNextSegment
        )
    }

    /// Control for the row: the same state with the pause NOT pressed keeps playing. If this
    /// ever returns `.holdAtNextSegment`, the fix has stopped normal playback dead.
    func testNotPausedWithMoreSegmentsSpeaksTheNextOne() {
        XCTAssertEqual(
            SpeechService.completionAction(hasPendingCodeBlock: false, isPaused: false,
                                           pauseOnCode: false, hasNextSegment: true),
            Action.speakNextSegment
        )
    }

    // MARK: - End of the playlist

    /// Nothing left to say ends the session whether or not a pause was pending: there is no
    /// segment to park on, and holding would leave `isActive` true forever with the island
    /// showing a transport for a finished message.
    func testLastSegmentFinishesEvenWhenPaused() {
        XCTAssertEqual(
            SpeechService.completionAction(hasPendingCodeBlock: false, isPaused: true,
                                           pauseOnCode: false, hasNextSegment: false),
            Action.finish
        )
        XCTAssertEqual(
            SpeechService.completionAction(hasPendingCodeBlock: false, isPaused: false,
                                           pauseOnCode: false, hasNextSegment: false),
            Action.finish
        )
    }

    // MARK: - The code-block half

    /// A code block still reaches the viewer when the user paused during its announcement —
    /// the hand-off belongs to the segment that just FINISHED — but playback then waits,
    /// exactly as pause-on-code would. Auto-resuming here was the worse half of the row: it
    /// armed the one-second delay task, so the pause was overridden a beat later.
    func testPauseDuringACodeAnnouncementOpensTheViewerThenHolds() {
        XCTAssertEqual(
            SpeechService.completionAction(hasPendingCodeBlock: true, isPaused: true,
                                           pauseOnCode: false, hasNextSegment: true),
            Action.openCodeViewerThenHold
        )
    }

    /// Pause-on-code, the pre-existing behaviour, is unchanged by the new `isPaused` term.
    func testPauseOnCodeHoldsAsBefore() {
        XCTAssertEqual(
            SpeechService.completionAction(hasPendingCodeBlock: true, isPaused: false,
                                           pauseOnCode: true, hasNextSegment: true),
            Action.openCodeViewerThenHold
        )
    }

    /// Neither flag set: announce, hand off, carry on after the delay.
    func testCodeBlockAutoResumesWhenNeitherFlagIsSet() {
        XCTAssertEqual(
            SpeechService.completionAction(hasPendingCodeBlock: true, isPaused: false,
                                           pauseOnCode: false, hasNextSegment: true),
            Action.openCodeViewerThenAutoResume
        )
    }

    /// A pending code block is never "the end": its own segment has to be handed over before
    /// the playlist can be judged exhausted, so `hasNextSegment` must not short-circuit it into
    /// `.finish` and drop the code on the floor.
    func testAPendingCodeBlockIsHandedOverEvenAsTheLastSegment() {
        XCTAssertEqual(
            SpeechService.completionAction(hasPendingCodeBlock: true, isPaused: false,
                                           pauseOnCode: false, hasNextSegment: false),
            Action.openCodeViewerThenAutoResume
        )
    }

    // MARK: - Whole table

    /// Every input combination maps to exactly one action, so a future edit that adds a case
    /// cannot leave a hole that falls through to "speak". Sixteen combinations, spelled out.
    func testEveryCombinationIsDecided() {
        var seen: Set<Action> = []
        for hasPendingCodeBlock in [true, false] {
            for isPaused in [true, false] {
                for pauseOnCode in [true, false] {
                    for hasNextSegment in [true, false] {
                        let action = SpeechService.completionAction(
                            hasPendingCodeBlock: hasPendingCodeBlock, isPaused: isPaused,
                            pauseOnCode: pauseOnCode, hasNextSegment: hasNextSegment)
                        seen.insert(action)
                        if hasPendingCodeBlock {
                            XCTAssertTrue(action == .openCodeViewerThenHold || action == .openCodeViewerThenAutoResume,
                                          "A pending code block must always be handed over (paused: \(isPaused), pauseOnCode: \(pauseOnCode), next: \(hasNextSegment))")
                        } else if !hasNextSegment {
                            XCTAssertEqual(action, .finish)
                        } else {
                            XCTAssertEqual(action, isPaused ? .holdAtNextSegment : .speakNextSegment)
                        }
                    }
                }
            }
        }
        XCTAssertEqual(seen.count, 5, "All five actions must be reachable; an unreachable one is a rule that can never fire")
    }
}
