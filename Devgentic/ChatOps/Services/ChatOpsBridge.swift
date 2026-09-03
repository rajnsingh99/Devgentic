//
//  ChatOpsBridge.swift
//  Devgentic
//
//  Created by Raj Singh on 23/03/26.
//

import Foundation
import SwiftData
import os

/// The core orchestrator for Telegram ChatOps.
///
/// Routes incoming Telegram updates through the security gate, parses them into commands,
/// and dispatches them to the appropriate handler (conversation management, agent pipeline, HITL).
///
/// Uses the single-path architecture: remote messages flow through
/// `MainApplicationViewModel.submitRemoteMessage()` — the same path as the Mac UI.
/// The `RemoteMirrorService` handles mirroring events back to the transport.
@Observable @MainActor
final class ChatOpsBridge {

    private let logger = Logger(subsystem: DGLogger.subsystem, category: "ChatOpsBridge")

    // MARK: - Dependencies

    private weak var viewModel: MainApplicationViewModel?
    private var apiClient: TelegramAPIClient?
    private var listener: TelegramListener?
    private let securityGate = ChatOpsSecurityGate()
    private var telegramTransport: TelegramTransport?
    var remoteMirrorService: RemoteMirrorService?
    private let config = ChatOpsConfigManager.shared

    // MARK: - State

    private var listeningTask: Task<Void, Never>?
    private(set) var isRunning: Bool = false

    /// [D1] True when a clarification is pending for the active conversation — decides whether an inbound
    /// plain-text reply is parsed as a clarification answer vs a new message. Derived from the unified
    /// InteractionCenter (the old ChatOpsHITLBridge.awaitingClarification was dead state — only a
    /// never-posted notification set it, so Telegram clarification replies never registered).
    private var isAwaitingClarification: Bool {
        guard let convID = config.activeConversationID,
              let center = viewModel?.interactionCenter else { return false }
        return center.items(for: convID).contains { if case .clarification = $0.kind { return true }; return false }
    }

    init(viewModel: MainApplicationViewModel) {
        self.viewModel = viewModel
    }

    // MARK: - Lifecycle

    /// Starts the Telegram polling loop and begins processing updates.
    func start() {
        guard let token = config.botToken, !token.isEmpty else {
            logger.warning("Cannot start ChatOpsBridge — no bot token configured.")
            return
        }

        let client = TelegramAPIClient(botToken: token)
        let telegramListener = TelegramListener(apiClient: client)
        let transport = TelegramTransport(apiClient: client)

        self.apiClient = client
        self.listener = telegramListener
        self.telegramTransport = transport

        // Create RemoteMirrorService if ViewModel provides ActiveStreamManager
        if let asm = viewModel?.activeStreamManager {
            self.remoteMirrorService = RemoteMirrorService(activeStreamManager: asm)
        }

        isRunning = true

        listeningTask = Task { [weak self] in
            guard let self else { return }

            let stream = await telegramListener.start()
            self.logger.info("ChatOpsBridge started — listening for Telegram updates.")

            for await update in stream {
                await self.handleUpdate(update)
            }

            await MainActor.run {
                self.isRunning = false
                self.logger.info("ChatOpsBridge stopped.")
            }
        }
    }

    /// Stops the polling loop and cleans up.
    func stop() {
        listeningTask?.cancel()
        listeningTask = nil

        Task {
            await listener?.stop()
        }

        // [D2] Detach the mirror service so a stopped transport stops mirroring, then drop the strong ref.
        remoteMirrorService?.teardown()
        remoteMirrorService = nil

        isRunning = false
        logger.info("ChatOpsBridge stopped.")
    }

    // MARK: - Update Routing

