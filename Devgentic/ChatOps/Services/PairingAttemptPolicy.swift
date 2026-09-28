// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
//
//  PairingAttemptPolicy.swift
//  Devgentic
//
//  Telling a wrong PIN apart from ordinary chatter, during a pairing window.
//
//  ⚠️⚠️ WHY THIS DISTINCTION IS THE WHOLE POINT. All three pairing services dropped a non-matching
//  message on a bare `continue`, so a failed PIN attempt left no trace anywhere — you could not tell
//  that anyone had tried, and there was no data from which to justify a lockout threshold.
//
//  ⚠️ BUT LOGGING EVERY NON-MATCH WOULD BE WORSE THAN LOGGING NOTHING. A pairing window is five
//  minutes of a live chat, and most of what arrives is unrelated conversation. A line per message
//  would bury the one event that matters in exactly the traffic it needs to stand out from — which
//  is why the three `continue`s were defensible as written, and why this is a classifier rather than
//  a log statement. A message shaped like `PAIR <something>` with the wrong digits is an unambiguous
//  failed attempt; "lunch at 1?" is not.
//
//  ⚠️ THE ATTEMPTED DIGITS ARE DELIBERATELY NOT CARRIED. They are useless for detection — a count
//  and an origin are what show a burst — and a mistyped attempt is one character from the real PIN,
//  so recording them writes a near-secret into a log that ends up in diagnostic bundles.
//
//  ⚠️ NOT A GATE. This classifies; it does not decide whether to accept a pairing. The matching
//  comparison stays where it is, in each service, byte-identical to what shipped.
//

import Foundation
import os

enum PairingAttemptPolicy {

    /// What an inbound message during a pairing window is.
    enum Attempt: Equatable, Sendable {

        /// The expected PIN, exactly. The service pairs on this.
        case matched

        /// Shaped like a pairing command, but not this window's PIN. Worth a line.
        case wrongPIN

        /// Ordinary conversation. Deliberately NOT logged — see this file's header.
        case unrelated
    }

    /// The prefix a pairing command starts with, once normalized.
    ///
    /// ⚠️ THE TRAILING SPACE IS LOAD-BEARING. Without it a message reading "PAIRING SCHEDULED FOR
    /// FRIDAY" classifies as a failed attempt, and the log fills with the chatter this exists to
    /// stay out of.
    static let commandPrefix = "PAIR "

    /// Normalization, matching what all three services already apply before comparing.
    ///
    /// ⚠️ SHARED SO THE CLASSIFIER CANNOT DISAGREE WITH THE MATCH. If this normalized differently
    /// from the services, a message they accepted could be logged as a failure — or worse, a real
    /// failed attempt could classify as `.matched` and never be reported.
    nonisolated static func normalize(_ text: String) -> String {
        text.uppercased().trimmingCharacters(in: .whitespaces)
    }

    /// Classifies one inbound message against the PIN this window is waiting for.
    ///
    /// - Parameter expectedPIN: the window's PIN. ⚠️ REQUIRED, not read from a shared config: the
    ///   classifier must answer for the window the caller is actually in, and three services with
    ///   three separate windows share this function.
    nonisolated static func classify(_ text: String, expectedPIN: String) -> Attempt {
        let normalized = normalize(text)
        if normalized == commandPrefix + expectedPIN { return .matched }
        // ⚠️ THE PREFIX ALONE IS THE SIGNAL, not "prefix plus six digits". Someone fumbling the
        // format ("PAIR 12345", "PAIR abc123") is still someone trying to pair, and a classifier
        // that required well-formed digits would miss precisely the attempts worth seeing.
        return normalized.hasPrefix(commandPrefix) ? .wrongPIN : .unrelated
    }
}

// MARK: - Lockout

