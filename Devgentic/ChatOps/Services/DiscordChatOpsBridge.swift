//
//  DiscordChatOpsBridge.swift
//  Devgentic
//
//  Created by Raj Singh on 24/03/26.
//

import Foundation
import SwiftData
import os

/// The core orchestrator for Discord ChatOps.
///
/// Routes incoming Discord Gateway events through the security gate, parses them into commands,
/// and dispatches them to the appropriate handler.
///
/// Uses the single-path architecture: remote messages flow through
/// `MainApplicationViewModel.submitRemoteMessage()` — the same path as the Mac UI.
/// The `RemoteMirrorService` handles mirroring events back to the transport.
@Observable @MainActor
final class DiscordChatOpsBridge {

    private let logger = Logger(subsystem: DGLogger.subsystem, category: "DiscordChatOpsBridge")

    // MARK: - Dependencies

    private weak var viewModel: MainApplicationViewModel?
    private var apiClient: DiscordAPIClient?
    private var gatewayClient: DiscordGatewayClient?
    private let securityGate = ChatOpsSecurityGate()
    private var discordTransport: DiscordTransport?
    var remoteMirrorService: RemoteMirrorService?
    private let config = ChatOpsConfigManager.shared

    // MARK: - State

    private var listeningTask: Task<Void, Never>?
    private(set) var isRunning: Bool = false

    /// Tracks whether the bridge is awaiting a clarification response.
    private var awaitingClarification: Bool = false

    init(viewModel: MainApplicationViewModel) {
        self.viewModel = viewModel
    }

    // MARK: - Lifecycle

    /// Starts the Discord Gateway connection and begins processing events.
    func start() {
        guard let token = config.discordBotToken, !token.isEmpty else {
            logger.warning("Cannot start DiscordChatOpsBridge — no bot token configured.")
            return
        }

        let client = DiscordAPIClient(botToken: token)
        let gateway = DiscordGatewayClient(botToken: token)
        let transport = DiscordTransport(apiClient: client)

        self.apiClient = client
        self.gatewayClient = gateway
        self.discordTransport = transport

        // Create RemoteMirrorService if ViewModel provides ActiveStreamManager
        if let asm = viewModel?.activeStreamManager {
            self.remoteMirrorService = RemoteMirrorService(activeStreamManager: asm)
        }

        isRunning = true

        listeningTask = Task { [weak self] in
            guard let self else { return }

            let stream = await gateway.start()
            self.logger.info("DiscordChatOpsBridge started — listening for Discord events.")

            for await event in stream {
                await self.handleGatewayEvent(event)
            }

            await MainActor.run {
                self.isRunning = false
                self.logger.info("DiscordChatOpsBridge stopped.")
            }
        }
    }

    /// Stops the Gateway connection and cleans up.
    func stop() {
        listeningTask?.cancel()
        listeningTask = nil

        Task {
            await gatewayClient?.stop()
        }

        // [D2] Detach the mirror service so a stopped transport stops mirroring, then drop the strong ref.
        remoteMirrorService?.teardown()
        remoteMirrorService = nil

        isRunning = false
        logger.info("DiscordChatOpsBridge stopped.")
    }

    // MARK: - Event Routing

    private func handleGatewayEvent(_ event: DiscordGatewayEvent) async {
        switch event {
        case .ready(let ready):
            // Store application ID and register slash commands
            await apiClient?.setApplicationID(ready.application.id)
            if let guildID = config.discordGuildID, let appID = ready.application.id as String? {
                try? await apiClient?.registerSlashCommands(applicationID: appID, guildID: guildID)
                logger.info("Registered slash commands for guild \(guildID).")
            }

        case .messageCreate(let message):
            await handleMessage(message)

        case .interactionCreate(let interaction):
            await handleInteraction(interaction)

        case .disconnected(let error):
            if let error {
                logger.error("Discord Gateway disconnected: \(error.localizedDescription)")
            }
            // Gateway client handles reconnection internally

        case .resumed:
            logger.info("Discord Gateway resumed.")
        }
    }

    // MARK: - Message Handling

    private func handleMessage(_ message: DiscordMessage) async {
        // Ignore bot's own messages
        guard message.author.bot != true else { return }

        let channelID = message.channel_id

        // Security gate
        guard await securityGate.authorizeDiscord(channelID: channelID, config: config) else { return }

        // Parse command
        let command = ChatOpsCommand.parseDiscord(
            text: message.content,
            awaitingClarification: awaitingClarification
        )

        // Tier enforcement
        guard await securityGate.canExecute(command, tier: config.securityTier) else {
            let msg = await securityGate.denialMessage(for: command, tier: config.securityTier)
            _ = try? await apiClient?.sendMessage(channelID: channelID, content: msg)
            return
        }

        // Route
        await routeCommand(command, channelID: channelID)
    }