    private func handleUpdate(_ update: TelegramUpdate) async {
        // 1. Security gate
        guard await securityGate.authorize(update, config: config) else { return }

        // 2. Acknowledge callback queries immediately to remove spinner
        if let callbackQuery = update.callback_query {
            try? await apiClient?.answerCallbackQuery(id: callbackQuery.id)
        }

        // 3. Parse command
        let command = ChatOpsCommand.parse(
            text: update.message?.text,
            callbackData: update.callback_query?.data,
            awaitingClarification: isAwaitingClarification
        )

        // 4. Tier enforcement
        guard await securityGate.canExecute(command, tier: config.securityTier) else {
            if let chatID = update.chatID {
                let msg = await securityGate.denialMessage(for: command, tier: config.securityTier)
                _ = try? await apiClient?.sendMessage(chatID: chatID, text: msg)
            }
            return
        }

        // 5. Route
        guard let chatID = update.chatID else { return }

        switch command {
        case .conversations:
            await handleConversations(chatID: chatID)
        case .newConversation:
            await handleNewConversation(chatID: chatID)
        case .status:
            await handleStatus(chatID: chatID)
        case .cancel:
            await handleCancel(chatID: chatID)
        case .help:
            await handleHelp(chatID: chatID)
        case .switchConversation(let uuid):
            await handleSwitchConversation(to: uuid, chatID: chatID)
        case .approveHITL(let operationID):
            await remoteMirrorService?.handleApproval(operationID: operationID, approved: true)
        case .denyHITL(let operationID):
            await remoteMirrorService?.handleApproval(operationID: operationID, approved: false)
        case .gateChoiceHITL(let operationID, let optionIndex):
            await remoteMirrorService?.handleGate(operationID: operationID, optionIndex: optionIndex)
        case .clarificationResponse(let text):
            // [HITL/P6] Resolve the pending clarification's operationID from the unified
            // InteractionCenter (single source of truth) for this conversation.
            if let convID = config.activeConversationID,
               let center = viewModel?.interactionCenter {
                let pendingOpID = center.items(for: convID)
                    .first(where: { if case .clarification = $0.kind { return true }; return false })?
                    .id
                if let opID = pendingOpID {
                    await remoteMirrorService?.handleClarification(operationID: opID, text: text)
                }
            }
        case .freeText(let text):
            await handleFreeText(text, chatID: chatID)
        case .pairingAttempt:
            // Handled by PairingService, not the bridge
            break
        case .unknown:
            break
        }
    }

    // MARK: - Command Handlers

    private func handleConversations(chatID: Int64) async {
        let conversations = fetchRecentConversations(limit: 10)

        if conversations.isEmpty {
            _ = try? await apiClient?.sendMessage(chatID: chatID, text: "No conversations yet. Use /new to create one.")
            return
        }

        let buttons: [[InlineKeyboardButton]] = conversations.map { conversationSD in
            let title = conversationSD.toRowStruct().displayTitle
            let convID = conversationSD.id
            let isActive = convID == config.activeConversationID ? "⭐ " : ""
            let label = "\(isActive)\(title)"
            return [InlineKeyboardButton(text: String(label.prefix(60)), callbackData: "switch:\(convID.uuidString)")]
        }

        var allButtons = buttons
        allButtons.append([InlineKeyboardButton(text: "➕ New Conversation", callbackData: "action:new")])

        let keyboard = InlineKeyboardMarkup(inline_keyboard: allButtons)

        _ = try? await apiClient?.sendMessage(
            chatID: chatID,
            text: "📋 *Your Conversations:*",
            replyMarkup: .inline(keyboard)
        )
    }

    private func handleNewConversation(chatID: Int64) async {
        guard let vm = viewModel else { return }

        // Use the currently selected profile, or the first available agent profile
        guard let profile = resolveProfile() else {
            _ = try? await apiClient?.sendMessage(chatID: chatID, text: "⚠️ No agent profile configured. Set one in Devgentic Settings.")
            return
        }

        // Reuse an existing empty conversation instead of creating duplicates.
        // Check the most recent conversations for one with zero messages.
        if let emptyConv = findReusableEmptyConversation() {
            let reusedID = emptyConv.id
            config.activeConversationID = reusedID
            vm.selectedConversationID = reusedID

            _ = try? await apiClient?.sendMessage(
                chatID: chatID,
                text: "✅ Switched to existing empty conversation.\nJust type your message to start."
            )
            logger.info("[ChatOps] Reused empty conversation \(reusedID.uuidString) instead of creating a new one.")
            return
        }

        let convID = vm.createConversationForScheduledTask(profileID: profile, title: "Telegram Chat")
        config.activeConversationID = convID

        // Auto-navigate Mac UI to the new conversation
        vm.selectedConversationID = convID
        logger.info("[ChatOps] Mac UI navigated to new conversation \(convID.uuidString).")

        _ = try? await apiClient?.sendMessage(
            chatID: chatID,
            text: "✅ New conversation created and set as active.\nJust type your message to start."
        )
        logger.info("Created new conversation via Telegram: \(convID.uuidString)")
    }

