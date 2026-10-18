// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
//
//  SlackTransport.swift
//  Devgentic
//
//  Created by Raj Singh.
//

import Foundation
import os

/// Adapts `SlackAPIClient` to the `ChatOpsTransport` protocol.
/// Uses Block Kit for interactive HITL prompts and plain text for agent responses.
/// Slack has no bot typing indicator, so `sendTypingIndicator` is a no-op.
final class SlackTransport: ChatOpsTransport, @unchecked Sendable {

    let transportID = "slack"

    private let apiClient: SlackAPIClient
    private let logger = DGLogger(category: "SlackTransport")

    init(apiClient: SlackAPIClient) {
        self.apiClient = apiClient
    }

    // MARK: - ChatOpsTransport

    func sendTextMessage(chatID: String, text: String) async throws {
        // Why: a credential split across two chunks matches no pattern in either half
        // Credentials are redacted here, before chunking, not in the API client.
        try await apiClient.postMessage(channel: chatID, text: RemoteEgressSanitizer.credentialsOnly(text))
    }

    func sendChunkedMessage(chatID: String, text: String) async throws {
        // Why: a credential split across two chunks matches no pattern in either half
        // Credentials are redacted here, before chunking, not in the API client.
        try await apiClient.sendChunkedMessage(channel: chatID, text: RemoteEgressSanitizer.credentialsOnly(text))
    }

    func editMessage(chatID: String, messageID: String, newText: String) async throws {
        let newText = RemoteEgressSanitizer.credentialsOnly(newText)
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

// MARK: - Remote view rendering (C3)

extension SlackTransport {

    nonisolated var capabilities: RemoteCapabilities { SlackRemoteRenderer.capabilities }

    @discardableResult
    func render(_ view: RemoteView, to destination: RemoteDestination) async throws -> String? {
        // Sanitise the view, not the rendered text: Slack puts the body in blocks, and button labels carry conversation titles.
        let view = view.sanitizedForEgress()
        let channel = destination.channel
        guard let draft = SlackRemoteRenderer.draft(for: view) else {
            if case .silent(let silence) = view {
                RemoteRenderLog.silence(silence, channel: channel, logger: logger)
            }
            return nil
        }
        // `.interactionReply` degrades to a channel post; the decoded `response_url` is not used.
        let result = try await apiClient.postMessage(
            channel: channel.channelID,
            text: draft.text,
            blocks: draft.blocks
        )
        RemoteRenderLog.posted(view, channel: channel, logger: logger)
        return result.ts
    }
}
