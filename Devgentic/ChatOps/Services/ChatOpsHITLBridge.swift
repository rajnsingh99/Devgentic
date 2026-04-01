//
//  ChatOpsHITLBridge.swift
//  Devgentic
//
//  Created by Raj Singh on 23/03/26.
//

import Foundation
import os

/// Notification names posted by `ToolExecutionLoop` when HITL events occur.
/// The ChatOpsHITLBridge observes these to relay approval/clarification requests to Telegram.
extension Notification.Name {
    static let chatOpsToolConfirmationRequested = Notification.Name("chatOpsToolConfirmationRequested")
    static let chatOpsClarificationRequested = Notification.Name("chatOpsClarificationRequested")
}

/// UserInfo keys for HITL notifications.
enum ChatOpsHITLNotificationKey {
    static let conversationID = "conversationID"
    static let toolName = "toolName"
    static let params = "params"
    static let question = "question"
}

/// Bridges HITL (Human-In-The-Loop) events from the agent execution pipeline to Telegram.
///
/// When a tool requires confirmation or the agent asks a clarification question,
/// this bridge sends inline keyboard buttons to Telegram and relays the user's
/// response back to `ExecutionSuspensionService`.
@MainActor
final class ChatOpsHITLBridge {

    private let logger = Logger(subsystem: "com.devgentic", category: "ChatOpsHITL")
    private let apiClient: TelegramAPIClient
    private let config: ChatOpsConfigManager

    /// Whether we are currently waiting for a clarification response from Telegram.
    private(set) var awaitingClarification: Bool = false

    /// The conversation ID that is currently suspended for HITL.
    private var suspendedConversationID: UUID?

    private var confirmationObserver: Any?
    private var clarificationObserver: Any?
    private var permissionResolvedObserver: Any?
    private var clarificationResolvedObserver: Any?

    init(apiClient: TelegramAPIClient, config: ChatOpsConfigManager) {
        self.apiClient = apiClient
        self.config = config
        setupObservers()
    }

    deinit {
        if let obs = confirmationObserver { NotificationCenter.default.removeObserver(obs) }
        if let obs = clarificationObserver { NotificationCenter.default.removeObserver(obs) }
        if let obs = permissionResolvedObserver { NotificationCenter.default.removeObserver(obs) }
        if let obs = clarificationResolvedObserver { NotificationCenter.default.removeObserver(obs) }
    }

    // MARK: - Notification Observers

    private func setupObservers() {
        confirmationObserver = NotificationCenter.default.addObserver(
            forName: .chatOpsToolConfirmationRequested,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            Task { @MainActor [weak self] in
                await self?.handleConfirmationRequest(notification)
            }
        }

        clarificationObserver = NotificationCenter.default.addObserver(
            forName: .chatOpsClarificationRequested,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            Task { @MainActor [weak self] in
                await self?.handleClarificationRequest(notification)
            }
        }

        // Observe resolved notifications — when the Mac UI responds first,
        // clear our local state and inform the Telegram user.
        permissionResolvedObserver = NotificationCenter.default.addObserver(
            forName: .hitlPermissionResolved,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            Task { @MainActor [weak self] in
                self?.handlePermissionResolved(notification)
            }
        }

        clarificationResolvedObserver = NotificationCenter.default.addObserver(
            forName: .hitlClarificationResolved,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            Task { @MainActor [weak self] in
                await self?.handleClarificationResolved(notification)
            }
        }
    }

    // MARK: - Handle Incoming HITL Events

    private func handleConfirmationRequest(_ notification: Notification) async {
        guard let chatID = config.authorizedChatID,
              config.isEnabled,
              config.securityTier == .full else { return }

        guard let userInfo = notification.userInfo,
              let conversationID = userInfo[ChatOpsHITLNotificationKey.conversationID] as? UUID,
              let toolName = userInfo[ChatOpsHITLNotificationKey.toolName] as? String,
              let params = userInfo[ChatOpsHITLNotificationKey.params] as? String else { return }

        // Only relay if this is the active ChatOps conversation
        guard conversationID == config.activeConversationID else { return }

        suspendedConversationID = conversationID

        let messageText = """
        ⚠️ *Tool Approval Required*

        🔧 Tool: `\(toolName)`
        📋 Params: `\(String(params.prefix(500)))`

        Tap a button below to respond:
        """

        let keyboard = InlineKeyboardMarkup(inline_keyboard: [
            [
                InlineKeyboardButton(text: "✅ Approve", callbackData: "hitl:approve"),
                InlineKeyboardButton(text: "❌ Deny", callbackData: "hitl:deny")
            ]
        ])

        do {
            try await apiClient.sendMessage(
                chatID: chatID,
                text: messageText,
                replyMarkup: .inline(keyboard)
            )
            logger.info("Sent HITL confirmation request to Telegram for tool: \(toolName)")
        } catch {
            logger.error("Failed to send HITL confirmation to Telegram: \(error.localizedDescription)")
        }
    }

