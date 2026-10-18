// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
//
//  SpeechStaleCompletionTests.swift
//  DevgenticTests
//
//  Created by Raj Singh.
//

import XCTest
@testable import devgentic

@MainActor
final class SpeechStaleCompletionTests: XCTestCase {

    /// Three segments — prose, code, prose. `parseSegments` splits only on ``` fences, so a
    /// fence is the only way to get more than one segment out of a message.
    private let threeSegments = """
    Alpha segment.
    ```swift
    let x = 1
    ```
    Bravo segment.
    """

    /// `canPresentCodeViewer: false` keeps the middle segment from arming `pendingCodeBlock`,
    /// so these tests exercise the plain segment-to-segment path and post no
    /// `.speechOpenCodeViewer` notification into the rest of the suite.
    private func startThreeSegmentPlayback(_ service: SpeechService) {
        service.stop()
        service.speak(threeSegments, messageID: UUID(), canPresentCodeViewer: false)
    }

    override func tearDown() async throws {
        SpeechService.shared.stop()
    }

    // MARK: - The invariant

    /// ⚠️ THE PIN. Skip Forward once, then let the cancelled utterance's `didFinish` land.
    ///
    /// Before the fix this advanced the playlist a SECOND time: one press spoke segment 2 and
    /// then segment 3 over the top of it, and `clearUtteranceTracking` wiped the tracking for
    /// the segment that had just started.
    func testAStaleCompletionAfterASkipDoesNotAdvanceThePlaylistAgain() {
        let service = SpeechService.shared
        startThreeSegmentPlayback(service)

        XCTAssertEqual(service.totalSegmentCount, 3)
        XCTAssertEqual(service.currentSegmentIndex, 1)
        let cancelledGeneration = service.activeUtteranceGenerationForTesting
        XCTAssertNotNil(cancelledGeneration, "Segment 1 must be in flight for the skip to cancel anything")

        service.skipForward()

        XCTAssertEqual(service.currentSegmentIndex, 2, "Control: one press moves the playlist exactly one segment")
        let liveGeneration = service.activeUtteranceGenerationForTesting
        XCTAssertNotEqual(cancelledGeneration, liveGeneration,
                          "The skip must have handed a NEW utterance over — otherwise there is nothing for the guard to tell apart")

        // What macOS actually delivers for the utterance `skipForward` cancelled, arriving after
        // the replacement segment has already started speaking.
        service.deliverUtteranceCompletionForTesting(generation: cancelledGeneration)

        XCTAssertEqual(service.currentSegmentIndex, 2,
                       "A completion for the utterance the skip discarded must not move the playlist — segment 3 would start on top of segment 2")
        XCTAssertEqual(service.activeUtteranceGenerationForTesting, liveGeneration,
                       "…and must not clear the tracking of the segment that IS playing, or a later speed change can no longer restart it")
    }

    /// The anti-over-fix control: the guard must not swallow a real completion. If this fails,
    /// playback stops dead at segment 1 and never reaches the end of any message.
    func testTheInFlightUtterancesOwnCompletionStillAdvances() {
        let service = SpeechService.shared
        startThreeSegmentPlayback(service)

        let liveGeneration = service.activeUtteranceGenerationForTesting
        service.deliverUtteranceCompletionForTesting(generation: liveGeneration)

        XCTAssertEqual(service.currentSegmentIndex, 2,
                       "Segment 1 genuinely finished; the playlist must move on")
        XCTAssertTrue(service.isActive)
    }

    /// A generation is consumed exactly once — in the case where playback SPEAKS ON.
    ///
    /// ⚠️ This one does NOT discriminate the in-flight guard from a monotonic-counter guard:
    /// handling the first completion speaks the next segment, which bumps the counter too, so
    /// either design rejects the second delivery. `testAGenerationCannotCompleteTwiceWhilePARKED`
    /// below is the case that separates them; keep both.
    func testAGenerationCannotCompleteTwice() {
        let service = SpeechService.shared
        startThreeSegmentPlayback(service)

        let firstGeneration = service.activeUtteranceGenerationForTesting
        service.deliverUtteranceCompletionForTesting(generation: firstGeneration)
        XCTAssertEqual(service.currentSegmentIndex, 2)

        service.deliverUtteranceCompletionForTesting(generation: firstGeneration)
        XCTAssertEqual(service.currentSegmentIndex, 2,
                       "The second delivery for an already-completed utterance must be ignored")
    }

