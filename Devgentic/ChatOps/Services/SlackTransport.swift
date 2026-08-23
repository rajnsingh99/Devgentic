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
    private let logger = Logger(subsystem: DGLogger.subsystem, category: "SlackTransport")

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

        case .planReview(let subtaskDescriptions):
            let planList = subtaskDescriptions.enumerated()
                .map { "  \($0.offset + 1). \($0.element)" }
                .joined(separator: "\n")
            let messageText = "📋 *Plan Review Required*\n\nThe agent has generated a plan with \(subtaskDescriptions.count) step(s):\n\n\(planList)\n\nTap to approve or reject (edit on the Mac app):"

            // [D1] Approve/reject buttons → kind-aware handleApproval → resumePlanReview.
            let approveButton = SlackBlockElement.button(
                text: "✅ Approve",
                actionID: "hitl:approve:\(operationID.uuidString)",
                value: "approve",
                style: SlackBlockElement.primaryStyle
            )
            let rejectButton = SlackBlockElement.button(
                text: "❌ Reject",
                actionID: "hitl:deny:\(operationID.uuidString)",
                value: "deny",
                style: SlackBlockElement.dangerStyle
            )
            let blocks: [SlackBlock] = [
                .sectionBlock(text: messageText),
                .actionsBlock(elements: [approveButton, rejectButton], blockID: "hitl_\(operationID.uuidString)")
            ]

            let result = try await apiClient.postMessage(
                channel: chatID,
                text: messageText,
                blocks: blocks
            )
            return result.ts

        case .gate(let prompt, let options):
            // [D1] One Slack button per gate option; tap → "hitl:gate:<opID>:<idx>".
            let messageText = "🚦 *Decision Required*\n\n\(prompt)\n\nChoose an option:"
            let buttons = options.enumerated().map { idx, opt in
                SlackBlockElement.button(
                    text: String(opt.prefix(70)),   // under Slack's 75-char button-text cap
                    actionID: "hitl:gate:\(operationID.uuidString):\(idx)",
                    value: "gate_\(idx)",
                    style: nil
                )
            }
            // Slack caps an actions block at 5 elements — chunk into rows of 5 like Discord.
            var blocks: [SlackBlock] = [.sectionBlock(text: messageText)]
            for start in stride(from: 0, to: buttons.count, by: 5) {
                blocks.append(.actionsBlock(
                    elements: Array(buttons[start..<min(start + 5, buttons.count)]),
                    blockID: "hitl_\(operationID.uuidString)_\(start)"
                ))
            }

            let result = try await apiClient.postMessage(
                channel: chatID,
                text: messageText,
                blocks: blocks
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
