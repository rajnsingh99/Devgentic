//
//  SlackChatOpsBridge.swift
//  Devgentic
//
//  Created by Raj Singh on 24/03/26.
//

import Foundation
import SwiftData
import os

/// The core orchestrator for Slack ChatOps.
///
/// Routes incoming Slack Socket Mode events through the security gate, parses them into commands,
/// and dispatches them to the appropriate handler.
///
/// Uses the single-path architecture: remote messages flow through
/// `MainApplicationViewModel.submitRemoteMessage()` — the same path as the Mac UI.
/// The `RemoteMirrorService` handles mirroring events back to the transport.
@Observable @MainActor
final class SlackChatOpsBridge {

    private let logger = Logger(subsystem: DGLogger.subsystem, category: "SlackChatOpsBridge")

    // MARK: - Dependencies

    private weak var viewModel: MainApplicationViewModel?
    private var apiClient: SlackAPIClient?
    private var socketClient: SlackSocketClient?
    private let securityGate = ChatOpsSecurityGate()
    private var slackTransport: SlackTransport?
    var remoteMirrorService: RemoteMirrorService?
    private let config = ChatOpsConfigManager.shared

    // MARK: - State

    private var listeningTask: Task<Void, Never>?
    private(set) var isRunning: Bool = false
    private var awaitingClarification: Bool = false

    init(viewModel: MainApplicationViewModel) {
        self.viewModel = viewModel
    }

    // MARK: - Lifecycle

    func start() {
        guard let botToken = config.slackBotToken, !botToken.isEmpty,
              let appToken = config.slackAppToken, !appToken.isEmpty else {
            logger.warning("Cannot start SlackChatOpsBridge — missing bot or app token.")
            return
        }

        let client = SlackAPIClient(botToken: botToken)
        let socket = SlackSocketClient(appToken: appToken)
        let transport = SlackTransport(apiClient: client)

        self.apiClient = client
        self.socketClient = socket
        self.slackTransport = transport

        if let asm = viewModel?.activeStreamManager {
            self.remoteMirrorService = RemoteMirrorService(activeStreamManager: asm)
        }

        isRunning = true

        listeningTask = Task { [weak self] in
            guard let self else { return }

            let stream = await socket.start()
            self.logger.info("SlackChatOpsBridge started — listening for Slack events.")

            for await event in stream {
                await self.handleSocketEvent(event)
            }

            await MainActor.run {
                self.isRunning = false
                self.logger.info("SlackChatOpsBridge stopped.")
            }
        }
    }

    func stop() {
        listeningTask?.cancel()
        listeningTask = nil

        Task {
            await socketClient?.stop()
        }

        // [D2] Detach the mirror service so a stopped transport stops mirroring, then drop the strong ref.
        remoteMirrorService?.teardown()
        remoteMirrorService = nil

        isRunning = false
        logger.info("SlackChatOpsBridge stopped.")
    }

    // MARK: - Event Routing

    private func handleSocketEvent(_ event: SlackSocketEvent) async {
        switch event {
        case .connected:
            logger.info("Slack Socket Mode connected.")

        case .message(let slackEvent):
            await handleMessage(slackEvent)

        case .interaction(let payload):
            await handleInteraction(payload)

        case .slashCommand(let payload):
            await handleSlashCommand(payload)

        case .disconnected(let error):
            if let error {
                logger.error("Slack Socket disconnected: \(error.localizedDescription)")
            }
        }
    }

    // MARK: - Message Handling

    private func handleMessage(_ event: SlackEvent) async {
        // Ignore bot messages
        guard event.bot_id == nil, event.subtype == nil else { return }
        guard let channelID = event.channel, let text = event.text else { return }

        // Security gate
        guard await securityGate.authorizeSlack(channelID: channelID, config: config) else { return }

        // Parse command
        let command = ChatOpsCommand.parseSlack(
            text: text,
            awaitingClarification: awaitingClarification
        )

        // Tier enforcement
        guard await securityGate.canExecute(command, tier: config.securityTier) else {
            let msg = await securityGate.denialMessage(for: command, tier: config.securityTier)
            _ = try? await apiClient?.postMessage(channel: channelID, text: msg)
            return
        }

        await routeCommand(command, channelID: channelID)
    }

