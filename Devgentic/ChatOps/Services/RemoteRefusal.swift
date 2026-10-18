// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
//
//  RemoteRefusal.swift
//  Devgentic
//
//  Created by Raj Singh.
//

import Foundation

/// Why a message was refused, and what the caller may do about it.
struct RemoteRefusal: Equatable, Sendable {

    enum Reason: Equatable, Sendable {
        /// The room is not the paired one. Identity was never established; no reply is sent.
        case unauthorizedChannel
        /// The sender is not the paired account (for example a bystander in a shared room); no reply is sent.
        case unauthorizedSender
        /// Attributable to nobody at all.
        case unattributable
        /// This pairing predates per-sender authorization and recorded no account.
        case pairingPredatesAuthorization
        /// The paired operator, throttled. The only refusal that may be answered.
        case rateLimited(retryIn: TimeInterval)
    }

    let reason: Reason

    /// Required: every refusal states what followed from it, so a new refusal cannot be added without one.
    let consequence: String

    /// Whether the sender is owed a reply; true only for a throttled sender.
    /// The rate check runs after the channel and sender checks, so replying leaks nothing; other refusals precede identity.
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

/// Tells a throttled operator once per window, rather than never or on every dropped message.
/// Follows `ChatOpsUpgradeNotice.claimAnnouncement`: the dedup is the return value, not a side effect.
@MainActor
enum ChatOpsThrottleNotice {

    /// How long one notice covers, matched to the bucket's full-refill time (1 token/second, burst of 30).
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
