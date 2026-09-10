// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2026 Raj Singh
//
//  JarvisDeadMicrophoneTests.swift
//  DevgenticTests
//
//  The dead-microphone escalation ladder — the thing that turns "the orb looks fine and hears
//  nothing" into a visible NO AUDIO, a reachable "Repair Audio…", and eventually OFFLINE.
//
//  ⚠️ WHY THIS FILE EXISTS AT ALL. The ladder was written inline in the WhisperKit loop and simply
//  never written in the Apple Speech one, so that path re-armed forever on a healthy-looking
//  STANDBY — with the only remedy for a `coreaudiod` wedge unreachable, because the menu item is
//  gated on the flags this escalation sets. Two copies of a policy is how one of them goes missing;
//  what is pinned here is the ONE function both loops now call.
//

import XCTest
@testable import devgentic

@MainActor
final class JarvisDeadSessionLadderTests: XCTestCase {

    private func outcome(_ consecutive: Int) -> JarvisSessionController.DeadSessionOutcome {
        JarvisSessionController.deadSessionOutcome(consecutive: consecutive)
    }

    /// The first failure must NOT be terminal. A single `-10877` is often transient engine
    /// spin-up noise that the very next attempt survives.
    func testTheFirstDeadSessionRetries() {
        guard case .retry = outcome(1) else {
            return XCTFail("A single dead session must retry, not give up — the first one is usually transient.")
        }
    }

    /// ...but it must not retry forever either. Sitting on STANDBY over a dead microphone is the
    /// failure this whole ladder exists to end.
    func testItEventuallyGivesUpRatherThanPretendingToListen() {
        var consecutive = 1
        while consecutive < 50, outcome(consecutive) != .giveUp { consecutive += 1 }
        XCTAssertEqual(outcome(consecutive), .giveUp,
                       "The ladder must terminate; it retried \(consecutive) times without giving up.")
        XCTAssertLessThanOrEqual(consecutive, 6,
                                 "Giving up after \(consecutive) attempts leaves the user staring at a healthy-looking orb for too long.")
    }

    /// Once terminal, always terminal — a later attempt must not resurrect the retry path.
    func testGivingUpIsMonotonic() {
        var seenGiveUp = false
        for consecutive in 0...20 {
            if outcome(consecutive) == .giveUp { seenGiveUp = true }
            else if seenGiveUp {
                XCTFail("Attempt \(consecutive) retried after the ladder had already given up.")
            }
        }
        XCTAssertTrue(seenGiveUp)
    }

    /// The backoff exists to give the HAL progressively longer to release a device another app is
    /// holding, so it must actually climb.
    func testTheBackoffClimbsWithEachFailure() {
        var previous = -1.0
        for consecutive in 1...3 {
            guard case .retry(let backoff) = outcome(consecutive) else {
                return XCTFail("attempt \(consecutive) should still be retrying")
            }
            XCTAssertGreaterThan(backoff, previous,
                                 "Backoff must climb: attempt \(consecutive) waits \(backoff)s after \(previous)s.")
            previous = backoff
        }
    }

    /// A backoff long enough to be mistaken for a hang defeats the purpose — the user is standing
    /// there waiting for the orb to react.
    func testTheBackoffStaysShortEnoughToNotLookLikeAHang() {
        for consecutive in 1...5 {
            if case .retry(let backoff) = outcome(consecutive) {
                XCTAssertLessThan(backoff, 5.0, "attempt \(consecutive) waits \(backoff)s")
            }
        }
    }

    /// ⚠️⚠️ THE ORDERING THAT MAKES THE WARNING REACHABLE. On the Apple Speech path a dead session
    /// is ended by `deadAudioSessionLimit` so the ladder above can run — but the NO AUDIO warning
    /// (and with it the "Repair Audio…" menu item) is raised at `deadAudioWarningDelay` by the same
    /// ticker. Invert these and the session ends before the warning is ever set, which is exactly
    /// the state this whole fix existed to escape: an orb that looks healthy with no way to repair.
    func testTheWarningFiresBeforeADeadSessionIsEnded() {
        XCTAssertLessThan(JarvisSessionController.deadAudioWarningDelay,
                          JarvisSessionController.deadAudioSessionLimit,
                          "The NO AUDIO warning must be raised before the session that would have raised it is torn down.")
    }

    /// Long enough that a healthy engine — which delivers buffers within ~100 ms even in silence —
    /// can never be mistaken for a dead one.
    func testTheWarningDelayCannotFalsePositiveOnAQuietRoom() {
        XCTAssertGreaterThanOrEqual(JarvisSessionController.deadAudioWarningDelay, 1.0)
    }

