// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2026 Raj Singh
//
//  DiscordAPIClient.swift
//  Devgentic
//
//  Created by Raj Singh on 24/03/26.
//

import Foundation
import os

/// Low-level URLSession wrapper for the Discord REST API (v10).
/// All methods are async/throws — no Combine, no external dependencies.
actor DiscordAPIClient {

    private let botToken: String
    private let session: URLSession
    private let baseURL = "https://discord.com/api/v10"
    private let logger = DGLogger(category: "DiscordAPI")

    /// Application ID — set after READY event provides it.
    var applicationID: String?

    init(botToken: String) {
        self.botToken = botToken

        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 30
        config.timeoutIntervalForResource = 60
        self.session = URLSession(configuration: config)
    }

    // MARK: - Validation

    /// Validates the bot token by calling GET /users/@me.
    func getCurrentUser() async throws -> DiscordUser {
        return try await request(method: "GET", path: "/users/@me")
    }

    // MARK: - Sending Messages

    /// Sends a text message to a channel. Optionally includes button components.
    @discardableResult
    func sendMessage(
        channelID: String,
        content: String,
        components: [DiscordComponent]? = nil
    ) async throws -> DiscordMessage {
        let payload = DiscordCreateMessagePayload(content: content, components: components)
        return try await request(method: "POST", path: "/channels/\(channelID)/messages", body: payload)
    }

    /// Sends multiple chunked messages for long responses (Discord's 2000-char limit).
    func sendChunkedMessage(channelID: String, content: String) async throws {
        // ⚠️ 1950 rather than Discord's 2000 — margin for the markdown escaping applied after this
        // budget. Measured in UTF-16 by `RemoteTextBudget.chunk`; see its header.
        let chunks = DiscordAPIClient.chunkText(content, maxLength: 1950)
        try await RemoteChunkedSend.send(chunks) { chunk in
            try await sendMessage(channelID: channelID, content: chunk)
        }
    }

    // MARK: - Message Editing

    /// Edits an existing message's text and/or components.
    @discardableResult
    func editMessage(
        channelID: String,
        messageID: String,
        content: String,
        components: [DiscordComponent]? = nil
    ) async throws -> DiscordMessage {
        let payload = DiscordEditMessagePayload(content: content, components: components)
        return try await request(method: "PATCH", path: "/channels/\(channelID)/messages/\(messageID)", body: payload)
    }

    // MARK: - Typing Indicator

    /// Shows a typing indicator in the channel (lasts ~10 seconds or until a message is sent).
    func sendTypingIndicator(channelID: String) async throws {
        let _: EmptyResponse = try await request(method: "POST", path: "/channels/\(channelID)/typing")
    }

    // MARK: - Interactions

    /// Responds to an interaction (button click or slash command).
    func respondToInteraction(
        interactionID: String,
        interactionToken: String,
        type: Int,
        data: DiscordInteractionCallbackData? = nil
    ) async throws {
        let payload = DiscordInteractionResponsePayload(type: type, data: data)
        // Interaction callbacks use a different base URL pattern — no auth header needed.
        let url = URL(string: "\(baseURL)/interactions/\(interactionID)/\(interactionToken)/callback")!
        var urlRequest = URLRequest(url: url)
        urlRequest.httpMethod = "POST"
        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        urlRequest.httpBody = try JSONEncoder().encode(payload)

        let (data, httpResponse) = try await session.data(for: urlRequest)
        if let http = httpResponse as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
            let errorBody = String(data: data, encoding: .utf8) ?? "Unknown error"
            throw DiscordAPIError.apiError(status: http.statusCode, message: errorBody)
        }
    }

    /// Edits the original interaction response (followup after deferred).
    func editInteractionResponse(
        applicationID: String,
        interactionToken: String,
        content: String,
        components: [DiscordComponent]? = nil
    ) async throws {
        let payload = DiscordEditMessagePayload(content: content, components: components)
        let _: DiscordMessage = try await request(
            method: "PATCH",
            path: "/webhooks/\(applicationID)/\(interactionToken)/messages/@original",
            body: payload
        )
    }

    // MARK: - Slash Commands

    /// Registers slash commands for a specific guild.
    func registerSlashCommands(applicationID: String, guildID: String) async throws {
        // ⚠️ DERIVED FROM `ChatOpsVerbTable`, not a hand-written list. This was five literals
        // against a table that had grown to eight verbs, so `/profiles` was registered nowhere and
        // could only be reached by typing it as a message — a shipped command invisible in the very
        // menu Discord users browse.
        //
        // ⚠️ ARGUMENT-TAKING VERBS ARE DELIBERATELY EXCLUDED. `DiscordSlashCommand` has no `options`
        // field to declare a parameter and `DiscordInteractionData` has none to read one, so a
        // registered `/use` or `/search` would arrive with its argument missing and answer with a
        // usage hint every time — worse than not offering it. They stay reachable by typing
        // `/search foo` as an ordinary message, which does carry the argument.
        let commands: [DiscordSlashCommand] = ChatOpsVerb.presentationOrder
            .filter { !$0.takesArgument }
            .map { verb in
                DiscordSlashCommand(
                    name: verb.canonicalName,
                    description: verb.helpDescription,
                    type: DiscordSlashCommand.chatInput
                )
            }

        let url = URL(string: "\(baseURL)/applications/\(applicationID)/guilds/\(guildID)/commands")!
        var urlRequest = URLRequest(url: url)
        urlRequest.httpMethod = "PUT"
        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        urlRequest.setValue("Bot \(botToken)", forHTTPHeaderField: "Authorization")
        urlRequest.httpBody = try JSONEncoder().encode(commands)

        let (data, httpResponse) = try await session.data(for: urlRequest)
        if let http = httpResponse as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
            let errorBody = String(data: data, encoding: .utf8) ?? "Unknown error"
            logger.error("Failed to register slash commands: \(errorBody)")
            throw DiscordAPIError.apiError(status: http.statusCode, message: errorBody)
        }

        logger.info("Registered \(commands.count) slash commands for guild \(guildID).")
    }

    // MARK: - Text Chunking

    // MARK: - Private Helpers

    private func request<R: Decodable>(method: String, path: String) async throws -> R {
        return try await request(method: method, path: path, body: Optional<EmptyBody>.none)
    }

    private func request<P: Encodable, R: Decodable>(method: String, path: String, body: P? = nil) async throws -> R {
        let url = URL(string: "\(baseURL)\(path)")!
        var urlRequest = URLRequest(url: url)
        urlRequest.httpMethod = method
        urlRequest.setValue("Bot \(botToken)", forHTTPHeaderField: "Authorization")

        if let body = body {
            urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
            urlRequest.httpBody = try JSONEncoder().encode(body)
        }

        let (data, httpResponse) = try await session.data(for: urlRequest)

        guard let http = httpResponse as? HTTPURLResponse else {
            throw DiscordAPIError.apiError(status: -1, message: "Invalid response")
        }

        // Rate limited
        if http.statusCode == 429 {
            let retryAfter = Double(http.value(forHTTPHeaderField: "Retry-After") ?? "5") ?? 5.0
            logger.warning("Discord rate limited (429). Retry after \(retryAfter)s.")
            throw DiscordAPIError.rateLimited(retryAfter: retryAfter)
        }

        // Unauthorized
        if http.statusCode == 401 {
            throw DiscordAPIError.invalidToken
        }

        // Other errors
        guard (200...299).contains(http.statusCode) else {
            let errorBody = String(data: data, encoding: .utf8) ?? "Unknown error"
            throw DiscordAPIError.apiError(status: http.statusCode, message: errorBody)
        }

        // Handle empty responses (204 No Content, or empty body for typing indicator)
        if data.isEmpty || http.statusCode == 204 {
            if R.self == EmptyResponse.self {
                return EmptyResponse() as! R
            }
        }

        return try JSONDecoder().decode(R.self, from: data)
    }

    /// Splits text to this platform's message budget.
    ///
    /// ⚠️ A FORWARDER, NOT AN IMPLEMENTATION. The real one is `RemoteTextBudget.chunk`, shared by all
    /// three clients — see its header for the UTF-16 unit bug that three separate copies of this
    /// function each carried. It stays as a named entry point so this client's own tests exercise
    /// the same call production takes, rather than the shared helper in isolation.
    static func chunkText(_ text: String, maxLength: Int = 1950) -> [String] {
        RemoteTextBudget.chunk(text, limit: maxLength)
    }

}

// MARK: - Helper Types

private struct EmptyBody: Encodable {}

struct EmptyResponse: Decodable {}

// MARK: - Rate-limit reporting

extension DiscordAPIError: RemoteRateLimitedError {
    /// ⚠️ `retryAfter` was parsed from the `Retry-After` header and then read by nothing but
    /// `errorDescription`. This is the reader that makes it do something.
    var retryAfterSeconds: TimeInterval? {
        guard case .rateLimited(let retryAfter) = self else { return nil }
        return retryAfter
    }
}
