// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2026 Raj Singh
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
    private let logger = Logger(subsystem: DGLogger.subsystem, category: "TelegramTransport")

    init(apiClient: TelegramAPIClient) {
        self.apiClient = apiClient
    }

    // MARK: - ChatOpsTransport

    func sendTextMessage(chatID: String, text: String) async throws {
        // ⚠️ THE EGRESS FLOOR. Sanitised HERE rather than in the API client so it happens BEFORE
        // chunking — a credential split across two chunks matches no pattern in either half and
        // would walk straight through a client-side pass.
        try await apiClient.sendMessage(chatID: Int64(chatID)!, text: RemoteEgressSanitizer.credentialsOnly(text), parseMode: nil)
    }

    func sendChunkedMessage(chatID: String, text: String) async throws {
        // ⚠️ THE EGRESS FLOOR. Sanitised HERE rather than in the API client so it happens BEFORE
        // chunking — a credential split across two chunks matches no pattern in either half and
        // would walk straight through a client-side pass.
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
//
// In this file rather than beside the other two renderers because `apiClient` is `private`, and
// `private` in Swift is file-scoped.

extension TelegramTransport {

    nonisolated var capabilities: RemoteCapabilities { TelegramRemoteRenderer.capabilities }

    @discardableResult
    func render(_ view: RemoteView, to destination: RemoteDestination) async throws -> String? {
        // ⚠️ THE VIEW, NOT THE RENDERED TEXT. Slack puts the body in BLOCKS as well as the
        // fallback text, and every platform puts conversation titles on BUTTON LABELS — and a
        // title is auto-set to the user's first prompt. Cleaning `draft.text` would miss both.
        let view = view.sanitizedForEgress()
        let channel = destination.channel
        guard let draft = TelegramRemoteRenderer.draft(for: view) else {
            if case .silent(let silence) = view {
                RemoteRenderLog.silence(silence, channel: channel, logger: logger)
            }
            return nil
        }
        // ⚠️ Throws instead of `Int64(chatID)!`. The force-unwraps elsewhere in this file are safe
        // only because their sole producer builds the string from an `Int64`; new code does not
        // inherit that assumption.
        guard let chatID = Int64(channel.channelID) else {
            logger.error("[CHATOPS/RENDER] Telegram channel id \"\(channel.channelID)\" is not numeric, so the view was NOT posted. CONSEQUENCE: the remote user receives no reply at all and the command appears to have been ignored.")
            throw RemoteRenderError.unaddressableChannel(provider: .telegram, channelID: channel.channelID)
        }
        // ⚠️ `destination` is always a channel post: Telegram has no interaction-reply channel, so
        // `.interactionReply` degrades to the same call rather than failing.
        let message = try await apiClient.sendMessage(
            chatID: chatID,
            text: draft.text,
            parseMode: draft.parse_mode,
            // ⚠️ WAS `draft.reply_markup.map { .inline($0) }`. That literal re-wrap was the second
            // half of the barrier: even once the renderer could express a `ForceReply`, this line
            // would have forced it back into an inline keyboard. The draft now names its own kind.
            replyMarkup: draft.reply_markup
        )
        RemoteRenderLog.posted(view, channel: channel, logger: logger)
        return "\(message.message_id)"
    }
}
