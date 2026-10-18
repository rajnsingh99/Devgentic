// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
//
//  ChatOpsCoordinator.swift
//  Devgentic
//
//  Created by Raj Singh.
//

import Foundation
import os

/// Owns the lifecycle of the three ChatOps bridges (Telegram, Discord, Slack) and the ConversationSyncService
/// that mirrors active streams into the visible chat.
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

    /// Bridges are publicly readable so `ChatOpsSettingsView` can call `.stop()` directly during reconfiguration.
    /// External callers reach them through `MainApplicationViewModel`'s forwarding properties.
    private(set) var telegramBridge: ChatOpsBridge?
    private(set) var discordBridge: DiscordChatOpsBridge?
    private(set) var slackBridge: SlackChatOpsBridge?

    // Why: registered once and never unregistered: it resolves its targets on every send, so reconnects need no re-registration.
    /// Announces app notifications to whichever providers are connected.
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

    // Why: the XCTest host builds the real view model, so without this tests would open live bot listeners and
    // a second Telegram poller would swallow the developer's commands at random.
    /// Whether this process may open real chat connections: false in an XCTest host or a SwiftUI preview.
    /// `bootstrap()` (called once from the VM's init) starts the sync service and each enabled bridge only when true.
    static var mayOpenRealConnections: Bool {
        if TestHost.isRunning { return false }
        if ProcessInfo.processInfo.environment["XCODE_RUNNING_FOR_PREVIEWS"] == "1" { return false }
        return true
    }

    /// Called once from the view model's init: starts the always-on sync service and each bridge that has tokens and is enabled.
    /// Does nothing when `mayOpenRealConnections` is false.
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
                // Resolved per send, not captured: bridges come and go as providers connect and disconnect, so a captured list would
                // address a stopped bridge.
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
    /// Idempotent because `ChatOpsBridgeStart.shouldProceed` refuses a second start, not because it absorbs one.
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
