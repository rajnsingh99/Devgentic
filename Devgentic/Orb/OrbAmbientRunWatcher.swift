// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
//
//  OrbAmbientRunWatcher.swift
//  Devgentic
//
//  [Phase 6 · F3] Announces runs the user started by TYPING, while the orb is open.
//
//  WHY THIS IS THE FEATURE THAT JUSTIFIES THE ORB. Between commands, an open Orb panel does
//  nothing — it is a listening indicator with no reason to be on screen. But the runs a developer
//  actually cares about are usually the ones they launched in the main window and then walked away
//  from. This is the only thing Orb does that is worth having open while you work.
//
//  ⚠️ IT IS ALSO THE ONLY THING THAT SPEAKS UNPROMPTED, so every decision here is biased toward
//  staying quiet. Default off; opt-in threshold; four independent reasons to say nothing; and a
//  hard rule that a dropped announcement is always preferable to an interruption.
//
//  THE FOUR SILENCE RULES, each from a specific failure it would otherwise cause:
//   1. NO OBSERVED START, NO ANNOUNCEMENT. A run this object did not see begin has no duration, so
//      it cannot pass the threshold. This covers any run already in flight when the panel opened.
//      ⚠️ IT DOES NOT COVER RESUME OR REDO, and the comment here used to claim it did.
//      `startMessageStream` fires `didStartStream` unconditionally — including on the `updating:`
//      path that Resume and Regenerate use — so the start IS observed. Combined with
//      `messageSource` being transient (a resumed scheduled run decodes as `.localUI`), rule 3
//      could not recognise it. Rule 5 below is what actually covers that case.
//   2. NOT ORB'S OWN. He already announces those; saying it twice is worse than not at all.
//   3. NOT SCHEDULED. `MessageSource.scheduled` exists for exactly this: "the task you started
//      just finished" is a lie when nobody started it, and the user may be asleep.
//   4. NOT WHILE SPEAKING OR LISTENING. Enforced in `speakAmbient`, not here.
//   5. NOT A RESUMED OR REGENERATED RUN. Its message was created long before this start, and its
//      true origin is unrecoverable — `messageSource` does not persist, so a scheduled task
//      resumed the next morning looks exactly like something the user just typed. "The task you
//      started just finished" is a guess there, and rule 3 exists precisely to avoid that guess.
//

import Foundation

@MainActor
final class OrbAmbientRunWatcher: ActiveStreamMirrorDelegate {

    /// Called with the finished announcement. The controller decides whether it may be spoken.
    private let announce: (String, String) -> Void
    private let logger = DGLogger(category: "OrbAmbient")
    var correlationTag: String = ""

    /// ⚠️ This object's OWN start times, not the manager's.
    ///
    /// `ActiveStreamManager.streamStartedAt` is private, and it is `removeValue`d one line BEFORE
    /// the mirror fan-out — so by the time `didEndStream` arrives the manager has already
    /// forgotten when the run began. `ChatMessage.timestamp` is no substitute either: it is a
    /// `let` from message creation, which Redo and Resume make hours stale.
    private var startedAt: [UUID: Date] = [:]

    /// Bounds the map if a run somehow never ends (a crash mid-stream, a cancelled task that
    /// skips finalize). Without this the orb accumulates one entry per run for as long as it is
    /// open — small, but unbounded is unbounded.
    private static let maxTrackedRuns = 64

    /// How far a run's start may trail its message's creation before it is treated as a resume or
    /// a regenerate. Generous: a normal run starts within seconds of its message, and the only
    /// cost of being wrong in this direction is one un-announced run.
    private static let resumeDetectionWindow: TimeInterval = 300

    init(announce: @escaping (String, String) -> Void) {
        self.announce = announce
    }

    // MARK: - ActiveStreamMirrorDelegate

    func activeStreamManager(_ manager: ActiveStreamManager, didStartStream message: ChatMessage,
                             startedBy: MessageSource, for conversationID: UUID) {
        // ⚠️ Only a timestamp is recorded here. `message.messageSource` is ALWAYS `.localUI` at this
        // point — every caller assigns it after `startMessageStream` returns — so classification
        // has to wait for the end event.
        //
        // ⚠️ `startedBy` NOW CARRIES THE ANSWER, and this watcher deliberately ignores it: its
        // classification reads the AGENT message at `didEndStream` (see `announce`), and switching
        // to the start value would change which runs Orb speaks. The parameter exists for
        // `RemoteMirrorService`, which must decide at START whether a run may leave the machine.
        guard OrbConfigManager.shared.ambientAnnouncements else { return }
        if startedAt.count >= Self.maxTrackedRuns, let oldest = startedAt.min(by: { $0.value < $1.value })?.key {
            startedAt.removeValue(forKey: oldest)
            logger.info("[ORB_AMBIENT]\(self.correlationTag) Dropped the oldest tracked run to stay under \(Self.maxTrackedRuns). CONSEQUENCE: that run will not be announced if it ever finishes.")
        }
        startedAt[message.id] = Date()
    }

