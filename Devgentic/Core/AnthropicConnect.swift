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

    /// Sends a user's query to the Anthropic API.
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

        // Construct the message list from history
        var apiMessages = history.compactMap { message -> AnthropicRequest.Message? in
            let role = message.sender == .user ? "user" : "assistant"
            guard let contentText = message.content.textContent else { return nil }
            return AnthropicRequest.Message(role: role, content: contentText)
        }
        
        // Add the current user query as the last message
        apiMessages.append(AnthropicRequest.Message(role: "user", content: userQuery))

        // Construct the request body
        let requestBody = AnthropicRequest(
            model: modelName,
            max_tokens: 4096, // A reasonable default, can be made configurable
            messages: apiMessages
        )

        do {
            request.httpBody = try JSONEncoder().encode(requestBody)
        } catch {
            logger.error("Failed to encode Anthropic request body: \(error.localizedDescription)")
            throw error
        }

        logger.debug("Sending request to Anthropic API with model: \(modelName) and \(apiMessages.count) messages.")
        
        let (data, response) = try await urlSession.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
            let statusCode = (response as? HTTPURLResponse)?.statusCode ?? -1
            let errorResponse = String(data: data, encoding: .utf8) ?? "Unable to decode error response."
            logger.error("Anthropic API returned a non-200 status code: \(statusCode). Response: \(errorResponse)")
            let errorContent = MessageContent.error(title: "Anthropic API Error", details: "API Error (Code: \(statusCode)): \(errorResponse)")
            return ([ChatMessage(conversationId: conversationID, sender: .agent, content: errorContent)], nil)
        }

        do {
            let anthropicResponse = try JSONDecoder().decode(AnthropicResponse.self, from: data)
            
            if let responseText = anthropicResponse.content.first(where: { $0.type == "text" })?.text {
                let agentMessage = ChatMessage(conversationId: conversationID, sender: .agent, content: .markdownText(responseText))
                logger.info("Successfully received and parsed response from Anthropic.")
                return ([agentMessage], nil)
            } else {
                let errorText = "Could not find valid text in the Anthropic API response."
                logger.error("\(errorText) Response dump: \(String(data: data, encoding: .utf8) ?? "nil")")
                let errorContent = MessageContent.error(title: "Invalid Response Structure", details: errorText)
                return ([ChatMessage(conversationId: conversationID, sender: .agent, content: errorContent)], nil)
            }

        } catch {
            logger.error("Failed to decode Anthropic JSON response: \(error.localizedDescription)")
            throw error
        }
    }
}

// MARK: - Codable Structs for Anthropic API

private struct AnthropicRequest: Codable {
    let model: String
    let max_tokens: Int
    let messages: [Message]

    struct Message: Codable {
        let role: String
        let content: String
    }
}

private struct AnthropicResponse: Codable {
    let content: [ContentBlock]
    
    struct ContentBlock: Codable {
        let type: String
        let text: String?
    }
}