    // MARK: - Interaction Handling

    private func handleInteraction(_ payload: SlackInteractivePayload) async {
        guard let action = payload.actions?.first else { return }
        let channelID = payload.channel?.id ?? config.slackAuthorizedChannelID ?? ""

        // Parse action_id using the same callback data format
        let command = ChatOpsCommand.parseSlack(actionID: action.action_id)

        // [D1] Security: button taps must pass the same channel-authorization + tier gate as slash
        // commands. This path previously bypassed BOTH — a HITL approve/deny/gate button could resolve
        // below the .full tier or from an unauthorized channel.
        guard await securityGate.authorizeSlack(channelID: channelID, config: config) else { return }
        guard await securityGate.canExecute(command, tier: config.securityTier) else {
            let msg = await securityGate.denialMessage(for: command, tier: config.securityTier)
            _ = try? await apiClient?.postMessage(channel: channelID, text: msg)
            return
        }

        // Route HITL
        switch command {
        case .approveHITL(let operationID):
            await remoteMirrorService?.handleApproval(operationID: operationID, approved: true)
        case .denyHITL(let operationID):
            await remoteMirrorService?.handleApproval(operationID: operationID, approved: false)
        case .gateChoiceHITL(let operationID, let optionIndex):
            await remoteMirrorService?.handleGate(operationID: operationID, optionIndex: optionIndex)
        case .switchConversation(let uuid):
            await handleSwitchConversation(to: uuid, channelID: channelID)
        case .newConversation:
            await handleNewConversation(channelID: channelID)
        default:
            break
        }
    }

    // MARK: - Slash Command Handling

    private func handleSlashCommand(_ payload: SlackSlashCommandPayload) async {
        let channelID = payload.channel_id

        guard await securityGate.authorizeSlack(channelID: channelID, config: config) else { return }

        let command = ChatOpsCommand.parseSlack(slashCommand: payload.command)

        guard await securityGate.canExecute(command, tier: config.securityTier) else {
            let msg = await securityGate.denialMessage(for: command, tier: config.securityTier)
            _ = try? await apiClient?.postMessage(channel: channelID, text: msg)
            return
        }

        await routeCommand(command, channelID: channelID)
    }

    // MARK: - Command Routing

    private func routeCommand(_ command: ChatOpsCommand, channelID: String) async {
        switch command {
        case .conversations:
            await handleConversations(channelID: channelID)
        case .newConversation:
            await handleNewConversation(channelID: channelID)
        case .status:
            await handleStatus(channelID: channelID)
        case .cancel:
            await handleCancel(channelID: channelID)
        case .help:
            await handleHelp(channelID: channelID)
        case .switchConversation(let uuid):
            await handleSwitchConversation(to: uuid, channelID: channelID)
        case .approveHITL(let operationID):
            await remoteMirrorService?.handleApproval(operationID: operationID, approved: true)
        case .denyHITL(let operationID):
            await remoteMirrorService?.handleApproval(operationID: operationID, approved: false)
        case .gateChoiceHITL(let operationID, let optionIndex):
            await remoteMirrorService?.handleGate(operationID: operationID, optionIndex: optionIndex)
        case .clarificationResponse(let text):
            // [HITL/P6] Resolve the pending clarification's operationID from the unified InteractionCenter.
            if let convID = config.slackActiveConversationID,
               let center = viewModel?.interactionCenter {
                let pendingOpID = center.items(for: convID)
                    .first(where: { if case .clarification = $0.kind { return true }; return false })?
                    .id
                if let opID = pendingOpID {
                    await remoteMirrorService?.handleClarification(operationID: opID, text: text)
                    awaitingClarification = false
                }
            }
        case .freeText(let text):
            await handleFreeText(text, channelID: channelID)
        case .pairingAttempt:
            break
        case .unknown:
            break
        }
    }

    // MARK: - Command Handlers