/// Failed attempts within one pairing window, counted per origin.
///
/// ⚠️⚠️ PER ORIGIN, NOT PER WINDOW — AND THE OBVIOUS DESIGN IS STRICTLY WORSE THAN NO LOCKOUT AT
/// ALL. "Abort the window after N failures" converts an impractical attack into a trivial one:
/// guessing needs roughly 9,000 messages in 300 seconds to reach even a 1% chance, but a
/// window-wide lockout lets a stranger end the user's pairing with FIVE. Telegram bots are
/// discoverable by username, so anyone who finds the bot could then keep the user from ever pairing,
/// indefinitely, at no cost. That trade is backwards: it spends a real capability to prevent
/// something that was not going to happen.
///
/// Counting per origin keeps the window open for everyone else. One account's guesses are capped;
/// the legitimate user pairs from their own chat regardless of what anyone else is sending. A
/// distributed attacker needs a fresh account per `attemptsPerOrigin` guesses — on Discord and Slack
/// that means many members of a workspace the attacker must already be inside.
///
/// ⚠️ NO GLOBAL BACKSTOP, DELIBERATELY. Any window-wide cap reintroduces exactly the denial of
/// service above, just with a larger number in front of it.
///
/// ⚠️ THE LEDGER LIVES AND DIES WITH ONE WINDOW. It is a local value in the poll loop, so nothing
/// persists across pairings and a blocked origin is free again next time the user clicks Pair.
struct PairingAttemptLedger {

    /// Wrong PINs one origin may send before it is ignored for the rest of the window.
    ///
    /// ⚠️ TEN IS GENEROUS ON PURPOSE, because the number that matters is not this one. Against a
    /// 900,000-value space, capping an origin at ten guesses and capping it at three are the same
    /// answer — both are nowhere near a threat. The difference between them is entirely in how a
    /// fat-fingered human is treated, and locking the user out of their own pairing window is a
    /// real cost paid to prevent nothing.
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
    ///
    /// ⚠️ CHECKED BEFORE THE PIN IS COMPARED, so a blocked origin cannot pair even by then sending
    /// the CORRECT PIN. A lockout that still honours a lucky guess is not a lockout.
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

    /// How many distinct origins have guessed. ⚠️ THE NUMBER THAT DISTINGUISHES A TYPO FROM AN
    /// ATTACK: ten failures from one chat is someone struggling; ten failures from ten chats is not.
    var distinctOrigins: Int { failures.count }
}

// MARK: - Window Expiry

/// What happens when a pairing window runs out of time.
///
/// ⚠️⚠️ SHARED BECAUSE THE BUG WAS SHARED. All three services ended their window with the same three
/// lines — reset the connection state, delete the credentials, log the constant — and all three
/// carried the same two defects. Keeping one copy is what stops a future fix landing on two
/// platforms out of three, which is how the deadline bug (Telegram's loop bounds itself; Discord's
/// and Slack's did not) survived as long as it did.
@MainActor
enum PairingWindowExpiry {

    /// The watchdog's wait, shared by all three services so the unit conversion exists once.
    ///
    /// ⚠️ Takes SECONDS and sleeps on a `Duration`. Each service used to hand-convert with
    /// `UInt64(self?.pairingTimeout ?? 300 * 1_000_000_000)`: `??` binds looser than `*`, so with
    /// the service alive that is `UInt64(300.0)` — 300 NANOSECONDS. Every pairing window expired the
    /// moment it opened, on Telegram, Discord and Slack alike (Timeout inventory D-10, 2026-09-26).
    nonisolated static func waitOutWindow(_ timeout: TimeInterval) async {
        try? await Task.sleep(for: .seconds(timeout))
    }

    /// Ends an expired window — and ONLY if this window is still the live one.
    ///
    /// ⚠️⚠️ (1) **THE OWNERSHIP CHECK.** `Task.isCancelled` is false for an ORPHANED window: nothing
    /// cancelled it, the view that could have simply disappeared. So an orphan reaching its deadline
    /// happily reset `connectionState` and deleted the token belonging to a NEWER, already-successful
    /// pairing. `connectionState` still naming THIS window's PIN is the only available proof that the
    /// window is still ours, and it is checked before anything is written.
    ///
    /// ⚠️⚠️ (2) **A TIMEOUT MUST NOT DELETE CREDENTIALS.** The old arm ran `config.botToken = nil`,
    /// which is a Keychain DELETE. That token had been VALIDATED — the user pasted it and the
    /// platform's own API accepted it — and running out of time to send a PIN says nothing about the
    /// token. Wiping it silently reset the pane and made the user paste it again. Credentials are
    /// cleared by `disconnect()` and nowhere else.
    ///
    /// ⚠️ `.error(...)` rather than `.disconnected`, because a bare "Disconnected" is
    /// indistinguishable from never having started and tells the user nothing about what to do next.
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
