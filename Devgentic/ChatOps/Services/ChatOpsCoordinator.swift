// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
//
//  ChatOpsCoordinator.swift
//  Devgentic
//
//  Owns the lifecycle of the three ChatOps bridges (Telegram / Discord / Slack)
//  plus the ConversationSyncService that mirrors active streams into the
//  visible chat. Extracted from MainApplicationViewModel as part of the Gap C
//  god-object split — the methods here used to live inline in MainAppVM and
//  account for ~120 of its 1172 lines.
//
//  Design: the coordinator currently holds a weak reference to the MainAppVM
//  because the bridges themselves still take it as a dependency. A future
//  refinement could narrow that surface by threading a protocol (remote
//  message submission + active-stream observation), at which point the
//  coordinator could own its own narrower interface instead.
//

import Foundation
import os

@MainActor
final class ChatOpsCoordinator {

    private let logger = DGLogger(category: "ChatOpsCoordinator")

    /// Back-reference to the VM — bridges need to submit messages, query the
    /// active conversation, etc. Weak to avoid the obvious cycle since the VM
    /// owns the coordinator.
    private weak var viewModel: MainApplicationViewModel?

    /// Dependencies for `ConversationSyncService`, injected at init so the
    /// coordinator doesn't reach into the VM to grab them.
    private let chatHistoryViewModel: ChatHistoryViewModel
    private let activeStreamManager: ActiveStreamManager

    // MARK: - Owned Bridges & Services

    /// Bridges remain publicly readable so `ChatOpsSettingsView` can call
    /// `.stop()` directly for fine-grained control during reconfiguration.
    /// External callers reach these through `MainApplicationViewModel`'s
    /// forwarding properties (kept for API stability).
    private(set) var telegramBridge: ChatOpsBridge?
    private(set) var discordBridge: DiscordChatOpsBridge?
    private(set) var slackBridge: SlackChatOpsBridge?

    /// [Slice 3] Announces app notifications to whichever providers are connected.
    ///
    /// ⚠️ Registered ONCE and never unregistered: it resolves its targets on every send, so a
    /// disconnected provider simply stops being one. Unregistering on disconnect would also need
    /// re-registering on reconnect, and getting that wrong means silent notification loss.
    private var notificationChannel: ChatOpsNotificationChannel?

    /// Always-on sync service that injects newly-started streams from
    /// `ActiveStreamManager.activeStreams` into the currently displayed
    /// chat. Kept here because its lifecycle coincides with ChatOps bootstrap.
    private(set) var conversationSyncService: ConversationSyncService?

    // MARK: - Init

    init(
        viewModel: MainApplicationViewModel,
        chatHistoryViewModel: ChatHistoryViewModel,
        activeStreamManager: ActiveStreamManager
    ) {
        self.viewModel = viewModel
        self.chatHistoryViewModel = chatHistoryViewModel
        self.activeStreamManager = activeStreamManager
    }

    // MARK: - Bootstrap

    /// Called once from the VM's init. Spins up the always-on sync service
    /// and starts each bridge whose tokens are configured and whose toggle
    /// is enabled in `ChatOpsConfigManager`.
    /// Whether this process may open real chat connections.
    ///
    /// ⚠️⚠️ THE CONVENTION THIS REPLACES NEVER PROTECTED ANYTHING. Eight comments across the codebase
    /// forbade tests and previews from constructing `MainApplicationViewModel`, on the grounds that
    /// doing so bootstraps ChatOps. But the XCTest host IS the real app: `DevgenticApp.init` builds
    /// the view model on every `test-without-building` run whatever the tests themselves do. Verified
    /// empirically on 2026-09-11 — fifteen consecutive test runs each logged the three "ChatOps is
    /// disabled" lines from `bootstrap()`. They said *disabled* only because the developer's toggles
    /// happened to be off; with them on, every one of those runs would have opened a real Telegram,
    /// Discord and Slack listener against live bot tokens.
    ///
    /// ⚠️ WHAT THAT COSTS WHEN IT FIRES. Telegram serves ONE `getUpdates` poller and answers 409 to
    /// the other, so commands the developer sends while a test runs are swallowed at random by the
    /// test host — and executed there, against a throwaway view model, creating conversations and
    /// running agents in a process about to be killed. Nothing in the build output mentions it.
    ///
    /// ⚠️ `NSClassFromString("XCTestCase")` matches the precedent `TraceStore` already sets for this
    /// exact hazard, and for its stated reason: it is a SAFETY NET, firing even when a test run
    /// forgot to set an environment variable. Unlike TraceStore's it is deliberately NOT `#if DEBUG`
    /// — that guard is compiled out because it GRANTS something (an env-supplied path a shipped app
    /// must not honour); this one only ever REFUSES, and `XCTestCase` cannot load in a shipped app
    /// anyway, so leaving it in costs nothing and covers a release-configuration test run too.
    /// ⚠️ INTERNAL, not private, so a test can assert the answer IN ITS OWN PROCESS — which is the
    /// only assertion that actually proves the guard fires where it matters.
    static var mayOpenRealConnections: Bool {
        if TestHost.isRunning { return false }
        if ProcessInfo.processInfo.environment["XCODE_RUNNING_FOR_PREVIEWS"] == "1" { return false }
        return true
    }

