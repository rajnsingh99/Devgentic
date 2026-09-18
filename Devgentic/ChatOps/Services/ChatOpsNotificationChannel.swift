// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
//
//  ChatOpsNotificationChannel.swift
//  Devgentic
//
//  App notifications, delivered to the paired chat channels — slice 3 of the ChatOps remote
//  interface.
//
//  WHY THIS IS SMALL. `NotificationChannel` is a five-member strategy protocol and
//  `NotificationDispatcher` already fans out to every registered channel, so the app has FOUR live
//  dispatch sites that reach chat the moment one more channel exists: a completed run
//  (`ActiveStreamManager`), a stale human-in-the-loop request (`InteractionCenter`), a finished model
//  download (`DownloadManager`) and a completed scheduled task (`SchedulerService`). Nothing at
//  those sites changes.
//
//  ⚠️ THE ONE THAT MATTERS IS THE SCHEDULED TASK. A scheduled run has no remote session — nobody
//  messaged the bot to start it — so `RemoteMirrorService` never sees it and its result reached
//  nothing but the Mac. "Your 8am briefing finished" is the notification a remote user actually
//  wants, and it is the only one they could not already get.
//
//  ⚠️⚠️ WHICH IS ALSO WHY THIS MUST NOT DOUBLE-POST. The other three fire for conversations the
//  mirror may ALREADY be streaming to: a run started from Telegram gets its answer from
//  `RemoteMirrorService`, and announcing "Query Completed" beside it would say the same thing twice.
//  So the channel asks each provider whether it is already mirroring that conversation and stays
//  quiet if it is. That is a precise rule over information the bridge actually has — not a guess
//  from the payload, which carries no category (only `DownloadManager` sets `metadata`).
//
//  ⚠️ OFF BY DEFAULT. This turns local, private notifications into messages posted to a third-party
//  service. That is a decision for the user to make once, knowingly, rather than a behaviour they
//  discover when their model-download history appears in a shared Slack channel.
//

import Foundation
import os

private let logger = DGLogger(category: "ChatOpsNotifications")

// MARK: - Announcing

/// A provider that can post an unprompted message to its paired channel.
///
/// ⚠️ SEPARATE FROM `ChatOpsTransport`, deliberately. A transport renders to a destination it is
/// GIVEN; an announcer knows its OWN destination — the channel this provider is paired with — which
/// is the whole difference between replying and announcing. The bridge is the only thing that knows
/// both, so the bridge is what conforms.
@MainActor
protocol RemoteAnnouncing: AnyObject {

    var provider: RemoteChannel.Provider { get }

    /// Whether this provider is connected and paired. A stopped bridge announces nothing.
    var canAnnounce: Bool { get }

    /// Whether the mirror is already streaming this conversation to this provider.
    ///
    /// ⚠️ The double-post guard. Returns false for a nil conversation — an app-wide notification
    /// (a finished download) belongs to no conversation and is never a duplicate.
    func isMirroring(_ conversationID: UUID?) -> Bool

    /// Posts to this provider's paired channel.
    ///
    /// ⚠️ RETURNS WHETHER IT REACHED THE WIRE, and that is not bookkeeping. This was `-> Void`, so
    /// `ChatOpsNotificationChannel.send` could not fail, so `NotificationService.dispatch` counted
    /// it delivered — and the Settings "Test" button reported success for a notification that was
    /// never posted. A channel that cannot report failure makes every caller above it lie.
    @discardableResult
    func announce(_ view: RemoteView) async -> Bool
}

// MARK: - Errors

/// Why an announcement did not reach any remote channel.
///
/// ⚠️ THIS TYPE EXISTS SO `dispatch` CAN COUNT HONESTLY. `NotificationChannel.send` has always been
/// `throws`; this channel simply never used it, and a non-throwing send is counted as a delivery
/// (`NotificationService.swift`, `delivered += 1`).
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

    /// ⚠️ Defaults to FALSE. See this file's header — enabling it publishes local notifications to a
    /// third-party service, which is the user's call to make deliberately.
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
            // ⚠️ SUPPRESSION IS SUCCESS; HAVING NOBODY TO TELL IS NOT. Both used to leave through
            // the same bare `return`, which `NotificationService.dispatch` counts as a delivery —
            // so with the channel switched on and no provider connected, the Settings "Test" button
            // said it worked and nothing had been posted anywhere.
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

        // ⚠️ ANY delivery is a success; ZERO out of N is not. Throwing on a partial failure would
        // make the dispatcher discard a notification the user did receive.
        guard delivered > 0 else {
            logger.error("[CHATOPS] \"\(payload.title)\" reached none of its \(targets.count) paired provider(s) — every announce failed. CONSEQUENCE: the notification is lost, and this throws so the dispatcher reports it undelivered rather than counting a send that never landed.")
            throw ChatOpsAnnounceError.everyProviderFailed(attempted: targets.count)
        }
        logger.info("[CHATOPS] Announced \"\(payload.title)\" to \(delivered) of \(targets.count) provider(s).")
    }

    /// ⚠️ `.info`, never `.failure`, even for "Query Failed". Tone's only reader is
    /// `RemoteRenderLog.posted`, which logs a failure notice at `.error` — and a failed query is the
    /// app reporting normally, not the render path going wrong.
    nonisolated static func view(for payload: AppNotificationPayload) -> RemoteView {
        .notice(Notice(tone: .info, icon: "🔔", title: payload.title, body: payload.body))
    }
}