    private func handleConversations(channelID: String) async {
        let conversations = fetchRecentConversations(limit: 10)

        if conversations.isEmpty {
            _ = try? await apiClient?.postMessage(channel: channelID, text: "No conversations yet. Use /new to create one.")
            return
        }

        var buttons: [SlackBlockElement] = []
        for conversationSD in conversations.prefix(20) { // Slack allows up to 25 elements per actions block
            let title = conversationSD.toRowStruct().displayTitle
            let convID = conversationSD.id
            let isActive = convID == config.slackActiveConversationID ? "⭐ " : ""
            let label = String("\(isActive)\(title)".prefix(75))

            buttons.append(SlackBlockElement.button(
                text: label,
                actionID: "switch:\(convID.uuidString)",
                value: convID.uuidString
            ))
        }

        buttons.append(SlackBlockElement.button(
            text: "➕ New Conversation",
            actionID: "action:new",
            value: "new",
            style: SlackBlockElement.primaryStyle
        ))

        // Slack allows max 25 elements per actions block, max 5 per row is a Discord limit not Slack
        let blocks: [SlackBlock] = [
            .sectionBlock(text: "📋 *Your Conversations:*"),
            .actionsBlock(elements: buttons)
        ]

        _ = try? await apiClient?.postMessage(channel: channelID, text: "Your Conversations", blocks: blocks)
    }

    private func handleNewConversation(channelID: String) async {
        guard let vm = viewModel else { return }

        guard let profile = resolveProfile() else {
            _ = try? await apiClient?.postMessage(channel: channelID, text: "⚠️ No agent profile configured. Set one in Devgentic Settings.")
            return
        }

        if let emptyConv = findReusableEmptyConversation() {
            let reusedID = emptyConv.id
            config.slackActiveConversationID = reusedID
            vm.selectedConversationID = reusedID

            _ = try? await apiClient?.postMessage(
                channel: channelID,
                text: "✅ Switched to existing empty conversation.\nJust type your message to start."
            )
            logger.info("[Slack] Reused empty conversation \(reusedID.uuidString).")
            return
        }

        let convID = vm.createConversationForScheduledTask(profileID: profile, title: "Slack Chat")
        config.slackActiveConversationID = convID
        vm.selectedConversationID = convID

        _ = try? await apiClient?.postMessage(
            channel: channelID,
            text: "✅ New conversation created and set as active.\nJust type your message to start."
        )
        logger.info("Created new conversation via Slack: \(convID.uuidString)")
    }

    private func handleStatus(channelID: String) async {
        guard let vm = viewModel else { return }

        // Conversation-scoped 2026-08-17 (design doc increment 1): this used to read the
        // app-global `vm.streamingMessageID`, so /status reported "streaming" whenever ANY
        // conversation was busy — including a main-window run the remote user has nothing to
        // do with — and reported idle the moment an unrelated run cleared the slot.
        let isStreaming = config.slackActiveConversationID.map { vm.activeStreamManager.hasActiveStream(inConversation: $0) } ?? false
        let activeConvTitle: String
        if let activeID = config.slackActiveConversationID,
           let conversationSD = vm.persistenceService.getConversation(withId: activeID) {
            activeConvTitle = conversationSD.toRowStruct().displayTitle
        } else {
            activeConvTitle = "None"
        }

        let allConversations = fetchRecentConversations(limit: 100)

        let statusText = """
        📊 *Devgentic Status*

        🗣 Active Conversation: \(activeConvTitle)
        ⚡ Agent Streaming: \(isStreaming ? "Yes" : "No")
        🔐 Security Tier: \(config.securityTier.rawValue)
        📋 Total Conversations: \(allConversations.count)
        """

        _ = try? await apiClient?.postMessage(channel: channelID, text: statusText)
    }

    private func handleCancel(channelID: String) async {
        guard let conversationID = config.slackActiveConversationID else {
            _ = try? await apiClient?.postMessage(channel: channelID, text: "No active conversation to cancel.")
            return
        }

        await ExecutionSuspensionService.shared.cancel(for: conversationID)
        awaitingClarification = false

        _ = try? await apiClient?.postMessage(channel: channelID, text: "🛑 Cancelled active agent for this conversation.")
    }

