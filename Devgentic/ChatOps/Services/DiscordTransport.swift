// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
//
//  DiscordTransport.swift
//  Devgentic
//
//  Created by Raj Singh.
//

import Foundation
import os

/// Adapts `DiscordAPIClient` to the `ChatOpsTransport` protocol.
/// A thin wrapper: all HTTP logic stays in `DiscordAPIClient`.
/// Agent responses go out as plain text (no markdown) to avoid formatting issues with code-heavy content.
final class DiscordTransport: ChatOpsTransport, @unchecked Sendable {

    let transportID = "discord"

    private let apiClient: DiscordAPIClient
    private let logger = DGLogger(category: "DiscordTransport")

    init(apiClient: DiscordAPIClient) {
        self.apiClient = apiClient
    }

    // MARK: - ChatOpsTransport

    func sendTextMessage(chatID: String, text: String) async throws {
        // Sanitised here rather than in the API client so it runs before chunking: a credential split
        // across two chunks matches no pattern in either half.
        try await apiClient.sendMessage(channelID: chatID, content: RemoteEgressSanitizer.credentialsOnly(text))
    }

    func sendChunkedMessage(chatID: String, text: String) async throws {
        // Sanitised here rather than in the API client so it runs before chunking: a credential split
        // across two chunks matches no pattern in either half.
        try await apiClient.sendChunkedMessage(channelID: chatID, content: RemoteEgressSanitizer.credentialsOnly(text))
    }

    func editMessage(chatID: String, messageID: String, newText: String) async throws {
        let newText = RemoteEgressSanitizer.credentialsOnly(newText)
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

// MARK: - Remote view rendering (C3)

extension DiscordTransport {

    nonisolated var capabilities: RemoteCapabilities { DiscordRemoteRenderer.capabilities }

    /// Renders `view` to `destination`, posting the same draft whether it is a channel or an interaction reply.
    @discardableResult
    func render(_ view: RemoteView, to destination: RemoteDestination) async throws -> String? {
        // Sanitises the view, not the rendered text: Slack puts bodies in blocks and every platform puts
        // conversation titles on button labels, so cleaning `draft.text` alone would miss both.
        let view = view.sanitizedForEgress()
        let channel = destination.channel
        guard let draft = DiscordRemoteRenderer.draft(for: view) else {
            if case .silent(let silence) = view {
                RemoteRenderLog.silence(silence, channel: channel, logger: logger)
            }
            return nil
        }

        if case .interactionReply(_, let interactionToken) = destination {
            // The application id is learned from the READY payload each session and is nil until then;
            // the channel-post fallback keeps the reply from leaving Discord's "thinking…" placeholder hanging.
            if let applicationID = await apiClient.applicationID {
                try await apiClient.editInteractionResponse(
                    applicationID: applicationID,
                    interactionToken: interactionToken,
                    content: draft.content,
                    components: draft.components
                )
                RemoteRenderLog.posted(view, channel: channel, logger: logger)
                // nil, not an id: an interaction edit has no new message to address later.
                // A HITL prompt is never rendered to this destination, so nothing needs the id.
                return nil
            }
            logger.error("[CHATOPS/RENDER] Discord interaction reply requested before READY supplied an application id — falling back to a channel post. CONSEQUENCE: the reply still reaches the user, but the deferred \"thinking…\" placeholder on the original interaction is never resolved and stays visible.")
        }

        let message = try await apiClient.sendMessage(
            channelID: channel.channelID,
            content: draft.content,
            components: draft.components
        )
        RemoteRenderLog.posted(view, channel: channel, logger: logger)
        return message.id
    }
}