    func bootstrap() {
        guard Self.mayOpenRealConnections else {
            logger.error("[CHATOPS] bootstrap() REFUSED — this process is an XCTest host or a SwiftUI preview. CONSEQUENCE: no Telegram, Discord or Slack listener is opened, so this process cannot consume the developer's real paired channels or post to them; a second poller would otherwise race their running app for the same bot token and swallow commands at random. ChatOps is unavailable in this process by design.")
            return
        }

        if conversationSyncService == nil {
            conversationSyncService = ConversationSyncService(
                chatHistoryViewModel: chatHistoryViewModel,
                activeStreamManager: activeStreamManager
            )
        }

        if notificationChannel == nil {
            let channel = ChatOpsNotificationChannel(announcers: { [weak self] in
                // ⚠️ Resolved per send, not captured: bridges come and go as the user connects and
                // disconnects providers, so a captured list would address a stopped bridge.
                guard let self else { return [] }
                // Listed explicitly rather than built as a heterogeneous array — the three bridges
                // share no base type, which is the point: they are independent conformers.
                var announcers: [any RemoteAnnouncing] = []
                if let telegram = self.telegramBridge { announcers.append(telegram) }
                if let discord = self.discordBridge { announcers.append(discord) }
                if let slack = self.slackBridge { announcers.append(slack) }
                return announcers
            })
            notificationChannel = channel
            Task { await NotificationDispatcher.shared.register(channel) }
        }

        let config = ChatOpsConfigManager.shared

        if config.isEnabled {
            startTelegram()
        } else {
            logger.info("Telegram ChatOps is disabled.")
        }

        if config.isDiscordEnabled {
            startDiscord()
        } else {
            logger.info("Discord ChatOps is disabled.")
        }

        if config.isSlackEnabled {
            startSlack()
        } else {
            logger.info("Slack ChatOps is disabled.")
        }
    }

    // MARK: - Telegram

    /// Start the Telegram bridge.
    ///
    /// ⚠️ [LIFE-2] THIS COMMENT PROMISED "Idempotent" AND THE CODE DID NOT PROVIDE IT. Reusing the
    /// bridge OBJECT is not the same as a second `start()` being safe: the old one built a fresh
    /// client, listener and transport and overwrote the stored references, orphaning a live poller
    /// nothing could cancel. It is idempotent now because `ChatOpsBridgeStart.shouldProceed` REFUSES
    /// a second start — not because it absorbs one. A comment asserting a guarantee the code does not
    /// give is the same class of defect as a log line naming the wrong cause.
    func startTelegram() {
        let config = ChatOpsConfigManager.shared
        guard config.botToken != nil,
              config.authorizedChatID != nil else {
            logger.info("ChatOps not configured — missing token or chat ID.")
            return
        }
        guard let viewModel else {
            logger.warning("Cannot start Telegram bridge — view model deallocated.")
            return
        }

        if telegramBridge == nil {
            telegramBridge = ChatOpsBridge(viewModel: viewModel)
        }
        telegramBridge?.start()
        logger.info("ChatOps bridge started.")
    }

    func stopTelegram() {
        telegramBridge?.stop()
        logger.info("ChatOps bridge stopped.")
    }

    // MARK: - Discord

    func startDiscord() {
        let config = ChatOpsConfigManager.shared
        guard config.discordBotToken != nil,
              config.discordAuthorizedChannelID != nil else {
            logger.info("Discord ChatOps not configured — missing token or channel ID.")
            return
        }
        guard let viewModel else {
            logger.warning("Cannot start Discord bridge — view model deallocated.")
            return
        }

        if discordBridge == nil {
            discordBridge = DiscordChatOpsBridge(viewModel: viewModel)
        }
        discordBridge?.start()
        logger.info("Discord ChatOps bridge started.")
    }

    func stopDiscord() {
        discordBridge?.stop()
        logger.info("Discord ChatOps bridge stopped.")
    }

    // MARK: - Slack

    func startSlack() {
        let config = ChatOpsConfigManager.shared
        guard config.slackBotToken != nil,
              config.slackAppToken != nil,
              config.slackAuthorizedChannelID != nil else {
            logger.info("Slack ChatOps not configured — missing tokens or channel ID.")
            return
        }
        guard let viewModel else {
            logger.warning("Cannot start Slack bridge — view model deallocated.")
            return
        }

        if slackBridge == nil {
            slackBridge = SlackChatOpsBridge(viewModel: viewModel)
        }
        slackBridge?.start()
        logger.info("Slack ChatOps bridge started.")
    }

    func stopSlack() {
        slackBridge?.stop()
        logger.info("Slack ChatOps bridge stopped.")
    }
}