    private func handleHelp(channelID: String) async {
        let helpText = """
        🤖 *Devgentic ChatOps (Slack)*

        *Commands:*
        /conversations — List your conversations
        /new — Start a new conversation
        /status — Current agent status
        /cancel — Stop the active agent
        /help — Show this message

        *How it works:*
        1. Use /conversations to pick a conversation
        2. Type your message — it routes to the agent
        3. The agent responds right here

        *Security Tier:* \(config.securityTier.rawValue)
        """

        _ = try? await apiClient?.postMessage(channel: channelID, text: helpText)
    }

    private func handleSwitchConversation(to uuid: UUID, channelID: String) async {
        guard let vm = viewModel else { return }

        guard let conversationSD = vm.persistenceService.getConversation(withId: uuid) else {
            _ = try? await apiClient?.postMessage(channel: channelID, text: "⚠️ Conversation not found.")
            return
        }

        config.slackActiveConversationID = uuid
        awaitingClarification = false
        vm.selectedConversationID = uuid

        let title = conversationSD.toRowStruct().displayTitle
        _ = try? await apiClient?.postMessage(
            channel: channelID,
            text: "✅ Switched to: *\(title)*\n\nJust type your message to continue."
        )
    }

    private func handleFreeText(_ text: String, channelID: String) async {
        guard let vm = viewModel else { return }

        guard let conversationID = config.slackActiveConversationID else {
            _ = try? await apiClient?.postMessage(
                channel: channelID,
                text: "No active conversation. Use /conversations to pick one or /new to create one."
            )
            return
        }

        guard let profile = resolveProfileForConversation(conversationID) else {
            _ = try? await apiClient?.postMessage(
                channel: channelID,
                text: "⚠️ No agent profile found for this conversation."
            )
            return
        }

        let requestConfig = BackendRequestConfig(profile: profile)

        guard let transport = slackTransport else { return }

        remoteMirrorService?.registerSession(
            conversationID: conversationID,
            info: RemoteSessionInfo(
                transport: transport,
                chatID: channelID,
                source: .slack
            )
        )

        vm.submitRemoteMessage(
            prompt: text,
            conversationID: conversationID,
            source: .slack,
            config: requestConfig
        )
    }

    // MARK: - Profile Resolution

    private func resolveProfileForConversation(_ conversationID: UUID) -> BackendProfileModel? {
        guard let vm = viewModel else { return nil }
        let conversationSD = vm.persistenceService.getConversation(withId: conversationID)
        guard let profileID = conversationSD?.backendEntityId else { return nil }
        return ((try? BackendProfileStore.shared.fetchProfiles()) ?? []).first { $0.id == profileID }
    }

    private func resolveProfile() -> BackendProfileModel? {
        let profiles = (try? BackendProfileStore.shared.fetchProfiles()) ?? []
        if let vm = viewModel,
           let selectedID = vm.backendConfiguration.selectedProfileID,
           let profile = profiles.first(where: { $0.id == selectedID }) {
            return profile
        }
        return profiles.first { $0.profileType == .agent } ?? profiles.first
    }

    // MARK: - SwiftData Helpers

    private func findReusableEmptyConversation() -> ConversationSD? {
        if let activeID = config.slackActiveConversationID,
           let activeEntity = viewModel?.persistenceService.getConversation(withId: activeID),
           activeEntity.messages.count == 0 {
            return activeEntity
        }

        guard let context = ChatPersistenceStore.shared.modelContainer?.mainContext else { return nil }

        var descriptor = FetchDescriptor<ConversationSD>(
            sortBy: [SortDescriptor(\.timestamp, order: .reverse)]
        )
        descriptor.fetchLimit = 10

        do {
            let results = try context.fetch(descriptor)
            return results.first { $0.messages.count == 0 }
        } catch {
            logger.error("[Slack] Failed to query for empty conversations: \(error.localizedDescription)")
            return nil
        }
    }

    private func fetchRecentConversations(limit: Int) -> [ConversationSD] {
        guard let context = ChatPersistenceStore.shared.modelContainer?.mainContext else { return [] }

        var descriptor = FetchDescriptor<ConversationSD>(
            sortBy: [
                SortDescriptor(\.timestamp, order: .reverse)
            ]
        )
        descriptor.fetchLimit = limit

        do {
            return try context.fetch(descriptor)
        } catch {
            logger.error("Failed to fetch conversations for Slack ChatOps: \(error.localizedDescription)")
            return []
        }
    }
}