    private func handleStatus(chatID: Int64) async {
        guard let vm = viewModel else { return }

        // Conversation-scoped 2026-08-17 (design doc increment 1): this used to read the
        // app-global `vm.streamingMessageID`, so /status reported "streaming" whenever ANY
        // conversation was busy — including a main-window run the remote user has nothing to
        // do with — and reported idle the moment an unrelated run cleared the slot.
        let isStreaming = config.activeConversationID.map { vm.activeStreamManager.hasActiveStream(inConversation: $0) } ?? false
        let activeConvTitle: String
        if let activeID = config.activeConversationID,
           let conversationSD = vm.persistenceService.getConversation(withId: activeID) {
            activeConvTitle = conversationSD.toRowStruct().displayTitle
        } else {
            activeConvTitle = "None"
        }

        let allConversations = fetchRecentConversations(limit: 100)
        let tier = config.securityTier.rawValue
        let hitlPending = isAwaitingClarification ? "Yes" : "No"

        let statusText = """
        📊 *Devgentic Status*

        🗣 Active Conversation: \(activeConvTitle)
        ⚡ Agent Streaming: \(isStreaming ? "Yes" : "No")
        🔐 Security Tier: \(tier)
        ⏳ HITL Pending: \(hitlPending)
        📋 Total Conversations: \(allConversations.count)
        """

        _ = try? await apiClient?.sendMessage(chatID: chatID, text: statusText)
    }

    private func handleCancel(chatID: Int64) async {
        guard let conversationID = config.activeConversationID else {
            _ = try? await apiClient?.sendMessage(chatID: chatID, text: "No active conversation to cancel.")
            return
        }

        // [WF-SE10] Cancel the RUN, not just its parked question. This handler used to call
        // only `ExecutionSuspensionService.cancel(for:)` and then claim the agent was
        // cancelled — but that merely denies a parked HITL; the stream kept executing (and a
        // denied Gate manufactured a red "not answered" failure that routed the run down its
        // error branch, WF-CC1). `cancelStreams` is the same teardown the in-app Stop button
        // uses: cancellation cascades into any parked suspension and finalizes the message.
        let hadActiveRun = viewModel?.activeStreamManager.hasActiveStream(inConversation: conversationID) ?? false
        viewModel?.activeStreamManager.cancelStreams(forConversation: conversationID)
        // Belt-and-braces for a parked interaction with no live stream task (the pre-fix
        // shape); after a stream cancel this finds nothing and no-ops.
        await ExecutionSuspensionService.shared.cancel(for: conversationID)

        let reply = hadActiveRun
            ? "🛑 Cancelled the active run for this conversation."
            : "No run is currently active for this conversation — cleared any pending approvals."
        _ = try? await apiClient?.sendMessage(chatID: chatID, text: reply)
        logger.info("[CHATOPS] /cancel via Telegram for conversation \(conversationID.uuidString) — hadActiveRun=\(hadActiveRun). CONSEQUENCE: the stream task itself was cancelled (not just the parked HITL), so the run stops instead of continuing after the bot claims it was cancelled.")
    }

