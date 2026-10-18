// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
//
//  PairingAttemptPolicy.swift
//  Devgentic
//
//  Created by Raj Singh.
//

import Foundation
import os

/// Tells a wrong PIN apart from ordinary chatter during a pairing window, so failed attempts can be
/// logged without logging every message. A message shaped like `PAIR <something>` with the wrong digits
/// is a failed attempt; the attempted digits are never recorded.
enum PairingAttemptPolicy {

    /// What an inbound message during a pairing window is.
    enum Attempt: Equatable, Sendable {

        /// The expected PIN, exactly. The service pairs on this.
        case matched

        /// Shaped like a pairing command, but not this window's PIN. Worth a line.
        case wrongPIN

        /// Ordinary conversation; deliberately not logged.
        case unrelated
    }

    // Why: the trailing space is load-bearing: without it "PAIRING SCHEDULED FOR FRIDAY" classifies as a failed
    // attempt.
    /// The prefix a pairing command starts with, once normalized.
    static let commandPrefix = "PAIR "

    // Why: shared so the classifier cannot disagree with the services' own match.
    /// Normalization matching what all three pairing services apply before comparing.
    nonisolated static func normalize(_ text: String) -> String {
        text.uppercased().trimmingCharacters(in: .whitespaces)
    }

    /// Classifies one inbound message against the PIN this window is waiting for.
    /// - Parameter expectedPIN: the window's PIN; required, because each service has its own window.
    nonisolated static func classify(_ text: String, expectedPIN: String) -> Attempt {
        let normalized = normalize(text)
        if normalized == commandPrefix + expectedPIN { return .matched }
        // The prefix alone is the signal, not prefix plus six digits: a fumbled format is still a pairing
        // attempt.
        return normalized.hasPrefix(commandPrefix) ? .wrongPIN : .unrelated
    }
}

// MARK: - Lockout

/// Failed attempts within one pairing window, counted per origin and discarded with the window.
/// Per origin, not per window: a window-wide lockout would let a stranger end the user's pairing in a
/// few messages.
struct PairingAttemptLedger {

    /// Wrong PINs one origin may send before it is ignored for the rest of the window.
    /// Generous on purpose: against a 900,000-value space the cap barely matters, but it decides how a
    /// fat-fingered user is treated.
    static let attemptsPerOrigin = 10

    /// What the caller should do with this origin now.
    enum Standing: Equatable, Sendable {
        /// Keep listening to it. Carries how many wrong PINs remain before it is ignored.
        case listening(remaining: Int)
        /// Ignore everything further from this origin for the rest of the window.
        case blocked
    }

    private var failures: [String: Int] = [:]

    init() {}

    /// Whether this origin has already spent its attempts.
    /// Checked before the PIN is compared, so a blocked origin cannot pair even with the correct PIN.
    func isBlocked(_ origin: String) -> Bool {
        (failures[origin] ?? 0) >= Self.attemptsPerOrigin
    }

    /// Records one wrong PIN from `origin` and reports where that leaves it.
    mutating func recordFailure(from origin: String) -> Standing {
        let count = (failures[origin] ?? 0) + 1
        failures[origin] = count
        return count >= Self.attemptsPerOrigin
            ? .blocked
            : .listening(remaining: Self.attemptsPerOrigin - count)
    }

    /// Total wrong PINs seen this window, across every origin — for the log line only.
    var totalFailures: Int { failures.values.reduce(0, +) }

    /// How many distinct origins have guessed; ten failures from one chat is a typo, from ten chats it is
    /// not.
    var distinctOrigins: Int { failures.count }
}

// MARK: - Window Expiry

/// What happens when a pairing window runs out of time, shared by all three services so a fix lands
/// everywhere.
@MainActor
enum PairingWindowExpiry {

    /// The watchdog's wait, shared by all three services so the unit conversion exists once.
    /// Takes seconds and sleeps on a `Duration`; hand-converting to nanoseconds with `??` mis-binds and
    /// expires the window instantly.
    nonisolated static func waitOutWindow(_ timeout: TimeInterval) async {
        try? await Task.sleep(for: .seconds(timeout))
    }

    /// Ends an expired window, and only if it is still the live one (`connectionState` still names this
    /// PIN). Never deletes credentials (only `disconnect()` does) and reports `.error(...)` rather than a
    /// bare `.disconnected`.
    static func expire(pin: String,
                       platform: String,
                       timeout: TimeInterval,
                       state keyPath: ReferenceWritableKeyPath<ChatOpsConfigManager, ChatOpsConnectionState>,
                       config: ChatOpsConfigManager,
                       logger: DGLogger) {
        guard case .awaitingPairing(let livePIN) = config[keyPath: keyPath], livePIN == pin else {
            logger.info("[CHATOPS] A \(platform) pairing window expired but is no longer the live one, so it changed nothing. CONSEQUENCE: none — and that is the point. This window was superseded (the user started another, or pairing already completed); before this check an orphaned window's timeout reset the connection state and DELETED the bot token belonging to the newer pairing.")
            return
        }

        config[keyPath: keyPath] = .error("Pairing timed out — no PIN arrived within 5 minutes. Start pairing again.")
        logger.error("[CHATOPS] The \(platform) pairing window expired after \(timeout)s with no matching PIN. CONSEQUENCE: the PIN is dead and pairing did not complete; the validated token is deliberately KEPT so the user does not have to paste it again, and the Settings pane now says the window timed out rather than silently resetting to 'Disconnected'.")
    }
}
