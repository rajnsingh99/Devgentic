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
    private let session: URLSession // Use a custom-configured session, not URLSession.shared

    /// Initializes the service with a specific API key.
    /// - Parameter apiKey: The Google AI Studio API key.
    init(apiKey: String) {
        self.apiKey = apiKey
        // Create a URLSession specifically configured for streaming.
        self.session = GeminiConnect.createStreamingURLSession()
        logger.info("GeminiConnectService initialized with a custom URLSession for streaming.")
    }
    
    /// Creates a URLSession instance with a configuration tailored for long-lived streaming requests.
    private static func createStreamingURLSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        
        // Per the research, this is the most critical setting for streaming.
        // It prevents the session from timing out if the server is idle between events.
        configuration.timeoutIntervalForRequest = TimeInterval.greatestFiniteMagnitude
        configuration.timeoutIntervalForResource = TimeInterval.greatestFiniteMagnitude
        
        // Ensure we always fetch fresh data from the network.
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        
        // Set required headers that will apply to all requests in this session.
        configuration.httpAdditionalHeaders = [
            "Content-Type": "application/json"
            // Note: "Accept: text/event-stream" is removed as Gemini's streaming response
            // is a fragmented JSON array, not a standard SSE stream.
        ]
        
        return URLSession(configuration: configuration)
    }
    
    /// Establishes a streaming connection to the Gemini API and returns an async stream of text parts.
    func streamMessage(
        conversationID: UUID,
        userQuery: String,
        history: [ChatMessage],
        modelName: String,
        context: TraceContext
    ) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            Task {
                let apiContext = context.newSpan()
                logger.info("API Call Start: Gemini. traceID: \(apiContext.traceID), spanID: \(apiContext.spanID)")
                
                let apiStartTime = Date()
                var firstTokenTime: Date? = nil

                guard let url = URL(string: "https://generativelanguage.googleapis.com/v1beta/models/\(modelName):streamGenerateContent?alt=sse&key=\(self.apiKey)") else {
                    let error = NSError(domain: "GeminiConnectService.URL", code: 0, userInfo: [NSLocalizedDescriptionKey: "Invalid Gemini API URL for model: \(modelName)"])
                    continuation.finish(throwing: error)
                    return
                }

                var request = URLRequest(url: url)
                request.httpMethod = "POST"
                request.addValue("curl/8.6.0", forHTTPHeaderField: "User-Agent")

                let sanitizedHistory = self.sanitizeHistory(history)
                
                let apiContents = sanitizedHistory.compactMap { message -> Content? in
                    let role = message.sender == .user ? "user" : "model"
                    guard let contentText = message.content.textContent else { return nil }
                    return Content(role: role, parts: [Part(text: contentText)])
                } + [Content(role: "user", parts: [Part(text: userQuery)])]

                let requestBody = GeminiRequest(contents: apiContents)
                
                do {
                    request.httpBody = try JSONEncoder().encode(requestBody)
                    // --- ADDED: Robust payload logging ---
                    logRequestPayload(requestBody, for: "streamMessage")
                } catch {
                    logger.error("Failed to encode Gemini request body: \(error.localizedDescription)")
                    continuation.finish(throwing: error)
                    return
                }

                do {
                    let (bytes, response) = try await self.session.bytes(for: request)

                    guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
                        let statusCode = (response as? HTTPURLResponse)?.statusCode ?? -1
                        var errorBody = ""
                        // Asynchronously read the error body
                        for try await byte in bytes { errorBody += String(data: Data([byte]), encoding: .utf8) ?? "" }
                        logger.error("Gemini API returned a non-200 status code: \(statusCode). Body: \(errorBody)")
                        let error = NSError(domain: "GeminiConnectService.APIError", code: statusCode, userInfo: [NSLocalizedDescriptionKey: "Gemini API Error: \(errorBody)"])
                        continuation.finish(throwing: error)
                        return
                    }
                    
                    var isFirstToken = true

                    // --- NEW ROBUST PARSING LOGIC ---
                    // This logic handles the fragmented, multi-line JSON stream from the Gemini API.
                    // It buffers incoming data and parses complete JSON objects as they are formed.
                    for try await line in bytes.lines {
                        try Task.checkCancellation()
                        logger.trace("Raw stream line received: \(line)")

                        // The Gemini stream sends data in a Server-Sent Event (SSE) like format,
                        // where each data payload is prefixed with "data: ".
                        if line.hasPrefix("data: ") {
                            let jsonString = String(line.dropFirst(6)) // Remove "data: " prefix

                            if let data = jsonString.data(using: .utf8) {
                                do {
                                    let responseChunk = try JSONDecoder().decode(GeminiResponse.self, from: data)
                                    if let newText = responseChunk.candidates.first?.content.parts.first?.text {
                                        if isFirstToken {
                                            firstTokenTime = Date()
                                            isFirstToken = false
                                        }
                                        logger.debug("Stream received token: \"\(newText.replacingOccurrences(of: "\n", with: "\\n"))\"")
                                        continuation.yield(newText)
                                    }
                                } catch {
                                    // This can happen if a JSON chunk is malformed. Log it and continue.
                                    logger.warning("Could not decode a JSON object-like line: \(error.localizedDescription). JSON: \(jsonString)")
                                }
                            }
                        }
                    }
                    // --- END OF NEW PARSING LOGIC ---
                    
                    let apiEndTime = Date()
                    if let firstTokenTime = firstTokenTime {
                        let ttftDuration = firstTokenTime.timeIntervalSince(apiStartTime)
                        await MetricsManager.shared.record(duration: ttftDuration, for: "time_to_first_token", context: apiContext, provider: .google)
                    }
                    let totalDuration = apiEndTime.timeIntervalSince(apiStartTime)
                    await MetricsManager.shared.record(duration: totalDuration, for: "api_call_duration", context: apiContext, provider: .google)
                    logger.info("API Call Finished: Gemini. traceID: \(apiContext.traceID), spanID: \(apiContext.spanID)")
                    
                    continuation.finish()
                    
                } catch is CancellationError {
                    logger.info("Gemini stream was cancelled by the client.")
                    continuation.finish(throwing: CancellationError())
                } catch {
                    logger.error("Error during Gemini API stream: \(error.localizedDescription)")
                    continuation.finish(throwing: error)
                }
            }
        }
    }

    private func sanitizeHistory(_ messages: [ChatMessage]) -> [ChatMessage] {
        var sanitized: [ChatMessage] = []
        var lastRole: SenderRole? = nil

        for message in messages {
            guard message.content.textContent != nil, !message.content.textContent!.isEmpty else { continue }
            // Gemini requires alternating roles. If the last message has the same sender, skip this one.
            if message.sender == lastRole {
                logger.warning("Sanitizing history: found consecutive messages from the same sender (\(message.sender.rawValue)). Skipping.")
                continue
            }

            sanitized.append(message)
            lastRole = message.sender
        }
        
        // The conversation must start with a 'user' role message.
        if sanitized.first?.sender == .agent {
            logger.warning("Sanitizing history: first message was from the agent. Removing it.")
            sanitized.removeFirst()
        }

        return sanitized
    }

    func sendMessage(
        conversationID: UUID,
        userQuery: String,
        history: [ChatMessage],
        modelName: String
    ) async throws -> ([ChatMessage], Error?) {
        // This non-streaming method can continue to use the same session.
        // Its behavior is not affected by the long timeout.
        guard let url = URL(string: "https://generativelanguage.googleapis.com/v1beta/models/\(modelName):generateContent?key=\(apiKey)") else {
            throw NSError(domain: "GeminiConnectService.URL", code: 0, userInfo: [NSLocalizedDescriptionKey: "Invalid Gemini API URL for model: \(modelName)"])
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        
        let sanitizedHistory = self.sanitizeHistory(history)
        var apiContents = sanitizedHistory.compactMap { message -> Content? in
            let role = message.sender == .user ? "user" : "model"
            guard let contentText = message.content.textContent else { return nil }
            return Content(role: role, parts: [Part(text: contentText)])
        }

        apiContents.append(Content(role: "user", parts: [Part(text: userQuery)]))
        
        let requestBody = GeminiRequest(contents: apiContents)
        
        do {
            request.httpBody = try JSONEncoder().encode(requestBody)
            // --- ADDED: Robust payload logging ---
            logRequestPayload(requestBody, for: "sendMessage")
        } catch {
            logger.error("Failed to encode Gemini request body: \(error.localizedDescription)")
            throw error
        }
        
        let (data, response) = try await self.session.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
            let statusCode = (response as? HTTPURLResponse)?.statusCode ?? -1
            var errorDetails = String(data: data, encoding: .utf8) ?? "Unable to decode error response."
            
            if let errorResponse = try? JSONDecoder().decode(GeminiErrorResponse.self, from: data) {
                errorDetails = errorResponse.error.message
            }
            
            logger.error("Gemini API returned a non-200 status code: \(statusCode). Response: \(errorDetails)")
            let errorContent = MessageContent.error(title: "Gemini API Error", details: "API Error (Code: \(statusCode)): \(errorDetails)")
            return ([ChatMessage(conversationId: conversationID, sender: .agent, content: errorContent)], nil)
        }

        do {
            let geminiResponse = try JSONDecoder().decode(GeminiResponse.self, from: data)
            
            if let responseText = geminiResponse.candidates.first?.content.parts.first?.text {
                let agentMessage = ChatMessage(conversationId: conversationID, sender: .agent, content: .markdownText(responseText))
                return ([agentMessage], nil)
            } else {
                 let errorText = "Could not find valid text in the Gemini API response."
                 let errorContent = MessageContent.error(title: "Invalid Response Structure", details: errorText)
                 return ([ChatMessage(conversationId: conversationID, sender: .agent, content: errorContent)], nil)
            }

        } catch {
            logger.error("Failed to decode Gemini JSON response: \(error.localizedDescription)")
            throw error
        }
    }
    
    // --- ADDED: Private helper for logging request payloads ---
    /// Encodes a `Codable` request body to a pretty-printed JSON string and logs it.
    /// - Parameters:
    ///   - payload: The `Codable` object to be logged.
    ///   - functionName: The name of the calling function, for context in logs.
    private func logRequestPayload<T: Codable>(_ payload: T, for functionName: String) {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .prettyPrinted
        do {
            let data = try encoder.encode(payload)
            if let jsonString = String(data: data, encoding: .utf8) {
                logger.debug("""
                [GeminiConnect] Request Payload for \(functionName):
                ---
                \(jsonString)
                ---
                """)
            }
        } catch {
            logger.error("[GeminiConnect] Failed to encode request payload for logging: \(error.localizedDescription)")
        }
    }
}


// MARK: - Codable Structs for Gemini API

private struct GeminiRequest: Codable {
    let contents: [Content]
}

// Unified Content/Part for request and response
private struct Content: Codable {
    // Role is required for requests, but optional in response content.
    let role: String?
    let parts: [Part]
}

private struct Part: Codable {
    let text: String
}

// Unified Response for both streaming chunks and full non-streaming responses
private struct GeminiResponse: Codable {
    let candidates: [Candidate]

    struct Candidate: Codable {
        let content: Content
        // Finish reason is optional, especially in streaming chunks.
        let finishReason: String?
    }
}

private struct GeminiErrorResponse: Codable {
    let error: GeminiError
    
    struct GeminiError: Codable {
        let code: Int
        let message: String
        let status: String
    }
}