    func activeStreamManager(_ manager: ActiveStreamManager, didEndStream message: ChatMessage) {
        // ⚠️ Cheap exclusions FIRST. `didStartStream` records nothing when announcements are off
        // or for Orb's own runs, so the "start was never seen" branch below fired on every
        // single turn and reported a misleading cause for something that was never a candidate.
        guard OrbConfigManager.shared.ambientAnnouncements else {
            // A start WAS recorded means announcements were on when the run began and were
            // switched off mid-run — the only case worth a line, and only then.
            if startedAt.removeValue(forKey: message.id) != nil {
                logger.info("[ORB_AMBIENT]\(self.correlationTag) Run \(message.id.uuidString.prefix(4)) finished but announcements were switched off mid-run. CONSEQUENCE: nothing is spoken.")
            }
            return
        }
        guard message.messageSource != .orb else {
            startedAt.removeValue(forKey: message.id)
            return
        }

        guard let started = startedAt.removeValue(forKey: message.id) else {
            // Rule 1. Not an error — the common causes are a resumed run and a run that predates
            // the panel — but it IS the reason nothing is said, so it is worth a line.
            logger.info("[ORB_AMBIENT]\(self.correlationTag) Run \(message.id.uuidString.prefix(4)) ended but its start was never seen. CONSEQUENCE: not announced — without a start there is no duration to measure against the threshold.")
            return
        }
        // Rule 5. The message predates its own run by more than a turn could explain, so this is a
        // Resume or a Regenerate and the source we can read is not the source that started it.
        let age = started.timeIntervalSince(message.timestamp)
        if age > Self.resumeDetectionWindow {
            logger.info("[ORB_AMBIENT]\(self.correlationTag) Not announcing run \(message.id.uuidString.prefix(4)) — its message is \(Int(age / 60)) minute(s) older than the run, so this is a resume or a regenerate and the original source is unrecoverable. CONSEQUENCE: nothing is spoken; announcing it could claim a scheduled task was something the user started.")
            return
        }

        let elapsed = Date().timeIntervalSince(started)
        let threshold = OrbConfigManager.shared.ambientThresholdSeconds
        guard let phrase = Self.announcement(
            source: message.messageSource,
            outcome: message.terminalOutcome,
            elapsed: elapsed,
            threshold: threshold
        ) else {
            // ⚠️ Four different rules return nil here. Collapsing them into a silent `return` made
            // "why didn't Orb say anything?" unanswerable from a log — and three of the four
            // are correct behaviour the reader needs to be able to recognise as such.
            logger.info("[ORB_AMBIENT]\(self.correlationTag) Not announcing run \(message.id.uuidString.prefix(4)) — \(Self.silenceReason(source: message.messageSource, outcome: message.terminalOutcome, elapsed: elapsed, threshold: threshold)). CONSEQUENCE: nothing is spoken; this is the policy working, not a failure.")
            return
        }

        announce(phrase, "run finished after \(Int(elapsed))s, source \(message.messageSource.rawValue)")
    }

    // MARK: - Policy

    /// Why `announcement` returned nil. Kept beside it so the two cannot drift — a log that
    /// names a different rule than the one that fired is worse than no log.
    nonisolated static func silenceReason(source: MessageSource,
                                          outcome: ExecutionOutcome?,
                                          elapsed: TimeInterval,
                                          threshold: TimeInterval) -> String {
        if source == .orb { return "it was Orb's own run, already announced by the turn itself" }
        if source == .scheduled { return "it was a scheduled run and nobody is waiting for it" }
        if elapsed < threshold { return "it took \(Int(elapsed))s, under the \(Int(threshold))s threshold" }
        if outcome == .cancelled { return "the user cancelled it themselves" }
        return "no rule matched — this is unexpected and worth investigating"
    }

    /// What to say about a finished run, or nil to stay silent. Pure — the whole decision is
    /// testable without a stream, a clock or an audio device.
    nonisolated static func announcement(source: MessageSource,
                                         outcome: ExecutionOutcome?,
                                         elapsed: TimeInterval,
                                         threshold: TimeInterval) -> String? {
        // Rule 2: Orb announces his own runs through the turn machinery.
        guard source != .orb else { return nil }
        // Rule 3: nobody started a scheduled run, so nobody is waiting for it.
        guard source != .scheduled else { return nil }
        // Below the threshold the user is still watching the window; an announcement tells them
        // nothing they cannot already see.
        guard elapsed >= threshold else { return nil }
        // A run the user cancelled themselves needs no announcement — they were present for it.
        guard outcome != .cancelled else { return nil }

        switch outcome {
        case .completed:
            return String(localized: "Your task in the main window finished.")
        case .completedWithWarnings:
            return String(localized: "Your task in the main window finished, but not cleanly.")
        case .failed:
            return String(localized: "Your task in the main window failed.")
        case .timedOut:
            return String(localized: "Your task in the main window hit its time limit and was stopped.")
        case .cancelled:
            return nil
        case nil:
            // No stamped outcome means the run ended by a path that never finalized. Saying
            // "finished" would assert more than is known.
            return String(localized: "Your task in the main window stopped.")
        }
    }
}
