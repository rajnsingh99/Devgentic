// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
//
//  ChatOpsNotificationChannel.swift
//  Devgentic
//
//  Created by Raj Singh.
//

import Foundation
import os

private let logger = DGLogger(category: "ChatOpsNotifications")

// MARK: - Announcing

/// A provider that can post an unprompted message to its paired channel.
/// Separate from `ChatOpsTransport`: a transport renders to a destination it is given, while an announcer knows its own
/// destination (the channel it is paired with). The bridge knows both, so the bridge conforms.
@MainActor
protocol RemoteAnnouncing: AnyObject {

    var provider: RemoteChannel.Provider { get }

    /// Whether this provider is connected and paired. A stopped bridge announces nothing.
    var canAnnounce: Bool { get }

    /// Whether the mirror is already streaming this conversation to this provider: the double-post guard.
    /// Returns false for a nil conversation: an app-wide notification (a finished download) is never a duplicate.
    func isMirroring(_ conversationID: UUID?) -> Bool

    // Why: callers must see failure: a channel that cannot report it makes `NotificationService.dispatch` count a
    // delivery that never happened.
    /// Posts to this provider's paired channel and returns whether it reached the wire.
    @discardableResult
    func announce(_ view: RemoteView) async -> Bool
}

// MARK: - Errors

/// Why an announcement did not reach any remote channel, so `dispatch` can count deliveries honestly
/// (a non-throwing send is counted as delivered).
enum ChatOpsAnnounceError: LocalizedError {
    case noPairedProvider
    case everyProviderFailed(attempted: Int)

    var errorDescription: String? {
        switch self {
        case .noPairedProvider:
            return "No ChatOps provider is connected and paired, so there was nowhere to post."
        case .everyProviderFailed(let attempted):
            return "All \(attempted) paired ChatOps provider(s) failed to post."
        }
    }
}

// MARK: - Channel

final class ChatOpsNotificationChannel: NotificationChannel {

    let channelID = "chatops"
    let displayName = "ChatOps (Telegram, Discord, Slack)"

    /// True: it needs a paired channel before it can deliver anything.
    let requiresConfiguration = true

    /// Defaults to false: enabling it publishes local notifications to a third-party service, which is the user's call.
    var isEnabled: Bool {
        get { UserDefaults.standard.bool(forKey: AppSettings.chatOpsNotificationsEnabledKey) }
        set { UserDefaults.standard.set(newValue, forKey: AppSettings.chatOpsNotificationsEnabledKey) }
    }

    /// Resolved on every send rather than captured once: bridges are created and destroyed by
    /// `ChatOpsCoordinator` as the user connects and disconnects providers, so a captured list goes
    /// stale and would announce to a stopped bridge.
    private let announcers: @MainActor () -> [any RemoteAnnouncing]

    init(announcers: @escaping @MainActor () -> [any RemoteAnnouncing]) {
        self.announcers = announcers
    }

    func send(_ payload: AppNotificationPayload) async throws {
        var suppressedByMirror = 0
        let targets = await MainActor.run {
            announcers().filter { announcer in
                guard announcer.canAnnounce else { return false }
                if announcer.isMirroring(payload.conversationID) {
                    suppressedByMirror += 1
                    logger.info("[CHATOPS] Suppressed the \"\(payload.title)\" notification on \(announcer.provider.rawValue) — the mirror is already streaming that conversation there. CONSEQUENCE: the remote user is told once rather than twice; if the mirror later stops covering a case, this suppression is where the missing message went.")
                    return false
                }
                return true
            }
        }

        guard !targets.isEmpty else {
            // Suppression is success; having nobody to tell is not. They must not share one bare `return`, which
            // `NotificationService.dispatch` counts as a delivery.
            if suppressedByMirror > 0 {
                logger.info("[CHATOPS] \"\(payload.title)\" was not announced: all \(suppressedByMirror) eligible provider(s) are already mirroring that conversation. CONSEQUENCE: nothing is posted, which is correct — the remote user is seeing the stream itself.")
                return
            }
            logger.error("[CHATOPS] \"\(payload.title)\" could not be announced: no provider is connected and paired. CONSEQUENCE: the notification reaches the Mac only. This throws so the dispatcher does not count an undelivered notification as delivered, which is what made the Settings test button report success.")
            throw ChatOpsAnnounceError.noPairedProvider
        }

        let view = Self.view(for: payload)
        var delivered = 0
        for target in targets {
            if await target.announce(view) { delivered += 1 }
        }

        // Any delivery is a success; zero out of N is not. Throwing on a partial failure would make the dispatcher
        // discard a notification the user did receive.
        guard delivered > 0 else {
            logger.error("[CHATOPS] \"\(payload.title)\" reached none of its \(targets.count) paired provider(s) — every announce failed. CONSEQUENCE: the notification is lost, and this throws so the dispatcher reports it undelivered rather than counting a send that never landed.")
            throw ChatOpsAnnounceError.everyProviderFailed(attempted: targets.count)
        }
        logger.info("[CHATOPS] Announced \"\(payload.title)\" to \(delivered) of \(targets.count) provider(s).")
    }

    /// `.info`, never `.failure`, even for "Query Failed": `RemoteRenderLog.posted` logs a failure-toned notice at
    /// `.error`, and a failed query is the app reporting normally, not the render path going wrong.
    nonisolated static func view(for payload: AppNotificationPayload) -> RemoteView {
        .notice(Notice(tone: .info, icon: "🔔", title: payload.title, body: payload.body))
    }
}
