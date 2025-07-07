//
//  GeminiConnect.swift
//  Devgentic
//
//  Created by Raj Singh.
//

import Foundation
import os

private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "com.devgentic.app", category: "GeminiConnectService")

/// Service responsible for communicating with the Google Gemini API.
class GeminiConnect {

    private let apiKey: String
    private let urlSession: URLSession

    /// Initializes the service with a specific API key.
    /// - Parameter apiKey: The Google AI Studio API key.
    init(apiKey: String) {
        self.apiKey = apiKey
        self.urlSession = URLSession.shared
        logger.info("GeminiConnectService initialized.")
    }

    /// Sends a user's query to the Gemini API using a dynamically provided model name.
    /// - Parameters:
    ///   - conversationID: The ID of the current conversation.
    ///   - userQuery: The user's text input.
    ///   - files: A list of attached files (currently ignored).
    ///   - modelName: The specific model to use for the request (e.g., "gemini-1.5-pro-latest").
    /// - Returns: A tuple containing an array of `ChatMessage` and an optional `Error`.
    func sendMessage(
        conversationID: UUID,
        userQuery: String,
        files: [FileSystemItem],
        modelName: String
    ) async throws -> ([ChatMessage], Error?) {

        guard let url = URL(string: "https://generativelanguage.googleapis.com/v1beta/models/\(modelName):generateContent?key=\(apiKey)") else {
            throw NSError(domain: "GeminiConnectService.URL", code: 0, userInfo: [NSLocalizedDescriptionKey: "Invalid Gemini API URL for model: \(modelName)"])
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.addValue("application/json", forHTTPHeaderField: "Content-Type")

        // Construct the request body
        // TODO: Implement multi-part messages for file/image support.
        let requestBody = GeminiRequest(contents: [Content(parts: [Part(text: userQuery)])])
        
        do {
            request.httpBody = try JSONEncoder().encode(requestBody)
        } catch {
            logger.error("Failed to encode Gemini request body: \(error.localizedDescription)")
            throw error
        }

        logger.debug("Sending request to Gemini API with model: \(modelName)")
        
        let (data, response) = try await urlSession.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
            let statusCode = (response as? HTTPURLResponse)?.statusCode ?? -1
            let errorResponse = String(data: data, encoding: .utf8) ?? "Unable to decode error response."
            logger.error("Gemini API returned a non-200 status code: \(statusCode). Response: \(errorResponse)")
            let errorContent = MessageContent.error(title: "Gemini API Error", details: "API Error (Code: \(statusCode)): \(errorResponse)")
            return ([ChatMessage(conversationId: conversationID, sender: .agent, content: errorContent)], nil)
        }

        do {
            let geminiResponse = try JSONDecoder().decode(GeminiResponse.self, from: data)
            
            if let responseText = geminiResponse.candidates.first?.content.parts.first?.text {
                let agentMessage = ChatMessage(conversationId: conversationID, sender: .agent, content: .markdownText(responseText))
                logger.info("Successfully received and parsed response from Gemini.")
                return ([agentMessage], nil)
            } else if let finishReason = geminiResponse.candidates.first?.finishReason {
                let reasonText = "The model finished but returned no text. Reason: \(finishReason)."
                logger.warning("\(reasonText)")
                let errorContent = MessageContent.error(title: "Empty Response", details: reasonText)
                 return ([ChatMessage(conversationId: conversationID, sender: .agent, content: errorContent)], nil)
            } else {
                 let errorText = "Could not find valid text in the Gemini API response."
                 logger.error("\(errorText) Response dump: \(String(data: data, encoding: .utf8) ?? "nil")")
                 let errorContent = MessageContent.error(title: "Invalid Response Structure", details: errorText)
                 return ([ChatMessage(conversationId: conversationID, sender: .agent, content: errorContent)], nil)
            }

        } catch {
            logger.error("Failed to decode Gemini JSON response: \(error.localizedDescription)")
            throw error
        }
    }
}


// MARK: - Codable Structs for Gemini API

private struct GeminiRequest: Codable {
    let contents: [Content]
}

private struct Content: Codable {
    let parts: [Part]
}

private struct Part: Codable {
    let text: String
}

private struct GeminiResponse: Codable {
    let candidates: [Candidate]
}

private struct Candidate: Codable {
    let content: Content
    let finishReason: String?
}