    private func handleHelp(chatID: Int64) async {
        let helpText = """
        🤖 *Devgentic ChatOps*

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

        _ = try? await apiClient?.sendMessage(chatID: chatID, text: helpText)
    }

    private func handleSwitchConversation(to uuid: UUID, chatID: Int64) async {
        guard let vm = viewModel else { return }

        guard let conversationSD = vm.persistenceService.getConversation(withId: uuid) else {
            _ = try? await apiClient?.sendMessage(chatID: chatID, text: "⚠️ Conversation not found.")
            return
        }

        config.activeConversationID = uuid

        // Auto-navigate Mac UI to the switched conversation
        vm.selectedConversationID = uuid
        logger.info("[ChatOps] Mac UI navigated to conversation \(uuid.uuidString).")

        let title = conversationSD.toRowStruct().displayTitle
        _ = try? await apiClient?.sendMessage(
            chatID: chatID,
            text: "✅ Switched to: *\(title)*\n\nJust type your message to continue."
        )
        logger.info("Switched to conversation \(uuid.uuidString) via Telegram.")
    }

    private func handleFreeText(_ text: String, chatID: Int64) async {
        guard let vm = viewModel else { return }

        // Ensure there's an active conversation
        guard let conversationID = config.activeConversationID else {
            _ = try? await apiClient?.sendMessage(
                chatID: chatID,
                text: "No active conversation. Use /conversations to pick one or /new to create one."
            )
            return
        }

        // Resolve the backend profile for this conversation
        guard let profile = resolveProfileForConversation(conversationID) else {
            _ = try? await apiClient?.sendMessage(
                chatID: chatID,
                text: "⚠️ No agent profile found for this conversation."
            )
            return
        }

        // Send typing indicator
        _ = try? await apiClient?.sendTypingAction(chatID: chatID)

        let requestConfig = BackendRequestConfig(profile: profile)

        // Single-path architecture: route through the SAME flow as Mac UI.
        // The RemoteMirrorService will observe the stream and mirror events back to Telegram.
        // Register the remote session so the mirror service knows where to send responses.
        remoteMirrorService?.registerSession(
            conversationID: conversationID,
            info: RemoteSessionInfo(
                transport: telegramTransport!,
                chatID: "\(chatID)",
                source: .telegram
            )
        )

        // Submit through the main app flow — message appears in Mac UI, agent runs,
        // HITL banners show, and RemoteMirrorService handles the Telegram response.
        vm.submitRemoteMessage(
            prompt: text,
            conversationID: conversationID,
            source: .telegram,
            config: requestConfig
        )
    }

    // MARK: - Profile Resolution

    /// Resolves the backend profile for a given conversation from its `backendEntityId`.
    private func resolveProfileForConversation(_ conversationID: UUID) -> BackendProfileModel? {
        guard let vm = viewModel else { return nil }

        let conversationSD = vm.persistenceService.getConversation(withId: conversationID)
        guard let profileID = conversationSD?.backendEntityId else { return nil }

        return ((try? BackendProfileStore.shared.fetchProfiles()) ?? []).first { $0.id == profileID }
    }

    /// Resolves a default profile for new conversations — prefers agent profiles.
    private func resolveProfile() -> BackendProfileModel? {
        let profiles = (try? BackendProfileStore.shared.fetchSharedProfiles()) ?? []

        // First try the currently selected profile in the UI
        if let vm = viewModel,
           let selectedID = vm.backendConfiguration.selectedProfileID,
           let profile = profiles.first(where: { $0.id == selectedID }) {
            return profile
        }

        // Fall back to first agent profile
        return profiles.first { $0.profileType == .agent } ?? profiles.first
    }

    // MARK: - Persistence Helpers

    /// Finds the most recent empty conversation that can be reused instead of creating a new one.
    private func findReusableEmptyConversation() -> ConversationSD? {
        // Fast path: check if the current active conversation is already empty
        if let activeID = config.activeConversationID,
           let activeSD = viewModel?.persistenceService.getConversation(withId: activeID),
           activeSD.messages.isEmpty {
            logger.info("[ChatOps] Active conversation \(activeID.uuidString) is empty — reusing.")
            return activeSD
        }

        // Slow path: query for recent empty conversations
        guard let context = ChatPersistenceStore.shared.modelContainer?.mainContext else { return nil }
        var descriptor = FetchDescriptor<ConversationSD>(
            sortBy: [SortDescriptor(\.timestamp, order: .reverse)]
        )
        descriptor.fetchLimit = 10
        guard let results = try? context.fetch(descriptor) else { return nil }
        return results.first { $0.messages.isEmpty }
    }

    /// Fetches recent conversations from SwiftData.
    private func fetchRecentConversations(limit: Int) -> [ConversationSD] {
        guard let context = ChatPersistenceStore.shared.modelContainer?.mainContext else { return [] }
        var descriptor = FetchDescriptor<ConversationSD>(
            sortBy: [
                SortDescriptor(\.timestamp, order: .reverse)
            ]
        )
        descriptor.fetchLimit = limit
        return (try? context.fetch(descriptor)) ?? []
    }
}