    /// ⚠️ THE CASE THAT DISCRIMINATES THE GUARD. When a completion PARKS the playlist — paused,
    /// so it advances the index and speaks nothing — the monotonic `utteranceGeneration` does not
    /// move, because no replacement utterance is created. A guard comparing the reported stamp
    /// against that counter would therefore still MATCH a second delivery for the generation that
    /// just completed, and advance a second time; on Play the reader would then skip a segment.
    /// The shipped guard compares against the IN-FLIGHT generation, which the first completion
    /// clears. Without this test, that simplification ships green.
    func testAGenerationCannotCompleteTwiceWhilePARKED() {
        let service = SpeechService.shared
        startThreeSegmentPlayback(service)

        let parkedGeneration = service.activeUtteranceGenerationForTesting
        XCTAssertNotNil(parkedGeneration)

        service.pauseSpeaking()
        service.deliverUtteranceCompletionForTesting(generation: parkedGeneration)

        let indexAfterPark = service.currentSegmentIndex
        XCTAssertNil(service.activeUtteranceGenerationForTesting,
                     "a park speaks nothing, so nothing is in flight — this is what the guard reads")

        service.deliverUtteranceCompletionForTesting(generation: parkedGeneration)
        XCTAssertEqual(service.currentSegmentIndex, indexAfterPark,
                       "a second delivery for the parked generation must not advance again")
    }

    /// Skip Backward has the mirror bug — it plays the previous segment and then immediately
    /// re-plays the one the user was leaving.
    func testAStaleCompletionAfterASkipBackwardDoesNotAdvanceThePlaylist() {
        let service = SpeechService.shared
        startThreeSegmentPlayback(service)
        service.skipForward()
        service.skipForward()
        XCTAssertEqual(service.currentSegmentIndex, 3)

        let cancelledGeneration = service.activeUtteranceGenerationForTesting
        service.skipBackward()
        XCTAssertEqual(service.currentSegmentIndex, 2)

        service.deliverUtteranceCompletionForTesting(generation: cancelledGeneration)

        XCTAssertEqual(service.currentSegmentIndex, 2,
                       "Skipping back and then hearing segment 3 again is the mirror of the skip-forward double advance")
    }

    // MARK: - The rule itself

    /// The guard, spelled out. Distinct generations throughout — two utterances that happen to
    /// carry the same number would be the same utterance.
    func testCompletionOwnershipRule() {
        XCTAssertTrue(SpeechService.completionBelongsToInFlightUtterance(reported: 7, inFlight: 7),
                      "The utterance in flight owns its own completion")
        XCTAssertFalse(SpeechService.completionBelongsToInFlightUtterance(reported: 6, inFlight: 7),
                       "A completion for an utterance a skip discarded belongs to nobody")
        XCTAssertFalse(SpeechService.completionBelongsToInFlightUtterance(reported: 6, inFlight: nil),
                       "Nothing is in flight, so nothing can have finished")
    }

    /// Unknown fails OPEN, back to the pre-stamp behaviour: `restartCurrentUtterance` calls the
    /// handler itself with no stamp (standing in for a `didFinish` it just made impossible), and
    /// an utterance that somehow reached the delegate unstamped must still be able to end its
    /// segment. A completion wrongly ignored parks playback forever; one wrongly honoured only
    /// skips a segment.
    func testAnUnstampedCompletionIsHonoured() {
        XCTAssertTrue(SpeechService.completionBelongsToInFlightUtterance(reported: nil, inFlight: 7))
        XCTAssertTrue(SpeechService.completionBelongsToInFlightUtterance(reported: nil, inFlight: nil))
    }
}
