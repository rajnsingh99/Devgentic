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
    private let logger = Logger(subsystem: DGLogger.subsystem, category: "SlackAPI")

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
        let chunks = SlackAPIClient.chunkText(text, maxLength: 3000)
        for chunk in chunks {
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

    /// Splits long text into chunks. Slack allows 40K chars but we keep chunks reasonable.
    static func chunkText(_ text: String, maxLength: Int = 3000) -> [String] {
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
}
