//
//  LLMProviders.swift
//  Devgentic
//
//  Created by Devgentic Architect
//
//  URLSession-based LLM provider implementations replacing
//  OllamaLanguageModel, OpenAILanguageModel, and MLXLanguageModel.
//

import Foundation
import OSLog

private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "com.devgentic.app", category: "LLMProviders")

// MARK: - OpenAI-Compatible Provider

/// Handles OpenAI, Gemini (via compatible endpoint), and any OpenAI-compatible API.
/// Supports structured output via the `response_format` parameter.
struct OpenAILLMProvider: LLMProvider {

    let config: LLMProviderConfig

    init(config: LLMProviderConfig) {
        self.config = config
    }

    func generate(messages: [[String: String]], responseSchema: [String: Any]?) async throws -> String {
        let url = config.baseURL.appendingPathComponent("chat/completions")
        var request = URLRequest(url: url, timeoutInterval: config.timeout)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        if let apiKey = config.apiKey {
            request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        }

        var body: [String: Any] = [
            "model": config.modelName,
            "messages": messages,
            "stream": false
        ]

        // Structured output: embed JSON schema in response_format
        if let schema = responseSchema {
            body["response_format"] = [
                "type": "json_schema",
                "json_schema": [
                    "name": "cognitive_step",
                    "strict": true,
                    "schema": schema
                ] as [String: Any]
            ] as [String: Any]
        }

        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await URLSession.shared.data(for: request)

        try self.validateHTTPResponse(response, data: data)

        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        guard let choices = json?["choices"] as? [[String: Any]],
              let message = choices.first?["message"] as? [String: Any],
              let content = message["content"] as? String else {
            throw LLMProviderError.invalidResponse("Missing content in OpenAI response")
        }

        return content
    }

