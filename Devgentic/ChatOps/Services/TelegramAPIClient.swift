// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
//
//  TelegramAPIClient.swift
//  Devgentic
//
//  Created by Raj Singh.
//

import Foundation
import os

/// Low-level URLSession wrapper for the Telegram Bot API.
/// All methods are async/throws — no Combine, no external dependencies.
actor TelegramAPIClient {

    private let botToken: String
    private let session: URLSession
    private let baseURL: String
    private let logger = DGLogger(category: "TelegramAPI")

    init(botToken: String) {
        self.botToken = botToken
        self.baseURL = "https://api.telegram.org/bot\(botToken)"

        let config = URLSessionConfiguration.default
        // Slightly above Telegram's 60s long-poll hold to avoid client-side timeouts.
        config.timeoutIntervalForRequest = 65
        config.timeoutIntervalForResource = 70
        self.session = URLSession(configuration: config)
    }

    // MARK: - Polling

    /// Long-polls for new updates from Telegram; the array is empty if the timeout expires with no messages.
    /// - Parameter offset: the update ID to start from (previous + 1 acknowledges earlier updates).
    /// - Parameter timeout: server-side long-poll timeout in seconds (max 60).
    func getUpdates(offset: Int, timeout: Int = 60) async throws -> [TelegramUpdate] {
        var components = URLComponents(string: "\(baseURL)/getUpdates")!
        components.queryItems = [
            URLQueryItem(name: "offset", value: "\(offset)"),
            URLQueryItem(name: "timeout", value: "\(timeout)"),
            URLQueryItem(name: "allowed_updates", value: "[\"message\",\"callback_query\"]")
        ]

        let (data, _) = try await session.data(from: components.url!)
        let response = try JSONDecoder().decode(TelegramResponse<[TelegramUpdate]>.self, from: data)

        guard response.ok, let updates = response.result else {
            throw TelegramAPIError.apiError(
                code: response.error_code ?? -1,
                description: response.description ?? "Unknown error"
            )
        }
        return updates
    }

    // MARK: - Sending Messages

    /// Sends a text message to a chat. Optionally includes reply markup (inline or reply keyboard).
    @discardableResult
    func sendMessage(
        chatID: Int64,
        text: String,
        parseMode: String? = "Markdown",
        replyMarkup: SendMessagePayload.ReplyMarkup? = nil
    ) async throws -> TelegramMessage {
        let payload = SendMessagePayload(
            chat_id: chatID,
            text: text,
            parse_mode: parseMode,
            reply_markup: replyMarkup
        )
        return try await post(endpoint: "sendMessage", payload: payload)
    }

    /// Sends multiple chunked messages for long responses (Telegram's 4096-char limit).
    func sendChunkedMessage(
        chatID: Int64,
        text: String,
        parseMode: String? = "Markdown"
    ) async throws {
        // 4000 rather than Telegram's 4096: Markdown escaping adds a backslash per metacharacter after this budget is
        // applied, so the margin absorbs it. Measured in UTF-16 by `RemoteTextBudget.chunk`.
        let chunks = TelegramAPIClient.chunkText(text, maxLength: 4000)
        try await RemoteChunkedSend.send(chunks) { chunk in
            try await sendMessage(chatID: chatID, text: chunk, parseMode: parseMode)
        }
    }

    // MARK: - Chat Actions

    /// Sends a "typing..." indicator to the chat.
    func sendTypingAction(chatID: Int64) async throws {
        struct Payload: Encodable {
            let chat_id: Int64
            let action: String
        }
        let _: Bool = try await post(
            endpoint: "sendChatAction",
            payload: Payload(chat_id: chatID, action: TelegramChatAction.typing.rawValue)
        )
    }

    // MARK: - Callback Queries

    /// Acknowledges a callback query (removes the "loading" spinner on the inline button).
    func answerCallbackQuery(id: String, text: String? = nil) async throws {
        struct Payload: Encodable {
            let callback_query_id: String
            let text: String?
        }
        let _: Bool = try await post(
            endpoint: "answerCallbackQuery",
            payload: Payload(callback_query_id: id, text: text)
        )
    }

    // MARK: - Message Editing

    /// Edits the text of an existing message. Used for updating HITL prompts after resolution.
    @discardableResult
    func editMessageText(
        chatID: Int64,
        messageID: Int,
        text: String,
        parseMode: String? = nil,
        replyMarkup: SendMessagePayload.ReplyMarkup? = nil
    ) async throws -> TelegramMessage {
        let payload = EditMessageTextPayload(
            chat_id: chatID,
            message_id: messageID,
            text: text,
            parse_mode: parseMode,
            reply_markup: replyMarkup
        )
        return try await post(endpoint: "editMessageText", payload: payload)
    }

    // MARK: - Bot Commands

    /// Registers the bot's command menu (the ☰ button next to the text input).
    func setMyCommands(_ commands: [BotCommand]) async throws {
        struct Payload: Encodable {
            let commands: [BotCommand]
        }
        let _: Bool = try await post(
            endpoint: "setMyCommands",
            payload: Payload(commands: commands)
        )
    }

    // MARK: - Validation

    /// Validates the bot token by calling `getMe`. Returns the bot's user info.
    func getMe() async throws -> TelegramUser {
        let url = URL(string: "\(baseURL)/getMe")!
        let (data, _) = try await session.data(from: url)
        let response = try JSONDecoder().decode(TelegramResponse<TelegramUser>.self, from: data)

        guard response.ok, let user = response.result else {
            throw TelegramAPIError.apiError(
                code: response.error_code ?? -1,
                description: response.description ?? "Invalid bot token"
            )
        }
        return user
    }

    // MARK: - Private Helpers

    private func post<P: Encodable, R: Decodable>(endpoint: String, payload: P) async throws -> R {
        let url = URL(string: "\(baseURL)/\(endpoint)")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(payload)

        let (data, httpResponse) = try await session.data(for: request)

        if let http = httpResponse as? HTTPURLResponse, http.statusCode == 429 {
            // Telegram sends the retry delay in `parameters.retry_after`, not in a header; keep it so the retry can honor it.
            let retryAfter = (try? JSONDecoder().decode(TelegramErrorEnvelope.self, from: data))?
                .parameters?.retry_after
            logger.warning("Telegram rate limited (429); retry_after=\(retryAfter.map(String.init) ?? "absent").")
            throw TelegramAPIError.rateLimited(retryAfter: retryAfter.map(TimeInterval.init))
        }

        let decoded = try JSONDecoder().decode(TelegramResponse<R>.self, from: data)

        guard decoded.ok, let result = decoded.result else {
            throw TelegramAPIError.apiError(
                code: decoded.error_code ?? -1,
                description: decoded.description ?? "Unknown API error"
            )
        }
        return result
    }

    // MARK: - Text Chunking

    /// Splits text to this platform's message budget by forwarding to the shared `RemoteTextBudget.chunk`.
    /// Kept as a named entry point so this client's tests exercise the same call production takes.
    static func chunkText(_ text: String, maxLength: Int = 4000) -> [String] {
        RemoteTextBudget.chunk(text, limit: maxLength)
    }
}