    /// ⚠️ Both loops send the user to the same place. A second wording would mean the advice
    /// depended on which recognizer happened to be selected — and the Apple path had no message
    /// at all before this.
    func testTheUnavailableReasonNamesACauseAndAFix() {
        let reason = JarvisSessionController.deadAudioUnavailableReason
        XCTAssertTrue(reason.lowercased().contains("no audio"), reason)
        XCTAssertTrue(reason.lowercased().contains("holding the input device"),
                      "The reason must name the usual cause: \(reason)")
        XCTAssertTrue(reason.contains("System Settings"),
                      "The reason must give the user somewhere to go: \(reason)")
    }
}

// MARK: - Handing the input device back

/// When the panel-scoped audio engine is released mid-session.
///
/// ⚠️ THESE PIN A REJECTED DESIGN AS WELL AS THE ACCEPTED ONE. The engine is panel-scoped, and a
/// live `AVAudioEngine` at process death wedges `coreaudiod` app-wide — so "release it on the
/// longest idle" is a tempting change that has been made and reverted in review twice. The longest
/// parks are exactly the ones where releasing is unsafe; the reasons are on
/// `releasesEngineOnEntry(to:)` and a failure here should send you there before you change it.
@MainActor
final class JarvisIdleEngineReleaseTests: XCTestCase {

    func testTheOfflineStageHandsTheDeviceBack() {
        XCTAssertTrue(JarvisSessionController.releasesEngineOnEntry(
            to: .voiceUnavailable(reason: "The microphone opened but delivered no audio.")),
            "An OFFLINE orb left overnight is the longest-lived warm-engine window there is, and the engine is provably useless in it.")
    }

    /// The reason string is part of the case, so the policy must not accidentally key on one.
    func testEveryUnavailableReasonReleases() {
        for reason in ["Microphone access is denied.", "", "Apple's speech recognizer isn't available."] {
            XCTAssertTrue(JarvisSessionController.releasesEngineOnEntry(to: .voiceUnavailable(reason: reason)))
        }
    }

    /// ⚠️⚠️ THE REJECTED HALF. `.awaitingApproval` and `.executing` are LONGER parks than the one
    /// above, and releasing in them is still wrong — the "only when no approval window is armed"
    /// guard is dead code, the release lands on a live narration queue and crashes on the next
    /// sentence, and the paired re-warm is refused because `stopListening()` does not await
    /// `stopStreaming`. If you are here because this test failed, read
    /// `releasesEngineOnEntry(to:)` and solve all three before changing it.
    func testTheLongerParksDeliberatelyDoNotRelease() {
        XCTAssertFalse(JarvisSessionController.releasesEngineOnEntry(to: .awaitingApproval),
                       "Releasing here fires on every park, including armed spoken-approval windows, and can crash mid-narration.")
        XCTAssertFalse(JarvisSessionController.releasesEngineOnEntry(to: .executing),
                       "A run in flight is still narrating; releasing under the speaker's queue is the crash path.")
    }

    /// No listening stage may release — the engine is what capture is running on.
    func testNoListeningStageReleasesTheEngineUnderItself() {
        for stage in [JarvisStage.passiveListening, .commandCapture, .followUpWindow] {
            XCTAssertFalse(JarvisSessionController.releasesEngineOnEntry(to: stage),
                           "\(stage) holds the microphone open; releasing here would deafen it.")
        }
    }

    /// The startup stages are handled by their own explicit paths (`selectProfile` warms,
    /// `requestProfileSwitch` releases), so the funnel must not double up on them.
    func testTheStartupStagesAreLeftToTheirOwnPaths() {
        XCTAssertFalse(JarvisSessionController.releasesEngineOnEntry(to: .selectingProfile))
        XCTAssertFalse(JarvisSessionController.releasesEngineOnEntry(to: .welcoming))
        XCTAssertFalse(JarvisSessionController.releasesEngineOnEntry(to: .announcing))
    }

    /// ⚠️ `releaseWhenIdle` must NOT early-return when no engine is up: `processor` is nil while a
    /// warm is IN FLIGHT, and that is precisely the window where an idle park must cancel it —
    /// otherwise the build completes and installs a live engine into the idle the call exists to
    /// prevent. Safe to call here: with nothing warm it only logs and cancels.
    func testReleasingWhileIdleIsSafeAndUnconditionalWhenNothingIsUp() {
        JarvisDuplexAudio.shared.releaseWhenIdle(reason: "unit test — nothing warm")
        XCTAssertFalse(JarvisDuplexAudio.shared.isWarm)
        XCTAssertFalse(JarvisDuplexAudio.shared.isEchoCancelling)
        XCTAssertNil(JarvisDuplexAudio.shared.playbackTarget)
    }
}