    func stream(messages: [[String: String]]) -> AsyncThrowingStream<String, Error> {
        return AsyncThrowingStream { continuation in
            Task {
                do {
                    let url = config.baseURL.appendingPathComponent("chat/completions")
                    var request = URLRequest(url: url, timeoutInterval: config.timeout)
                    request.httpMethod = "POST"
                    request.setValue("application/json", forHTTPHeaderField: "Content-Type")

                    if let apiKey = config.apiKey {
                        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
                    }

                    let body: [String: Any] = [
                        "model": config.modelName,
                        "messages": messages,
                        "stream": true
                    ]

                    request.httpBody = try JSONSerialization.data(withJSONObject: body)

                    let (bytes, response) = try await URLSession.shared.bytes(for: request)

                    guard let httpResponse = response as? HTTPURLResponse else {
                        throw LLMProviderError.invalidResponse("Not an HTTP response")
                    }

                    guard (200...299).contains(httpResponse.statusCode) else {
                        // Collect error body for diagnostics
                        var errorBody = ""
                        for try await line in bytes.lines {
                            errorBody += line
                        }
                        throw LLMProviderError.httpError(httpResponse.statusCode, errorBody)
                    }

                    // Parse SSE (Server-Sent Events) stream
                    for try await line in bytes.lines {
                        guard line.hasPrefix("data: ") else { continue }
                        let payload = String(line.dropFirst(6))

                        if payload == "[DONE]" { break }

                        guard let chunkData = payload.data(using: .utf8),
                              let chunk = try? JSONSerialization.jsonObject(with: chunkData) as? [String: Any],
                              let choices = chunk["choices"] as? [[String: Any]],
                              let delta = choices.first?["delta"] as? [String: Any],
                              let content = delta["content"] as? String else {
                            continue
                        }

                        continuation.yield(content)
                    }

                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
        }
    }

    private func validateHTTPResponse(_ response: URLResponse, data: Data) throws {
        guard let httpResponse = response as? HTTPURLResponse else {
            throw LLMProviderError.invalidResponse("Not an HTTP response")
        }

        guard (200...299).contains(httpResponse.statusCode) else {
            let body = String(data: data, encoding: .utf8) ?? "Unknown error"
            throw LLMProviderError.httpError(httpResponse.statusCode, body)
        }
    }
}

// MARK: - Ollama Provider

/// Handles local Ollama API interactions via POST /api/chat.
struct OllamaLLMProvider: LLMProvider {

    let config: LLMProviderConfig

    init(config: LLMProviderConfig) {
        self.config = config
    }

    func generate(messages: [[String: String]], responseSchema: [String: Any]?) async throws -> String {
        let url = config.baseURL.appendingPathComponent("api/chat")
        var request = URLRequest(url: url, timeoutInterval: config.timeout)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        var body: [String: Any] = [
            "model": config.modelName,
            "messages": messages,
            "stream": false
        ]

        // Ollama supports structured output via the "format" field
        if let schema = responseSchema {
            body["format"] = schema
        }

        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await URLSession.shared.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse,
              (200...299).contains(httpResponse.statusCode) else {
            let body = String(data: data, encoding: .utf8) ?? "Unknown error"
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            throw LLMProviderError.httpError(status, body)
        }

        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        guard let message = json?["message"] as? [String: Any],
              let content = message["content"] as? String else {
            throw LLMProviderError.invalidResponse("Missing content in Ollama response")
        }

        return content
    }

    func stream(messages: [[String: String]]) -> AsyncThrowingStream<String, Error> {
        return AsyncThrowingStream { continuation in
            Task {
                do {
                    let url = config.baseURL.appendingPathComponent("api/chat")
                    var request = URLRequest(url: url, timeoutInterval: config.timeout)
                    request.httpMethod = "POST"
                    request.setValue("application/json", forHTTPHeaderField: "Content-Type")

                    let body: [String: Any] = [
                        "model": config.modelName,
                        "messages": messages,
                        "stream": true
                    ]

                    request.httpBody = try JSONSerialization.data(withJSONObject: body)

                    let (bytes, response) = try await URLSession.shared.bytes(for: request)

                    guard let httpResponse = response as? HTTPURLResponse,
                          (200...299).contains(httpResponse.statusCode) else {
                        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
                        throw LLMProviderError.httpError(status, "Ollama streaming error")
                    }

                    // Ollama streams newline-delimited JSON objects
                    for try await line in bytes.lines {
                        guard !line.isEmpty,
                              let lineData = line.data(using: .utf8),
                              let json = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any],
                              let message = json["message"] as? [String: Any],
                              let content = message["content"] as? String else {
                            continue
                        }

                        continuation.yield(content)

                        // Check if Ollama signals completion
                        if let done = json["done"] as? Bool, done { break }
                    }

                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
        }
    }
}

// MARK: - MLX Provider

/// Wraps the existing MLXService for on-device inference.
struct MLXLLMProvider: LLMProvider {

    let modelName: String

    init(modelName: String) {
        self.modelName = modelName
    }

    func generate(messages: [[String: String]], responseSchema: [String: Any]?) async throws -> String {
        var fullText = ""
        let temperature: Float = 0.6
        let maxTokens = 2048

        let stream = await MLXService.shared.streamChat(
            messages: messages,
            maxTokens: maxTokens,
            temperature: temperature
        )

        for try await token in stream {
            fullText += token
        }

        return fullText
    }

    func stream(messages: [[String: String]]) -> AsyncThrowingStream<String, Error> {
        let temperature: Float = 0.6
        let maxTokens = 2048

        return AsyncThrowingStream { continuation in
            Task {
                do {
                    let tokenStream = await MLXService.shared.streamChat(
                        messages: messages,
                        maxTokens: maxTokens,
                        temperature: temperature
                    )

                    for try await token in tokenStream {
                        continuation.yield(token)
                    }

                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
        }
    }
}

// MARK: - Error Type

/// Errors specific to LLM provider operations.
enum LLMProviderError: LocalizedError {
    case httpError(Int, String)
    case invalidResponse(String)
    case unsupportedProvider(String)

    var errorDescription: String? {
        switch self {
        case .httpError(let status, let body):
            return "HTTP \(status): \(body)"
        case .invalidResponse(let detail):
            return "Invalid response: \(detail)"
        case .unsupportedProvider(let name):
            return "Unsupported provider: \(name)"
        }
    }
}
