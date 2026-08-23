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
    private let logger = Logger(subsystem: DGLogger.subsystem, category: "DiscordTransport")

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

        case .planReview(let subtaskDescriptions):
            let planList = subtaskDescriptions.enumerated()
                .map { "  \($0.offset + 1). \($0.element)" }
                .joined(separator: "\n")
            let messageText = """
            📋 **Plan Review Required**

            The agent has generated a plan with \(subtaskDescriptions.count) step(s):

            \(planList)

            Tap to approve or reject (edit on the Mac app):
            """

            // [D1] Approve/reject buttons → kind-aware handleApproval → resumePlanReview.
            let approveButton = DiscordComponent.button(
                label: "✅ Approve",
                customID: "hitl:approve:\(operationID.uuidString)",
                style: DiscordComponent.successStyle
            )
            let rejectButton = DiscordComponent.button(
                label: "❌ Reject",
                customID: "hitl:deny:\(operationID.uuidString)",
                style: DiscordComponent.dangerStyle
            )
            let row = DiscordComponent.actionRow([approveButton, rejectButton])

            let message = try await apiClient.sendMessage(
                channelID: chatID,
                content: messageText,
                components: [row]
            )
            return message.id

        case .gate(let prompt, let options):
            // [D1] One button per gate option; tap → "hitl:gate:<opID>:<idx>". Discord caps 5
            // buttons/row, so chunk into rows of 5 (gates have 2–4 options in practice).
            let messageText = """
            🚦 **Decision Required**

            \(prompt)

            Choose an option:
            """
            let buttons = options.enumerated().map { idx, opt in
                DiscordComponent.button(
                    label: String(opt.prefix(70)),   // under Discord's 80-char button-label cap
                    customID: "hitl:gate:\(operationID.uuidString):\(idx)",
                    style: DiscordComponent.secondaryStyle
                )
            }
            let rows = stride(from: 0, to: buttons.count, by: 5).map { start in
                DiscordComponent.actionRow(Array(buttons[start..<min(start + 5, buttons.count)]))
            }

            let message = try await apiClient.sendMessage(
                channelID: chatID,
                content: messageText,
                components: rows
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
