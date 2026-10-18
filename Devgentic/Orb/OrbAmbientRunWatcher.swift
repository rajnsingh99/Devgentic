// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
//
//  OrbAmbientRunWatcher.swift
//  Devgentic
//
//  Created by Raj Singh.
//

import Foundation

/// Announces runs the user started by typing in the main window while the orb is open.
/// The only thing that speaks unprompted, so every rule favours silence: default off, opt-in threshold, and a dropped
/// announcement is always preferable to an interruption.
@MainActor
final class OrbAmbientRunWatcher: ActiveStreamMirrorDelegate {

    /// Called with the finished announcement. The controller decides whether it may be spoken.
    private let announce: (String, String) -> Void
    private let logger = DGLogger(category: "OrbAmbient")
    var correlationTag: String = ""

    /// This object's own start times: `ActiveStreamManager.streamStartedAt` is private and cleared before the fan-out.
    /// `ChatMessage.timestamp` is no substitute: it is fixed at message creation and stale after Redo or Resume.
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
        // Only a timestamp is recorded: `message.messageSource` is always `.localUI` here, so classify at the end event.
        // `startedBy` is ignored here; classification reads the agent message at `didEndStream`.
        guard OrbConfigManager.shared.ambientAnnouncements else { return }
        if startedAt.count >= Self.maxTrackedRuns, let oldest = startedAt.min(by: { $0.value < $1.value })?.key {
            startedAt.removeValue(forKey: oldest)
            logger.info("[ORB_AMBIENT]\(self.correlationTag) Dropped the oldest tracked run to stay under \(Self.maxTrackedRuns). CONSEQUENCE: that run will not be announced if it ever finishes.")
        }
        startedAt[message.id] = Date()
    }

    func activeStreamManager(_ manager: ActiveStreamManager, didEndStream message: ChatMessage) {
        // Cheap exclusions first: `didStartStream` records nothing when announcements are off or for Orb's own runs,
        // so the "start was never seen" branch must not report a cause for runs that were never candidates.
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
            // Several different rules return nil here; log the reason so "why didn't Orb say anything?" is answerable.
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
