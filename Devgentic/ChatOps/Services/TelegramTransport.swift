//
//  TelegramTransport.swift
//  Devgentic
//
//  Created by Raj Singh on 23/03/26.
//

import Foundation
import os

/// Adapts `TelegramAPIClient` to the `ChatOpsTransport` protocol.
///
/// This is a thin wrapper — all actual HTTP logic stays in `TelegramAPIClient`.
/// The transport sends plain text (no Markdown) for agent responses to avoid
/// parse failures on code-heavy content.
///
/// Telegram uses numeric IDs internally — this transport converts between
/// the protocol's String IDs and Telegram's Int64/Int at the boundary.
final class TelegramTransport: ChatOpsTransport, @unchecked Sendable {

    let transportID = "telegram"

    private let apiClient: TelegramAPIClient
    private let logger = Logger(subsystem: "com.devgentic", category: "TelegramTransport")

    init(apiClient: TelegramAPIClient) {
        self.apiClient = apiClient
    }

    // MARK: - ChatOpsTransport

    func sendTextMessage(chatID: String, text: String) async throws {
        try await apiClient.sendMessage(chatID: Int64(chatID)!, text: text, parseMode: nil)
    }

    func sendChunkedMessage(chatID: String, text: String) async throws {
        try await apiClient.sendChunkedMessage(chatID: Int64(chatID)!, text: text, parseMode: nil)
    }

    func sendHITLPrompt(
        chatID: String,
        operationID: UUID,
        type: HITLType
    ) async throws -> String {
        let numericChatID = Int64(chatID)!

        switch type {
        case .toolConfirmation(let toolName, let params):
            let truncatedParams = String(params.prefix(500))
            let messageText = """
            ⚠️ Tool Approval Required

            Tool: \(toolName)
            Params: \(truncatedParams)

            Tap to approve or deny:
            """

            let keyboard = InlineKeyboardMarkup(
                inline_keyboard: [[
                    InlineKeyboardButton(text: "✅ Approve", callbackData: "hitl:approve:\(operationID.uuidString)"),
                    InlineKeyboardButton(text: "❌ Deny", callbackData: "hitl:deny:\(operationID.uuidString)")
                ]]
            )

            let message = try await apiClient.sendMessage(
                chatID: numericChatID,
                text: messageText,
                parseMode: nil,
                replyMarkup: .inline(keyboard)
            )
            return "\(message.message_id)"

        case .clarification(let question):
            let messageText = """
            💬 Agent needs clarification:

            \(question)

            Reply with your answer, or type /skip to skip.
            """

            let message = try await apiClient.sendMessage(
                chatID: numericChatID,
                text: messageText,
                parseMode: nil
            )
            return "\(message.message_id)"

        case .planReview(let subtaskDescriptions):
            let planList = subtaskDescriptions.enumerated()
                .map { "  \($0.offset + 1). \($0.element)" }
                .joined(separator: "\n")
            let messageText = """
            📋 Plan Review Required

            The agent has generated a plan with \(subtaskDescriptions.count) step(s):

            \(planList)

            Please approve or edit this plan from the Mac app.
            """

            let message = try await apiClient.sendMessage(
                chatID: numericChatID,
                text: messageText,
                parseMode: nil
            )
            return "\(message.message_id)"
        }
    }

    func editMessage(chatID: String, messageID: String, newText: String) async throws {
        try await apiClient.editMessageText(
            chatID: Int64(chatID)!,
            messageID: Int(messageID)!,
            text: newText,
            parseMode: nil
        )
    }

    func sendTypingIndicator(chatID: String) async throws {
        try await apiClient.sendTypingAction(chatID: Int64(chatID)!)
    }
}
