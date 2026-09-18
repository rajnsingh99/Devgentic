// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
//
//  SlackAPIClient.swift
//  Devgentic
//
//  Created by Raj Singh on 24/03/26.
//

import Foundation
import os

/// Low-level URLSession wrapper for the Slack Web API.
/// All methods are async/throws — no Combine, no external dependencies.
actor SlackAPIClient {

    private let botToken: String
    private let session: URLSession
    private let baseURL = "https://slack.com/api"
    private let logger = DGLogger(category: "SlackAPI")

    init(botToken: String) {
        self.botToken = botToken

        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 30
        config.timeoutIntervalForResource = 60
        self.session = URLSession(configuration: config)
    }

    // MARK: - Validation

    /// Validates the bot token by calling auth.test.
    func authTest() async throws -> SlackAuthTestResponse {
        let url = URL(string: "\(baseURL)/auth.test")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(botToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let (data, httpResponse) = try await session.data(for: request)
        try checkHTTPErrors(httpResponse: httpResponse, data: data, method: "auth.test")

        let response = try JSONDecoder().decode(SlackAuthTestResponse.self, from: data)
        guard response.ok else {
            throw SlackAPIError.apiError(method: "auth.test", error: response.error ?? "Unknown error")
        }
        return response
    }

    // MARK: - Sending Messages

    /// Sends a message to a channel. Returns the message ts (timestamp = message ID).
    @discardableResult
    func postMessage(
        channel: String,
        text: String,
        blocks: [SlackBlock]? = nil
    ) async throws -> (channel: String, ts: String) {
        let payload = SlackPostMessagePayload(channel: channel, text: text, blocks: blocks)
        let data = try await post(method: "chat.postMessage", payload: payload)
        let response = try JSONDecoder().decode(SlackAPIResponse<EmptyResponse>.self, from: data)

        guard response.ok, let ts = response.ts, let ch = response.channel else {
            throw SlackAPIError.apiError(method: "chat.postMessage", error: response.error ?? "Missing ts/channel")
        }
        return (channel: ch, ts: ts)
    }

    /// Sends multiple chunked messages for long responses.
    func sendChunkedMessage(channel: String, text: String) async throws {
        // ⚠️ 3000 is a `section` block's text limit — NOT `chat.postMessage`'s 40 000. Invariant 28
        // records why the tighter one binds. Measured in UTF-16 by `RemoteTextBudget.chunk`.
        let chunks = SlackAPIClient.chunkText(text, maxLength: 3000)
        try await RemoteChunkedSend.send(chunks) { chunk in
            try await postMessage(channel: channel, text: chunk)
        }
    }

    // MARK: - Message Editing

    /// Updates an existing message's text and/or blocks.
    func updateMessage(
        channel: String,
        ts: String,
        text: String,
        blocks: [SlackBlock]? = nil
    ) async throws {
        let payload = SlackUpdateMessagePayload(channel: channel, ts: ts, text: text, blocks: blocks)
        let data = try await post(method: "chat.update", payload: payload)
        let response = try JSONDecoder().decode(SlackAPIResponse<EmptyResponse>.self, from: data)

        guard response.ok else {
            throw SlackAPIError.apiError(method: "chat.update", error: response.error ?? "Unknown error")
        }
    }

    // MARK: - Socket Mode Connection

    /// Opens a Socket Mode connection. Requires an app-level token (xapp-).
    /// Returns the WebSocket URL to connect to.
    static func openConnection(appToken: String) async throws -> String {
        let url = URL(string: "https://slack.com/api/apps.connections.open")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(appToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")

        let session = URLSession.shared
        let (data, _) = try await session.data(for: request)
        let response = try JSONDecoder().decode(SlackConnectionOpenResponse.self, from: data)

        guard response.ok, let wsURL = response.url else {
            throw SlackAPIError.apiError(method: "apps.connections.open", error: response.error ?? "Missing URL")
        }
        return wsURL
    }

    // MARK: - Text Chunking

    // MARK: - Views

    /// Opens a modal against a live `trigger_id`.
    ///
    /// ⚠️ `trigger_id` EXPIRES IN ABOUT THREE SECONDS and cannot be reused. It arrives only on
    /// `block_actions` and `slash_commands` payloads — never on `events_api`, so a modal can never
    /// be opened in response to typed text on Slack, only from a button or a slash command.
    ///
    /// ⚠️ A REJECTED VIEW COMES BACK AS HTTP 200. Slack answers `ok: false` with an `error` string
    /// that names nothing useful ("invalid_arguments"), putting the real detail in
    /// `response_metadata.messages` — which this app used to discard. Both are logged here, because
    /// the user-visible symptom is a button that appears to do nothing at all.
    func openView(triggerID: String, view: SlackModalView) async throws {
        let payload = SlackViewsOpenPayload(trigger_id: triggerID, view: view)
        let data = try await post(method: "views.open", payload: payload)
        let response = try JSONDecoder().decode(SlackAPIResponse<EmptyResponse>.self, from: data)

        guard response.ok else {
            let detail = response.response_metadata?.messages?.joined(separator: "; ") ?? "no detail supplied"
            logger.error("[CHATOPS] Slack refused views.open: \(response.error ?? "unknown") — \(detail). CONSEQUENCE: the modal never opens, so the user taps the answer button and nothing happens; the run stays parked and the only route left is typing in the channel.")
            throw SlackAPIError.apiError(method: "views.open", error: response.error ?? "views.open failed")
        }
    }

    // MARK: - Private Helpers

    private func post<P: Encodable>(method: String, payload: P) async throws -> Data {
        let url = URL(string: "\(baseURL)/\(method)")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(botToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json; charset=utf-8", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(payload)

        let (data, httpResponse) = try await session.data(for: request)
        try checkHTTPErrors(httpResponse: httpResponse, data: data, method: method)
        return data
    }

    private func checkHTTPErrors(httpResponse: URLResponse, data: Data, method: String) throws {
        guard let http = httpResponse as? HTTPURLResponse else { return }

        if http.statusCode == 429 {
            let retryAfter = Double(http.value(forHTTPHeaderField: "Retry-After") ?? "5") ?? 5.0
            logger.warning("Slack rate limited (429) on \(method). Retry after \(retryAfter)s.")
            throw SlackAPIError.rateLimited(retryAfter: retryAfter)
        }

        if http.statusCode == 401 {
            throw SlackAPIError.invalidToken
        }

        guard (200...299).contains(http.statusCode) else {
            let errorBody = String(data: data, encoding: .utf8) ?? "Unknown error"
            throw SlackAPIError.apiError(method: method, error: "HTTP \(http.statusCode): \(errorBody)")
        }
    }

    /// Splits text to this platform's message budget.
    ///
    /// ⚠️ A FORWARDER, NOT AN IMPLEMENTATION. The real one is `RemoteTextBudget.chunk`, shared by all
    /// three clients — see its header for the UTF-16 unit bug that three separate copies of this
    /// function each carried. It stays as a named entry point so this client's own tests exercise
    /// the same call production takes, rather than the shared helper in isolation.
    static func chunkText(_ text: String, maxLength: Int = 3000) -> [String] {
        RemoteTextBudget.chunk(text, limit: maxLength)
    }

}

// MARK: - Rate-limit reporting

extension SlackAPIError: RemoteRateLimitedError {
    /// ⚠️ Same story as Discord: parsed from `Retry-After`, previously read only by
    /// `errorDescription`.
    var retryAfterSeconds: TimeInterval? {
        guard case .rateLimited(let retryAfter) = self else { return nil }
        return retryAfter
    }
}
