// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
//
//  RemoteRefusal.swift
//  Devgentic
//
//  Why the security gate said no, and whether the sender is owed an answer.
//
//  ⚠️⚠️ THE GATE RETURNED `Bool`, SO THE BRIDGE COULD NOT TELL TWO OPPOSITE SITUATIONS APART: "a
//  stranger's room, owed nothing" and "the paired operator, throttled, owed an acknowledgement and an
//  explanation". Both became `false`, both became a bare `return`, and the operator whose own commands
//  were being dropped by the rate limiter saw exactly what an intruder saw — silence.
//
//  ⚠️⚠️ AND THE SILENCE IS CORRECT FOR ONE OF THEM. Replying to an unauthorized room confirms that a
//  paired Mac is listening there, and hands an attacker free amplification; that is why those arms
//  were written "Dropping silently" in the first place. The distinction must therefore be carried in
//  the type rather than left to each of six call sites to remember — `mayReply` is true for exactly
//  one case.
//

import Foundation

/// Why a message was refused, and what the caller may do about it.
struct RemoteRefusal: Equatable, Sendable {

    enum Reason: Equatable, Sendable {
        /// The room is not the paired one. ⚠️ Identity was never established — say nothing.
        case unauthorizedChannel
        /// The sender is not the paired account. ⚠️ A bystander in a shared room — say nothing.
        case unauthorizedSender
        /// Attributable to nobody at all.
        case unattributable
        /// This pairing predates per-sender authorization and recorded no account.
        case pairingPredatesAuthorization
        /// The paired operator, throttled. ⚠️ THE ONE ARM THAT MAY REPLY.
        case rateLimited(retryIn: TimeInterval)
    }

    let reason: Reason

    /// ⚠️ REQUIRED, NOT OPTIONAL. Every refusal states what followed from it — the standing logging
    /// rule. Making it a stored `let` means a new refusal cannot be added without writing one.
    let consequence: String

    /// Whether the sender is owed a reply.
    ///
    /// ⚠️⚠️ TRUE FOR EXACTLY ONE REASON, and that asymmetry is the security boundary. A throttled
    /// sender has already proved they are the paired operator — the rate check runs AFTER the channel
    /// and sender checks — so answering them leaks nothing they do not already know. Every other
    /// refusal happens before identity is established.
    var mayReply: Bool {
        if case .rateLimited = reason { return true }
        return false
    }
}

/// The gate's verdict.
enum RemoteAuthorization: Equatable, Sendable {
    case authorized
    case refused(RemoteRefusal)

    var isAuthorized: Bool {
        if case .authorized = self { return true }
        return false
    }
}

/// Telling a throttled operator once, rather than never or constantly.
///
/// ⚠️ Follows `ChatOpsUpgradeNotice.claimAnnouncement` exactly: the dedup is the RETURN VALUE, not a
/// side effect a caller can forget to check. Without it, a burst that trips the limiter would either
/// say nothing (today) or answer every dropped message — turning one refusal into a flood that is
/// itself the amplification the silent arms exist to avoid.
@MainActor
enum ChatOpsThrottleNotice {

    /// How long one notice covers. ⚠️ Matched to the bucket's own full-refill time: at 1 token/second
    /// with a burst of 30, a sender who has exhausted it is clear again within 30 seconds, so telling
    /// them more than once per window says nothing new.
    static let window: TimeInterval = 30

    private static var lastTold: [RemoteChannel.Provider: TimeInterval] = [:]

    /// Whether this caller should post the notice now.
    static func claim(for provider: RemoteChannel.Provider,
                      now: TimeInterval = ProcessInfo.processInfo.systemUptime) -> Bool {
        if let last = lastTold[provider], now - last < window { return false }
        lastTold[provider] = now
        return true
    }

    static func resetForTesting() { lastTold.removeAll() }
}