    // MARK: - Interaction Handling

    private func handleInteraction(_ interaction: DiscordInteraction) async {
        let channelID = interaction.channel_id ?? config.discordAuthorizedChannelID ?? ""

        // Immediately acknowledge to meet Discord's 3-second deadline
        if interaction.type == DiscordInteraction.messageComponent {
            // Button click — deferred update (type 6)
            try? await apiClient?.respondToInteraction(
                interactionID: interaction.id,
                interactionToken: interaction.token,
                type: DiscordInteractionResponsePayload.deferredUpdateMessage
            )
        } else if interaction.type == DiscordInteraction.applicationCommand {
            // Slash command — deferred channel message (type 5)
            try? await apiClient?.respondToInteraction(
                interactionID: interaction.id,
                interactionToken: interaction.token,
                type: DiscordInteractionResponsePayload.deferredChannelMessage
            )
        }

        // Parse the command from the interaction
        let command: ChatOpsCommand
        if interaction.type == DiscordInteraction.messageComponent {
            command = ChatOpsCommand.parseDiscord(customID: interaction.data?.custom_id)
        } else if interaction.type == DiscordInteraction.applicationCommand {
            command = ChatOpsCommand.parseDiscord(slashCommandName: interaction.data?.name)
        } else {
            return
        }

        // Security gate
        guard await securityGate.authorizeDiscord(channelID: channelID, config: config) else { return }

        // Tier enforcement
        guard await securityGate.canExecute(command, tier: config.securityTier) else {
            let msg = await securityGate.denialMessage(for: command, tier: config.securityTier)
            if let appID = await apiClient?.applicationID {
                try? await apiClient?.editInteractionResponse(
                    applicationID: appID,
                    interactionToken: interaction.token,
                    content: msg
                )
            }
            return
        }

        // Route HITL commands directly
        switch command {
        case .approveHITL(let operationID):
            await remoteMirrorService?.handleApproval(operationID: operationID, approved: true)
            return
        case .denyHITL(let operationID):
            await remoteMirrorService?.handleApproval(operationID: operationID, approved: false)
            return
        case .gateChoiceHITL(let operationID, let optionIndex):
            await remoteMirrorService?.handleGate(operationID: operationID, optionIndex: optionIndex)
            return
        default:
            break
        }

        // For slash commands, route and send response via followup
        await routeInteractionCommand(command, interaction: interaction, channelID: channelID)
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
            if let convID = config.discordActiveConversationID,
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
            break // Handled by PairingService
        case .unknown:
            break
        }
    }

    /// Routes slash command interactions and responds via interaction followup.
    private func routeInteractionCommand(_ command: ChatOpsCommand, interaction: DiscordInteraction, channelID: String) async {
        guard let appID = await apiClient?.applicationID else { return }

        switch command {
        case .conversations:
            let text = await conversationListText()
            try? await apiClient?.editInteractionResponse(
                applicationID: appID,
                interactionToken: interaction.token,
                content: text
            )
        case .newConversation:
            await handleNewConversation(channelID: channelID)
        case .status:
            let text = await statusText()
            try? await apiClient?.editInteractionResponse(
                applicationID: appID,
                interactionToken: interaction.token,
                content: text
            )
        case .cancel:
            await handleCancel(channelID: channelID)
        case .help:
            let text = helpText()
            try? await apiClient?.editInteractionResponse(
                applicationID: appID,
                interactionToken: interaction.token,
                content: text
            )
        default:
            break
        }
    }

    // MARK: - Command Handlers

    private func handleConversations(channelID: String) async {
        let conversations = fetchRecentConversations(limit: 10)

        if conversations.isEmpty {
            _ = try? await apiClient?.sendMessage(channelID: channelID, content: "No conversations yet. Use /new to create one.")
            return
        }

        // Discord: max 5 buttons per ActionRow, max 5 rows
        var rows: [DiscordComponent] = []
        var currentButtons: [DiscordComponent] = []

        for conversationSD in conversations {
            let title = conversationSD.toRowStruct().displayTitle
            let convID = conversationSD.id
            let isActive = convID == config.discordActiveConversationID ? "⭐ " : ""
            let label = String("\(isActive)\(title)".prefix(80))

            currentButtons.append(
                DiscordComponent.button(
                    label: label,
                    customID: "switch:\(convID.uuidString)",
                    style: DiscordComponent.secondaryStyle
                )
            )

            if currentButtons.count == 5 {
                rows.append(DiscordComponent.actionRow(currentButtons))
                currentButtons = []
            }
        }

        // Add "New Conversation" button
        currentButtons.append(
            DiscordComponent.button(
                label: "➕ New Conversation",
                customID: "action:new",
                style: DiscordComponent.primaryStyle
            )
        )

        if !currentButtons.isEmpty {
            rows.append(DiscordComponent.actionRow(currentButtons))
        }

        _ = try? await apiClient?.sendMessage(
            channelID: channelID,
            content: "📋 **Your Conversations:**",
            components: rows
        )
    }

    private func handleNewConversation(channelID: String) async {
        guard let vm = viewModel else { return }

        guard let profile = resolveProfile() else {
            _ = try? await apiClient?.sendMessage(channelID: channelID, content: "⚠️ No agent profile configured. Set one in Devgentic Settings.")
            return
        }

        // Reuse an existing empty conversation
        if let emptyConv = findReusableEmptyConversation() {
            let reusedID = emptyConv.id
            config.discordActiveConversationID = reusedID
            vm.selectedConversationID = reusedID

            _ = try? await apiClient?.sendMessage(
                channelID: channelID,
                content: "✅ Switched to existing empty conversation.\nJust type your message to start."
            )
            logger.info("[Discord] Reused empty conversation \(reusedID.uuidString).")
            return
        }

        let convID = vm.createConversationForScheduledTask(profileID: profile, title: "Discord Chat")
        // [CF-39] See the Telegram bridge — provenance recorded at creation, not inferred later.
        RemoteConversationOriginStore.record(.discord, for: convID)
        config.discordActiveConversationID = convID
        vm.selectedConversationID = convID
        logger.info("[Discord] Mac UI navigated to new conversation \(convID.uuidString).")

        _ = try? await apiClient?.sendMessage(
            channelID: channelID,
            content: "✅ New conversation created and set as active.\nJust type your message to start."
        )
        logger.info("Created new conversation via Discord: \(convID.uuidString)")
    }

    private func handleStatus(channelID: String) async {
        let text = await statusText()
        _ = try? await apiClient?.sendMessage(channelID: channelID, content: text)
    }

    private func handleCancel(channelID: String) async {
        guard let conversationID = config.discordActiveConversationID else {
            _ = try? await apiClient?.sendMessage(channelID: channelID, content: "No active conversation to cancel.")
            return
        }

        // [WF-SE10] Cancel the RUN, not just its parked question — same teardown as the
        // in-app Stop button (cancellation cascades into any parked HITL and finalizes).
        // The suspension drain stays as belt-and-braces for a parked interaction with no
        // live stream task; after a stream cancel it finds nothing and no-ops.
        let hadActiveRun = viewModel?.activeStreamManager.hasActiveStream(inConversation: conversationID) ?? false
        viewModel?.activeStreamManager.cancelStreams(forConversation: conversationID)
        await ExecutionSuspensionService.shared.cancel(for: conversationID)
        awaitingClarification = false

        let reply = hadActiveRun
            ? "🛑 Cancelled the active run for this conversation."
            : "No run is currently active for this conversation — cleared any pending approvals."
        _ = try? await apiClient?.sendMessage(channelID: channelID, content: reply)
        logger.info("[CHATOPS] /cancel via Discord for conversation \(conversationID.uuidString) — hadActiveRun=\(hadActiveRun). CONSEQUENCE: the stream task itself was cancelled (not just the parked HITL), so the run stops instead of continuing after the bot claims it was cancelled.")
    }

    private func handleHelp(channelID: String) async {
        _ = try? await apiClient?.sendMessage(channelID: channelID, content: helpText())
    }

    private func handleSwitchConversation(to uuid: UUID, channelID: String) async {
        guard let vm = viewModel else { return }

        guard let conversationSD = vm.persistenceService.getConversation(withId: uuid) else {
            _ = try? await apiClient?.sendMessage(channelID: channelID, content: "⚠️ Conversation not found.")
            return
        }

        config.discordActiveConversationID = uuid
        awaitingClarification = false
        vm.selectedConversationID = uuid
        logger.info("[Discord] Mac UI navigated to conversation \(uuid.uuidString).")

        let title = conversationSD.toRowStruct().displayTitle
        _ = try? await apiClient?.sendMessage(
            channelID: channelID,
            content: "✅ Switched to: **\(title)**\n\nJust type your message to continue."
        )
        logger.info("Switched to conversation \(uuid.uuidString) via Discord.")
    }

    private func handleFreeText(_ text: String, channelID: String) async {
        guard let vm = viewModel else { return }

        guard let conversationID = config.discordActiveConversationID else {
            _ = try? await apiClient?.sendMessage(
                channelID: channelID,
                content: "No active conversation. Use /conversations to pick one or /new to create one."
            )
            return
        }

        guard let profile = resolveProfileForConversation(conversationID) else {
            _ = try? await apiClient?.sendMessage(
                channelID: channelID,
                content: "⚠️ No agent profile found for this conversation."
            )
            return
        }

        // Send typing indicator
        try? await apiClient?.sendTypingIndicator(channelID: channelID)

        let requestConfig = BackendRequestConfig(profile: profile)

        // Register the remote session for mirroring
        guard let transport = discordTransport else { return }

        remoteMirrorService?.registerSession(
            conversationID: conversationID,
            info: RemoteSessionInfo(
                transport: transport,
                chatID: channelID,
                source: .discord
            )
        )

        vm.submitRemoteMessage(
            prompt: text,
            conversationID: conversationID,
            source: .discord,
            config: requestConfig
        )
    }

    // MARK: - Text Builders

    private func conversationListText() async -> String {
        let conversations = fetchRecentConversations(limit: 10)
        if conversations.isEmpty {
            return "No conversations yet. Use /new to create one."
        }

        var lines = ["📋 **Your Conversations:**\n"]
        for (index, conversationSD) in conversations.enumerated() {
            let title = conversationSD.toRowStruct().displayTitle
            let isActive = conversationSD.id == config.discordActiveConversationID ? " ⭐" : ""
            lines.append("\(index + 1). \(title)\(isActive)")
        }
        return lines.joined(separator: "\n")
    }

    private func statusText() async -> String {
        guard let vm = viewModel else { return "Status unavailable." }

        // Conversation-scoped 2026-08-17 (design doc increment 1): this used to read the
        // app-global `vm.streamingMessageID`, so /status reported "streaming" whenever ANY
        // conversation was busy — including a main-window run the remote user has nothing to
        // do with — and reported idle the moment an unrelated run cleared the slot.
        let isStreaming = config.discordActiveConversationID.map { vm.activeStreamManager.hasActiveStream(inConversation: $0) } ?? false
        let activeConvTitle: String
        if let activeID = config.discordActiveConversationID,
           let conversationSD = vm.persistenceService.getConversation(withId: activeID) {
            activeConvTitle = conversationSD.toRowStruct().displayTitle
        } else {
            activeConvTitle = "None"
        }

        let allConversations = fetchRecentConversations(limit: 100)
        let tier = config.securityTier.rawValue

        return """
        📊 **Devgentic Status**

        🗣 Active Conversation: \(activeConvTitle)
        ⚡ Agent Streaming: \(isStreaming ? "Yes" : "No")
        🔐 Security Tier: \(tier)
        📋 Total Conversations: \(allConversations.count)
        """
    }

    private func helpText() -> String {
        """
        🤖 **Devgentic ChatOps (Discord)**

        **Commands:**
        /conversations — List your conversations
        /new — Start a new conversation
        /status — Current agent status
        /cancel — Stop the active agent
        /help — Show this message

        **How it works:**
        1. Use /conversations to pick a conversation
        2. Type your message — it routes to the agent
        3. The agent responds right here

        **Security Tier:** \(config.securityTier.rawValue)
        """
    }

    // MARK: - Profile Resolution

    private func resolveProfileForConversation(_ conversationID: UUID) -> BackendProfileModel? {
        guard let vm = viewModel else { return nil }
        let conversationSD = vm.persistenceService.getConversation(withId: conversationID)
        guard let profileID = conversationSD?.backendEntityId else { return nil }
        return ((try? BackendProfileStore.shared.fetchProfiles()) ?? []).first { $0.id == profileID }
    }

    private func resolveProfile() -> BackendProfileModel? {
        let profiles = (try? BackendProfileStore.shared.fetchSharedProfiles()) ?? []
        if let vm = viewModel,
           let selectedID = vm.backendConfiguration.selectedProfileID,
           let profile = profiles.first(where: { $0.id == selectedID }) {
            return profile
        }
        return profiles.first { $0.profileType == .agent } ?? profiles.first
    }

    // MARK: - SwiftData Helpers

    private func findReusableEmptyConversation() -> ConversationSD? {
        if let activeID = config.discordActiveConversationID,
           let activeEntity = viewModel?.persistenceService.getConversation(withId: activeID),
           activeEntity.messages.count == 0 {
            logger.info("[Discord] Active conversation \(activeID.uuidString) is empty — reusing.")
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
            logger.error("[Discord] Failed to query for empty conversations: \(error.localizedDescription)")
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
            logger.error("Failed to fetch conversations for Discord ChatOps: \(error.localizedDescription)")
            return []
        }
    }
}

// MARK: - DiscordAPIClient Extension

extension DiscordAPIClient {
    func setApplicationID(_ id: String) {
        self.applicationID = id
    }
}