// MARK: - Errors

enum TelegramAPIError: LocalizedError {
    case apiError(code: Int, description: String)
    case rateLimited(retryAfter: TimeInterval?)
    case invalidToken

    var errorDescription: String? {
        switch self {
        case .apiError(let code, let desc):
            return "Telegram API error (\(code)): \(desc)"
        case .rateLimited(let retryAfter):
            if let retryAfter {
                return "Telegram rate limited — retry after \(Int(retryAfter))s"
            }
            return "Telegram rate limited — try again later"
        case .invalidToken:
            return "Invalid bot token"
        }
    }


}


// MARK: - Rate-limit reporting

extension TelegramAPIError: RemoteRateLimitedError {
    /// The wait Telegram reports in `parameters.retry_after` (seconds), not in a header; a 429 with no number
    /// still has a value. Nil means "not a rate limit at all"; `RemoteChunkedSend` relies on that to decide if a retry helps.
    var retryAfterSeconds: TimeInterval? {
        guard case .rateLimited(let retryAfter) = self else { return nil }
        return retryAfter ?? 1
    }
}

/// The error shape Telegram returns alongside a 429.
private struct TelegramErrorEnvelope: Decodable {
    struct Parameters: Decodable { let retry_after: Int? }
    let parameters: Parameters?
}
