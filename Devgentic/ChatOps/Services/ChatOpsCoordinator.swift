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
    func bootstrap() {
        if conversationSyncService == nil {
            conversationSyncService = ConversationSyncService(
                chatHistoryViewModel: chatHistoryViewModel,
                activeStreamManager: activeStreamManager
            )
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

    /// Start the Telegram bridge. Idempotent — reuses an existing bridge if
    /// already created.
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
