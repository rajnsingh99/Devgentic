//
//  SlackTransport.swift
//  Devgentic
//
//  Created by Raj Singh on 24/03/26.
//

import Foundation
import os

/// Adapts `SlackAPIClient` to the `ChatOpsTransport` protocol.
///
/// Uses Block Kit for interactive HITL prompts and plain text for agent responses.
/// Slack has no bot typing indicator, so `sendTypingIndicator` is a no-op.
final class SlackTransport: ChatOpsTransport, @unchecked Sendable {

    let transportID = "slack"

    private let apiClient: SlackAPIClient
    private let logger = Logger(subsystem: "com.devgentic", category: "SlackTransport")

    init(apiClient: SlackAPIClient) {
        self.apiClient = apiClient
    }

    // MARK: - ChatOpsTransport

    func sendTextMessage(chatID: String, text: String) async throws {
        try await apiClient.postMessage(channel: chatID, text: text)
    }

    func sendChunkedMessage(chatID: String, text: String) async throws {
        try await apiClient.sendChunkedMessage(channel: chatID, text: text)
    }

    func sendHITLPrompt(
        chatID: String,
        operationID: UUID,
        type: HITLType
    ) async throws -> String {
        switch type {
        case .toolConfirmation(let toolName, let params):
            let truncatedParams = String(params.prefix(500))
            let messageText = "⚠️ *Tool Approval Required*\n\n*Tool:* \(toolName)\n*Params:* \(truncatedParams)"

            let approveButton = SlackBlockElement.button(
                text: "✅ Approve",
                actionID: "hitl:approve:\(operationID.uuidString)",
                value: "approve",
                style: SlackBlockElement.primaryStyle
            )
            let denyButton = SlackBlockElement.button(
                text: "❌ Deny",
                actionID: "hitl:deny:\(operationID.uuidString)",
                value: "deny",
                style: SlackBlockElement.dangerStyle
            )

            let blocks: [SlackBlock] = [
                .sectionBlock(text: messageText),
                .actionsBlock(elements: [approveButton, denyButton], blockID: "hitl_\(operationID.uuidString)")
            ]

            let result = try await apiClient.postMessage(
                channel: chatID,
                text: messageText, // Fallback for notifications
                blocks: blocks
            )
            return result.ts

        case .clarification(let question):
            let messageText = "💬 *Agent needs clarification:*\n\n\(question)\n\nReply with your answer, or type /skip to skip."

            let result = try await apiClient.postMessage(
                channel: chatID,
                text: messageText
            )
            return result.ts
        }
    }

    func editMessage(chatID: String, messageID: String, newText: String) async throws {
        try await apiClient.updateMessage(
            channel: chatID,
            ts: messageID,
            text: newText,
            blocks: [] // Clear buttons after resolution
        )
    }

    func sendTypingIndicator(chatID: String) async throws {
        // Slack has no bot typing indicator — no-op
    }
}
