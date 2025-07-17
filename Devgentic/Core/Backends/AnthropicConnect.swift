//
//  AnthropicConnect.swift
//  Devgentic
//
//  Created by Raj Singh.
//

import Foundation
import os

private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "com.devgentic.app", category: "AnthropicConnectService")

/// Service responsible for communicating with the Anthropic API.
class AnthropicConnect {

    private let apiKey: String
    private let urlSession: URLSession

    init(apiKey: String) {
        self.apiKey = apiKey
        self.urlSession = URLSession.shared
        logger.info("AnthropicConnectService initialized.")
    }

    /// Establishes a streaming connection to the Anthropic Messages API.
    func streamMessage(
        userQuery: String,
        history: [ChatMessage],
        modelName: String,
        context: TraceContext // <-- Add context parameter
    ) -> AsyncThrowingStream<String, Error> {
        return AsyncThrowingStream { continuation in
            let task = Task {
                let apiContext = context.newSpan()
                logger.info("API Call Start: Anthropic. traceID: \(apiContext.traceID), spanID: \(apiContext.spanID)")
                
                let apiStartTime = Date()
                var firstTokenTime: Date? = nil

                do {
                    guard let url = URL(string: "https://api.anthropic.com/v1/messages") else {
                        throw NSError(domain: "Anthropic.URL", code: 0, userInfo: [NSLocalizedDescriptionKey: "Invalid Anthropic API URL"])
                    }
                    
                    var request = URLRequest(url: url)
                    request.httpMethod = "POST"
                    request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
                    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
                    request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
                    request.setValue("true", forHTTPHeaderField: "anthropic-beta") // Required for streaming
                    
                    let apiMessages = history.map { AnthropicMessage(from: $0) } + [AnthropicMessage(role: "user", content: userQuery)]
                    let requestBody = AnthropicStreamRequest(model: modelName, messages: apiMessages, stream: true, max_tokens: 4096)
                    request.httpBody = try JSONEncoder().encode(requestBody)

                    let (bytes, response) = try await self.urlSession.bytes(for: request)
                    
                    guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
                        throw NSError(domain: "Anthropic.APIError", code: (response as? HTTPURLResponse)?.statusCode ?? -1, userInfo: [NSLocalizedDescriptionKey: "Anthropic API Error"])
                    }

                    var eventName: String?
                    var isFirstToken = true
                    for try await line in bytes.lines {
                        if line.hasPrefix("event: ") {
                            eventName = String(line.dropFirst(7))
                        } else if line.hasPrefix("data: ") {
                            if isFirstToken {
                                firstTokenTime = Date()
                                isFirstToken = false
                            }
                            let jsonString = String(line.dropFirst(6))
                            if eventName == "content_block_delta" {
                                if let data = jsonString.data(using: .utf8),
                                   let chunk = try? JSONDecoder().decode(AnthropicStreamChunk.self, from: data),
                                   chunk.type == "content_block_delta" {
                                    continuation.yield(chunk.delta.text)
                                }
                            } else if eventName == "message_stop" {
                                break // Exit loop
                            }
                        } else {
                            eventName = nil
                        }
                    }
                    
                    // --- Metrics Recording ---
                    let apiEndTime = Date()
                    if let firstTokenTime = firstTokenTime {
                        let ttftDuration = firstTokenTime.timeIntervalSince(apiStartTime)
                        await MetricsManager.shared.record(duration: ttftDuration, for: "time_to_first_token", context: apiContext, provider: .anthropic)
                    }
                    let totalDuration = apiEndTime.timeIntervalSince(apiStartTime)
                    await MetricsManager.shared.record(duration: totalDuration, for: "api_call_duration", context: apiContext, provider: .anthropic)
                    logger.info("API Call Finished: Anthropic. traceID: \(apiContext.traceID), spanID: \(apiContext.spanID)")
                    // --- End Metrics ---
                    
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { @Sendable _ in
                task.cancel()
            }
        }
    }

    /// Sends a user's query to the Anthropic API (non-streaming).
    func sendMessage(
        conversationID: UUID,
        userQuery: String,
        history: [ChatMessage],
        modelName: String
    ) async throws -> ([ChatMessage], Error?) {

        guard let url = URL(string: "https://api.anthropic.com/v1/messages") else {
            throw NSError(domain: "AnthropicConnectService.URL", code: 0, userInfo: [NSLocalizedDescriptionKey: "Invalid Anthropic API URL."])
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")

        var apiMessages = history.compactMap { message -> AnthropicRequest.Message? in
            let role = message.sender == .user ? "user" : "assistant"
            guard let contentText = message.content.textContent else { return nil }
            return AnthropicRequest.Message(role: role, content: contentText)
        }
        
        apiMessages.append(AnthropicRequest.Message(role: "user", content: userQuery))

        let requestBody = AnthropicRequest(
            model: modelName,
            max_tokens: 4096,
            messages: apiMessages
        )

        request.httpBody = try JSONEncoder().encode(requestBody)
        
        let (data, response) = try await urlSession.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
            let statusCode = (response as? HTTPURLResponse)?.statusCode ?? -1
            let errorResponse = String(data: data, encoding: .utf8) ?? "Unable to decode error response."
            let errorContent = MessageContent.error(title: "Anthropic API Error", details: "API Error (Code: \(statusCode)): \(errorResponse)")
            return ([ChatMessage(conversationId: conversationID, sender: .agent, content: errorContent)], nil)
        }

        let anthropicResponse = try JSONDecoder().decode(AnthropicResponse.self, from: data)
        
        if let responseText = anthropicResponse.content.first(where: { $0.type == "text" })?.text {
            let agentMessage = ChatMessage(conversationId: conversationID, sender: .agent, content: .markdownText(responseText))
            return ([agentMessage], nil)
        } else {
            let errorText = "Could not find valid text in the Anthropic API response."
            let errorContent = MessageContent.error(title: "Invalid Response Structure", details: errorText)
            return ([ChatMessage(conversationId: conversationID, sender: .agent, content: errorContent)], nil)
        }
    }
}

// MARK: - Codable Structs for Anthropic API

// Non-streaming
private struct AnthropicRequest: Codable {
    let model: String
    let max_tokens: Int
    let messages: [Message]
    struct Message: Codable { let role: String; let content: String }
}

private struct AnthropicResponse: Codable {
    let content: [ContentBlock]
    struct ContentBlock: Codable { let type: String; let text: String? }
}

// Streaming
private struct AnthropicStreamRequest: Codable { let model: String; let messages: [AnthropicMessage]; let stream: Bool; let max_tokens: Int }
private struct AnthropicMessage: Codable { let role: String; let content: String; init(role: String, content: String) { self.role = role; self.content = content }; init(from message: ChatMessage) { self.role = message.sender.rawValue == "agent" ? "assistant" : "user"; self.content = message.content.textContent ?? "" } }
private struct AnthropicStreamChunk: Decodable { let type: String; let delta: Delta; struct Delta: Decodable { let text: String } }
