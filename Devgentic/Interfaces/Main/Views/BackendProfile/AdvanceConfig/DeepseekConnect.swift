//
//  DeepseekConnect.swift
//  Devgentic
//
//  Created by Raj Singh on 25/08/25.
//

import Foundation
import os

private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "com.devgentic.app", category: "DeepseekConnectService")

/// Service responsible for communicating with the Deepseek API.
class DeepseekConnect {

    private let apiKey: String
    private let session: URLSession

    /// Initializes the service with a specific API key.
    init(apiKey: String) {
        self.apiKey = apiKey
        self.session = DeepseekConnect.createStreamingURLSession()
        logger.info("DeepseekConnectService initialized.")
    }
    
    private static func createStreamingURLSession() -> URLSession {
        let configuration = URLSessionConfiguration.default
        configuration.timeoutIntervalForRequest = TimeInterval.greatestFiniteMagnitude
        configuration.timeoutIntervalForResource = TimeInterval.greatestFiniteMagnitude
        return URLSession(configuration: configuration)
    }
    
    /// Establishes a streaming connection to the Deepseek API.
    func streamMessage(
        userQuery: String,
        history: [ChatMessage],
        modelName: String,
        advancedConfig: DeepseekAdvancedConfig?
    ) -> AsyncThrowingStream<String, Error> {
        
        return AsyncThrowingStream { continuation in
            Task {
                guard let url = URL(string: "https://api.deepseek.com/v1/chat/completions") else {
                    continuation.finish(throwing: NSError(domain: "DeepseekConnect.URL", code: 0, userInfo: [NSLocalizedDescriptionKey: "Invalid API URL"]))
                    return
                }

                var request = URLRequest(url: url)
                request.httpMethod = "POST"
                request.setValue("Bearer \(self.apiKey)", forHTTPHeaderField: "Authorization")
                request.setValue("application/json", forHTTPHeaderField: "Content-Type")

                let messages = sanitizeHistory(history).map {
                    DeepseekRequest.Message(role: $0.sender == .user ? "user" : "assistant", content: $0.content.textContent ?? "")
                } + [DeepseekRequest.Message(role: "user", content: userQuery)]

                let requestBody = DeepseekRequest(
                    model: modelName,
                    messages: messages,
                    stream: true,
                    temperature: advancedConfig?.temperature,
                    topP: advancedConfig?.topP,
                    maxTokens: advancedConfig?.maxTokens,
                    frequencyPenalty: advancedConfig?.frequencyPenalty,
                    presencePenalty: advancedConfig?.presencePenalty
                )
                
                do {
                    request.httpBody = try JSONEncoder().encode(requestBody)
                } catch {
                    logger.error("Failed to encode Deepseek request body: \(error.localizedDescription)")
                    continuation.finish(throwing: error)
                    return
                }

                do {
                    let (bytes, response) = try await self.session.bytes(for: request)

                    guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
                        let statusCode = (response as? HTTPURLResponse)?.statusCode ?? -1
                        let error = NSError(domain: "DeepseekConnect.APIError", code: statusCode, userInfo: [NSLocalizedDescriptionKey: "Deepseek API returned non-200 status."])
                        continuation.finish(throwing: error)
                        return
                    }

                    for try await line in bytes.lines {
                        if line.hasPrefix("data: ") {
                            let jsonString = String(line.dropFirst(6))
                            guard jsonString != "[DONE]" else {
                                continuation.finish()
                                return
                            }
                            
                            if let data = jsonString.data(using: .utf8) {
                                do {
                                    let chunk = try JSONDecoder().decode(DeepseekStreamResponse.self, from: data)
                                    if let text = chunk.choices.first?.delta.content {
                                        continuation.yield(text)
                                    }
                                } catch {
                                    logger.warning("Could not decode a Deepseek JSON stream object: \(error.localizedDescription). JSON: \(jsonString)")
                                }
                            }
                        }
                    }
                    continuation.finish()
                } catch {
                    logger.error("Error during Deepseek API stream: \(error.localizedDescription)")
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
        return sanitized
    }
}

// MARK: - Codable Structs for Deepseek API

private struct DeepseekRequest: Codable {
    let model: String
    let messages: [Message]
    let stream: Bool
    var temperature: Double?
    var topP: Double?
    var maxTokens: Int?
    var frequencyPenalty: Double?
    var presencePenalty: Double?

    enum CodingKeys: String, CodingKey {
        case model, messages, stream, temperature
        case topP = "top_p"
        case maxTokens = "max_tokens"
        case frequencyPenalty = "frequency_penalty"
        case presencePenalty = "presence_penalty"
    }
    
    struct Message: Codable {
        let role: String
        let content: String
    }
}

private struct DeepseekStreamResponse: Codable {
    let choices: [Choice]
    
    struct Choice: Codable {
        let delta: Delta
    }
    
    struct Delta: Codable {
        let content: String?
    }
}
