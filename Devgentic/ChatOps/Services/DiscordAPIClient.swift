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
    private let logger = Logger(subsystem: "com.devgentic", category: "DiscordAPI")

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
        let chunks = DiscordAPIClient.chunkText(content, maxLength: 1950)
        for chunk in chunks {
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
        let commands: [DiscordSlashCommand] = [
            DiscordSlashCommand(name: "conversations", description: "List recent conversations", type: DiscordSlashCommand.chatInput),
            DiscordSlashCommand(name: "new", description: "Start a new conversation", type: DiscordSlashCommand.chatInput),
            DiscordSlashCommand(name: "status", description: "Show current agent status", type: DiscordSlashCommand.chatInput),
            DiscordSlashCommand(name: "cancel", description: "Stop the active agent", type: DiscordSlashCommand.chatInput),
            DiscordSlashCommand(name: "help", description: "Show available commands", type: DiscordSlashCommand.chatInput)
        ]

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

    /// Splits long text into chunks that respect Discord's 2000-char message limit.
    /// Tries to split on paragraph boundaries first, then falls back to hard splits.
    static func chunkText(_ text: String, maxLength: Int = 1950) -> [String] {
        guard text.count > maxLength else { return [text] }

        var chunks: [String] = []
        var remaining = text

        while !remaining.isEmpty {
            if remaining.count <= maxLength {
                chunks.append(remaining)
                break
            }

            let searchRange = remaining.prefix(maxLength)
            if let paragraphBreak = searchRange.range(of: "\n\n", options: .backwards) {
                let chunk = String(remaining[remaining.startIndex..<paragraphBreak.upperBound])
                chunks.append(chunk)
                remaining = String(remaining[paragraphBreak.upperBound...])
            } else if let lineBreak = searchRange.range(of: "\n", options: .backwards) {
                let chunk = String(remaining[remaining.startIndex..<lineBreak.upperBound])
                chunks.append(chunk)
                remaining = String(remaining[lineBreak.upperBound...])
            } else {
                let idx = remaining.index(remaining.startIndex, offsetBy: maxLength)
                chunks.append(String(remaining[remaining.startIndex..<idx]))
                remaining = String(remaining[idx...])
            }
        }

        return chunks
    }

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
}

// MARK: - Helper Types

private struct EmptyBody: Encodable {}

struct EmptyResponse: Decodable {}
