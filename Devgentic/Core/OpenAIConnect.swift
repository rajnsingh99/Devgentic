//
//  OpenAIConnect.swift
//  Devgentic
//
//  Created by Raj Singh.
//

import Foundation
import os

private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "com.devgentic.app", category: "OpenAIConnectService")

/// Service responsible for communicating with the OpenAI API.
class OpenAIConnect {

    private let apiKey: String
    private let urlSession: URLSession

    init(apiKey: String) {
        self.apiKey = apiKey
        self.urlSession = URLSession.shared
        logger.info("OpenAIConnectService initialized.")
    }

    /// Sends a user's query to the OpenAI API.
    func sendMessage(
        conversationID: UUID,
        userQuery: String,
        files: [FileSystemItem],
        modelName: String
    ) async throws -> ([ChatMessage], Error?) {

        guard let url = URL(string: "https://api.openai.com/v1/chat/completions") else {
            throw NSError(domain: "OpenAIConnectService.URL", code: 0, userInfo: [NSLocalizedDescriptionKey: "Invalid OpenAI API URL."])
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")

        // Construct the request body
        // TODO: Add support for files/images and conversation history
        let requestBody = OpenAIRequest(
            model: modelName,
            messages: [OpenAIRequest.Message(role: "user", content: userQuery)]
        )

        do {
            request.httpBody = try JSONEncoder().encode(requestBody)
        } catch {
            logger.error("Failed to encode OpenAI request body: \(error.localizedDescription)")
            throw error
        }

        logger.debug("Sending request to OpenAI API with model: \(modelName)")
        
        let (data, response) = try await urlSession.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
            let statusCode = (response as? HTTPURLResponse)?.statusCode ?? -1
            let errorResponse = String(data: data, encoding: .utf8) ?? "Unable to decode error response."
            logger.error("OpenAI API returned a non-200 status code: \(statusCode). Response: \(errorResponse)")
            let errorContent = MessageContent.error(title: "OpenAI API Error", details: "API Error (Code: \(statusCode)): \(errorResponse)")
            return ([ChatMessage(conversationId: conversationID, sender: .agent, content: errorContent)], nil)
        }

        do {
            let openAIResponse = try JSONDecoder().decode(OpenAIResponse.self, from: data)
            
            if let responseText = openAIResponse.choices.first?.message.content {
                let agentMessage = ChatMessage(conversationId: conversationID, sender: .agent, content: .markdownText(responseText))
                logger.info("Successfully received and parsed response from OpenAI.")
                return ([agentMessage], nil)
            } else {
                let errorText = "Could not find valid text in the OpenAI API response."
                logger.error("\(errorText) Response dump: \(String(data: data, encoding: .utf8) ?? "nil")")
                let errorContent = MessageContent.error(title: "Invalid Response Structure", details: errorText)
                return ([ChatMessage(conversationId: conversationID, sender: .agent, content: errorContent)], nil)
            }

        } catch {
            logger.error("Failed to decode OpenAI JSON response: \(error.localizedDescription)")
            throw error
        }
    }
}

// MARK: - Codable Structs for OpenAI API

private struct OpenAIRequest: Codable {
    let model: String
    let messages: [Message]

    struct Message: Codable {
        let role: String
        let content: String
    }
}

private struct OpenAIResponse: Codable {
    let choices: [Choice]

    struct Choice: Codable {
        let message: Message
    }
    
    struct Message: Codable {
        let content: String?
    }
}
