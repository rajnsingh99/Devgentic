// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2026 Raj Singh
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
    private let logger = DGLogger(category: "DiscordTransport")

    init(apiClient: DiscordAPIClient) {
        self.apiClient = apiClient
    }

    // MARK: - ChatOpsTransport

    func sendTextMessage(chatID: String, text: String) async throws {
        // ⚠️ THE EGRESS FLOOR. Sanitised HERE rather than in the API client so it happens BEFORE
        // chunking — a credential split across two chunks matches no pattern in either half and
        // would walk straight through a client-side pass.
        try await apiClient.sendMessage(channelID: chatID, content: RemoteEgressSanitizer.credentialsOnly(text))
    }

    func sendChunkedMessage(chatID: String, text: String) async throws {
        // ⚠️ THE EGRESS FLOOR. Sanitised HERE rather than in the API client so it happens BEFORE
        // chunking — a credential split across two chunks matches no pattern in either half and
        // would walk straight through a client-side pass.
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

    /// ⚠️ THIS IS THE METHOD THAT ENDS THE `/conversations` DIVERGENCE. Discord renders that command
    /// two ways today — a button grid when it arrives as a channel message, a numbered plain-text
    /// list when it arrives as a slash command — because "reply into the interaction" was built as a
    /// second code path that re-derives its own text. Here the interaction reply is a DESTINATION:
    /// the same rendered draft goes to a different address.
    @discardableResult
    func render(_ view: RemoteView, to destination: RemoteDestination) async throws -> String? {
        // ⚠️ THE VIEW, NOT THE RENDERED TEXT. Slack puts the body in BLOCKS as well as the
        // fallback text, and every platform puts conversation titles on BUTTON LABELS — and a
        // title is auto-set to the user's first prompt. Cleaning `draft.text` would miss both.
        let view = view.sanitizedForEgress()
        let channel = destination.channel
        guard let draft = DiscordRemoteRenderer.draft(for: view) else {
            if case .silent(let silence) = view {
                RemoteRenderLog.silence(silence, channel: channel, logger: logger)
            }
            return nil
        }

        if case .interactionReply(_, let interactionToken) = destination {
            // The application id is learned from the READY payload each session and is nil until
            // then; falling back to a channel post keeps the reply reaching the user rather than
            // leaving Discord's "thinking…" placeholder hanging forever.
            if let applicationID = await apiClient.applicationID {
                try await apiClient.editInteractionResponse(
                    applicationID: applicationID,
                    interactionToken: interactionToken,
                    content: draft.content,
                    components: draft.components
                )
                RemoteRenderLog.posted(view, channel: channel, logger: logger)
                // ⚠️ nil, not an id: an interaction EDIT has no new message to address later. A HITL
                // prompt is never rendered to this destination — the mirror always posts to a
                // channel — so nothing needs the id here.
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
