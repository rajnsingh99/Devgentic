//
//  DiscordTransport.swift
//  Devgentic
//
//  Created by Raj Singh on 24/03/26.
//

import Foundation
import os

/// Adapts `DiscordAPIClient` to the `ChatOpsTransport` protocol.
///
/// This is a thin wrapper — all actual HTTP logic stays in `DiscordAPIClient`.
/// The transport sends plain text (no markdown) for agent responses to avoid
/// formatting issues with code-heavy content.
final class DiscordTransport: ChatOpsTransport, @unchecked Sendable {

    let transportID = "discord"

    private let apiClient: DiscordAPIClient
    private let logger = Logger(subsystem: "com.devgentic", category: "DiscordTransport")

    init(apiClient: DiscordAPIClient) {
        self.apiClient = apiClient
    }

    // MARK: - ChatOpsTransport

    func sendTextMessage(chatID: String, text: String) async throws {
        try await apiClient.sendMessage(channelID: chatID, content: text)
    }

    func sendChunkedMessage(chatID: String, text: String) async throws {
        try await apiClient.sendChunkedMessage(channelID: chatID, content: text)
    }

    func sendHITLPrompt(
        chatID: String,
        operationID: UUID,
        type: HITLType
    ) async throws -> String {
        switch type {
        case .toolConfirmation(let toolName, let params):
            let truncatedParams = String(params.prefix(500))
            let messageText = """
            ⚠️ **Tool Approval Required**

            **Tool:** \(toolName)
            **Params:** \(truncatedParams)

            Tap to approve or deny:
            """

            let approveButton = DiscordComponent.button(
                label: "✅ Approve",
                customID: "hitl:approve:\(operationID.uuidString)",
                style: DiscordComponent.successStyle
            )
            let denyButton = DiscordComponent.button(
                label: "❌ Deny",
                customID: "hitl:deny:\(operationID.uuidString)",
                style: DiscordComponent.dangerStyle
            )
            let row = DiscordComponent.actionRow([approveButton, denyButton])

            let message = try await apiClient.sendMessage(
                channelID: chatID,
                content: messageText,
                components: [row]
            )
            return message.id

        case .clarification(let question):
            let messageText = """
            💬 **Agent needs clarification:**

            \(question)

            Reply with your answer, or type /skip to skip.
            """

            let message = try await apiClient.sendMessage(
                channelID: chatID,
                content: messageText
            )
            return message.id
        }
    }

    func editMessage(chatID: String, messageID: String, newText: String) async throws {
        try await apiClient.editMessage(
            channelID: chatID,
            messageID: messageID,
            content: newText,
            components: [] // Clear buttons after resolution
        )
    }

    func sendTypingIndicator(chatID: String) async throws {
        try await apiClient.sendTypingIndicator(channelID: chatID)
    }
}
