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
        
        configuration.timeoutIntervalForRequest = TimeInterval.greatestFiniteMagnitude
        configuration.timeoutIntervalForResource = TimeInterval.greatestFiniteMagnitude
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.httpAdditionalHeaders = [
            "Content-Type": "application/json"
        ]
        
        return URLSession(configuration: configuration)
    }
    
    /// Establishes a streaming connection to the Gemini API and returns an async stream of text parts.
    /// This function is already compliant with the new architecture.
    func streamMessage(
        conversationID: UUID,
        userQuery: String,
        history: [ChatMessage],
        modelName: String,
        generationType: [GenerationType]?,
        context: TraceContext
    ) -> AsyncThrowingStream<String, Error> {
        // Check for image generation type
        if generationType?.contains(.imageData) == true {
            return AsyncThrowingStream { continuation in
                let error = NSError(domain: "GeminiConnectService.StreamingError", code: 0, userInfo: [NSLocalizedDescriptionKey: "Streaming is not supported for image generation models."])
                continuation.finish(throwing: error)
            }
        }
        
        return AsyncThrowingStream { continuation in
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
                        for try await byte in bytes { errorBody += String(data: Data([byte]), encoding: .utf8) ?? "" }
                        logger.error("Gemini API returned a non-200 status code: \(statusCode). Body: \(errorBody)")
                        let error = NSError(domain: "GeminiConnectService.APIError", code: statusCode, userInfo: [NSLocalizedDescriptionKey: "Gemini API Error: \(errorBody)"])
                        continuation.finish(throwing: error)
                        return
                    }
                    
                    var isFirstToken = true

                    for try await line in bytes.lines {
                        try Task.checkCancellation()
                        logger.trace("Raw stream line received: \(line)")

                        if line.hasPrefix("data: ") {
                            let jsonString = String(line.dropFirst(6))

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
                                    logger.warning("Could not decode a JSON object-like line: \(error.localizedDescription). JSON: \(jsonString)")
                                }
                            }
                        }
                    }
                    
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
            if message.sender == lastRole {
                logger.warning("Sanitizing history: found consecutive messages from the same sender (\(message.sender.rawValue)). Skipping.")
                continue
            }

            sanitized.append(message)
            lastRole = message.sender
        }
        
        if sanitized.first?.sender == .agent {
            logger.warning("Sanitizing history: first message was from the agent. Removing it.")
            sanitized.removeFirst()
        }

        return sanitized
    }

    /// **REFACTORED for Step 2.2**
    /// Sends a non-streaming message and returns raw response data instead of a ChatMessage.
    func sendMessage(
        conversationID: UUID,
        userQuery: String,
        history: [ChatMessage],
        modelName: String,
        generationType: [GenerationType]?
    ) async throws -> (responseText: String?, responseImageData: Data?, error: Error?) {
        
        if generationType?.contains(.imageData) == true {
            return try await generateImage(
                conversationID: conversationID,
                userQuery: userQuery,
                modelName: modelName
            )
        }
        
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
            let error = NSError(domain: "GeminiConnectService.APIError", code: statusCode, userInfo: [NSLocalizedDescriptionKey: "API Error (Code: \(statusCode)): \(errorDetails)"])
            return (nil, nil, error)
        }

        do {
            let geminiResponse = try JSONDecoder().decode(GeminiResponse.self, from: data)
            
            if let responseText = geminiResponse.candidates.first?.content.parts.first?.text {
                return (responseText, nil, nil)
            } else {
                 let errorText = "Could not find valid text in the Gemini API response."
                 let error = NSError(domain: "GeminiConnectService.APIError", code: 0, userInfo: [NSLocalizedDescriptionKey: errorText])
                 return (nil, nil, error)
            }

        } catch {
            logger.error("Failed to decode Gemini JSON response: \(error.localizedDescription)")
            throw error
        }
    }
    
    /// **REFACTORED for Step 2.2**
    /// Generates an image and returns raw Data instead of a ChatMessage.
    private func generateImage(
        conversationID: UUID,
        userQuery: String,
        modelName: String
    ) async throws -> (responseText: String?, responseImageData: Data?, error: Error?) {
        logger.info("Initiating image generation with model: \(modelName)")
        
        guard let url = URL(string: "https://generativelanguage.googleapis.com/v1beta/models/\(modelName):generateContent?key=\(apiKey)") else {
            throw NSError(domain: "GeminiConnectService.URL", code: 0, userInfo: [NSLocalizedDescriptionKey: "Invalid Gemini Image API URL for model: \(modelName)"])
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"

        let requestBody = GeminiImageRequest(
            contents: [
                Content(role: "user", parts: [Part(text: userQuery)])
            ],
            generationConfig: GenerationConfig(responseModalities: ["IMAGE", "TEXT"])
        )

        do {
            request.httpBody = try JSONEncoder().encode(requestBody)
            logRequestPayload(requestBody, for: "generateImage")
        } catch {
            logger.error("Failed to encode Gemini Image request body: \(error.localizedDescription)")
            throw error
        }

        let (data, response) = try await self.session.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
            let statusCode = (response as? HTTPURLResponse)?.statusCode ?? -1
            let errorDetails = String(data: data, encoding: .utf8) ?? "Unable to decode error response."
            logger.error("Gemini Image API returned a non-200 status code: \(statusCode). Response: \(errorDetails)")
            let error = NSError(domain: "GeminiConnectService.APIError", code: statusCode, userInfo: [NSLocalizedDescriptionKey: "API Error (Code: \(statusCode)): \(errorDetails)"])
            return (nil, nil, error)
        }

        do {
            let geminiResponse = try JSONDecoder().decode(GeminiResponse.self, from: data)
            
            if let base64String = geminiResponse.candidates.first?.content.parts.first(where: { $0.inlineData != nil })?.inlineData?.data,
               let imageData = Data(base64Encoded: base64String) {
                
                logger.info("Successfully decoded image data from Base64 string.")
                return (nil, imageData, nil)
                
            } else {
                let errorText = "Could not find valid image data in the Gemini API response."
                logger.warning("\(errorText)")
                let error = NSError(domain: "GeminiConnectService.APIError", code: 0, userInfo: [NSLocalizedDescriptionKey: errorText])
                return (nil, nil, error)
            }
        } catch {
            logger.error("Failed to decode Gemini Image JSON response: \(error.localizedDescription)")
            throw error
        }
    }
    
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

private struct Content: Codable {
    let role: String?
    let parts: [Part]
}

private struct Part: Codable {
    let text: String?
    let inlineData: InlineData?
    
    init(text: String?, inlineData: InlineData? = nil) {
        self.text = text
        self.inlineData = inlineData
    }
    
    struct InlineData: Codable {
        let mimeType: String
        let data: String
    }
}

private struct GeminiResponse: Codable {
    let candidates: [Candidate]

    struct Candidate: Codable {
        let content: Content
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


// MARK: - Codable Structs for Gemini Image Generation API (generateContent)

private struct GeminiImageRequest: Codable {
    let contents: [Content]
    let generationConfig: GenerationConfig
}

private struct GenerationConfig: Codable {
    let responseModalities: [String]
}
