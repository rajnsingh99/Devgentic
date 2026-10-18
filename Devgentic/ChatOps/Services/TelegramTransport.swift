// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
//
//  TelegramTransport.swift
//  Devgentic
//
//  Created by Raj Singh.
//

import Foundation
import os

/// Adapts `TelegramAPIClient` to `ChatOpsTransport`; all HTTP logic stays in the client.
/// Sends plain text (no Markdown) to avoid parse failures on code, converting String ids to Telegram's
/// Int64 at the boundary.
final class TelegramTransport: ChatOpsTransport, @unchecked Sendable {

    let transportID = "telegram"

    private let apiClient: TelegramAPIClient
    private let logger = DGLogger(category: "TelegramTransport")

    init(apiClient: TelegramAPIClient) {
        self.apiClient = apiClient
    }

    // MARK: - ChatOpsTransport

    func sendTextMessage(chatID: String, text: String) async throws {
        // The egress floor: sanitised here, before chunking, so a credential split across chunks cannot slip
        // past a client-side pass.
        try await apiClient.sendMessage(chatID: Int64(chatID)!, text: RemoteEgressSanitizer.credentialsOnly(text), parseMode: nil)
    }

    func sendChunkedMessage(chatID: String, text: String) async throws {
        // The egress floor: sanitised here, before chunking, so a credential split across chunks cannot slip
        // past a client-side pass.
        try await apiClient.sendChunkedMessage(chatID: Int64(chatID)!, text: RemoteEgressSanitizer.credentialsOnly(text), parseMode: nil)
    }

    func editMessage(chatID: String, messageID: String, newText: String) async throws {
        let newText = RemoteEgressSanitizer.credentialsOnly(newText)
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

// MARK: - Remote view rendering (C3)
// Lives in this file because `apiClient` is `private`, which is file-scoped in Swift.

extension TelegramTransport {

    nonisolated var capabilities: RemoteCapabilities { TelegramRemoteRenderer.capabilities }

    @discardableResult
    func render(_ view: RemoteView, to destination: RemoteDestination) async throws -> String? {
        // Sanitises the view, not the rendered text: Slack puts the body in blocks and platforms put
        // conversation titles on button labels.
        let view = view.sanitizedForEgress()
        let channel = destination.channel
        guard let draft = TelegramRemoteRenderer.draft(for: view) else {
            if case .silent(let silence) = view {
                RemoteRenderLog.silence(silence, channel: channel, logger: logger)
            }
            return nil
        }
        // Throws instead of force-unwrapping `Int64(chatID)`; the other force-unwraps are safe only because
        // their producer builds the string from an `Int64`.
        guard let chatID = Int64(channel.channelID) else {
            logger.error("[CHATOPS/RENDER] Telegram channel id \"\(channel.channelID)\" is not numeric, so the view was NOT posted. CONSEQUENCE: the remote user receives no reply at all and the command appears to have been ignored.")
            throw RemoteRenderError.unaddressableChannel(provider: .telegram, channelID: channel.channelID)
        }
        // `destination` is always a channel post: Telegram has no interaction-reply channel, so
        // `.interactionReply` degrades to the same call.
        let message = try await apiClient.sendMessage(
            chatID: chatID,
            text: draft.text,
            parseMode: draft.parse_mode,
            // The draft names its own reply-markup kind, so a `ForceReply` is not forced back into an inline
            // keyboard.
            replyMarkup: draft.reply_markup
        )
        RemoteRenderLog.posted(view, channel: channel, logger: logger)
        return "\(message.message_id)"
    }
}