    private func handleClarificationRequest(_ notification: Notification) async {
        // Clarifications (ask_user) are allowed at .standard tier — the agent is just asking a question,
        // not executing a dangerous action. Only tool approval (approve/deny) requires .full.
        guard let chatID = config.authorizedChatID,
              config.isEnabled,
              (config.securityTier == .standard || config.securityTier == .full) else { return }

        guard let userInfo = notification.userInfo,
              let conversationID = userInfo[ChatOpsHITLNotificationKey.conversationID] as? UUID,
              let question = userInfo[ChatOpsHITLNotificationKey.question] as? String else { return }

        // Only relay if this is the active ChatOps conversation
        guard conversationID == config.activeConversationID else { return }

        suspendedConversationID = conversationID
        awaitingClarification = true

        let messageText = """
        💬 *Agent needs clarification:*

        \(question)

        Reply with your answer, or type /skip to skip.
        """

        do {
            try await apiClient.sendMessage(chatID: chatID, text: messageText)
            logger.info("Sent clarification request to Telegram.")
        } catch {
            logger.error("Failed to send clarification request to Telegram: \(error.localizedDescription)")
        }
    }

    // MARK: - Handle Resolved Notifications (Cross-Surface Sync)

    /// Called when a permission suspension is resolved (by ANY surface — Mac UI, Telegram, or timeout).
    /// If we had a pending HITL state, clear it and notify the Telegram user.
    private func handlePermissionResolved(_ notification: Notification) {
        guard suspendedConversationID != nil,
              !awaitingClarification else { return } // Only clear permission state, not clarification

        let approved = notification.userInfo?[HITLResolvedKey.approved] as? Bool ?? false
        logger.info("Permission resolved externally (approved: \(approved)). Clearing Telegram HITL state.")
        suspendedConversationID = nil

        // Inform the Telegram user that the action was handled from the Mac
        if let chatID = config.authorizedChatID, config.isEnabled {
            let statusText = approved ? "✅ Tool approved (from Mac)." : "❌ Tool denied (from Mac)."
            Task {
                try? await apiClient.sendMessage(chatID: chatID, text: statusText)
            }
        }
    }

    /// Called when a clarification suspension is resolved (by ANY surface).
    private func handleClarificationResolved(_ notification: Notification) async {
        guard awaitingClarification else { return }

        logger.info("Clarification resolved externally. Clearing Telegram HITL state.")
        awaitingClarification = false
        suspendedConversationID = nil

        // Inform the Telegram user that the question was answered from the Mac
        if let chatID = config.authorizedChatID, config.isEnabled {
            _ = try? await apiClient.sendMessage(chatID: chatID, text: "✅ Clarification handled (from Mac).")
        }
    }

    // MARK: - Relay User Responses Back to Agent

    /// Relays a tool approval/denial from Telegram back to the suspended agent.
    func relayApproval(approved: Bool) async {
        guard let conversationID = suspendedConversationID else {
            logger.warning("No suspended conversation for HITL approval relay.")
            return
        }

        await ExecutionSuspensionService.shared.resume(for: conversationID, approved: approved)
        suspendedConversationID = nil

        logger.info("Relayed HITL approval (\(approved)) for conversation \(conversationID.uuidString)")
    }

    /// Relays a clarification response from Telegram back to the suspended agent.
    func relayClarification(text: String) async {
        guard let conversationID = suspendedConversationID else {
            logger.warning("No suspended conversation for clarification relay.")
            return
        }

        let response: String? = text.isEmpty ? nil : text
        await ExecutionSuspensionService.shared.resumeClarification(for: conversationID, userInput: response)

        awaitingClarification = false
        suspendedConversationID = nil

        logger.info("Relayed clarification response for conversation \(conversationID.uuidString)")
    }

    /// Resets HITL state (e.g., on disconnect or conversation switch).
    func reset() {
        awaitingClarification = false
        suspendedConversationID = nil
    }
}
