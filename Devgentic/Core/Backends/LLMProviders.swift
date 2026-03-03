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

// MARK: - LLM Provider Protocol

/// The contract for all Language Model providers in Devgentic.
/// Uses the standard OpenAI-compatible messages format directly,
/// eliminating the need for intermediate Transcript types.
protocol LLMProvider: Sendable {

    /// Generates a complete response for the given conversation.
    /// - Parameters:
    ///   - messages: An array of message dictionaries in OpenAI chat format:
    ///     `[{"role": "system"|"user"|"assistant", "content": "..."}]`
    ///   - tools: An optional array of tool dictionaries in the provider's native format.
    ///   - responseSchema: An optional JSON Schema dictionary for structured output enforcement.
    ///     Providers that support it (OpenAI, Ollama) embed this in the API request body.
    /// - Returns: The full text response from the model.
    func generate(messages: [[String: String]], tools: [[String: Any]]?, responseSchema: [String: Any]?) async throws -> String

    /// Streams a response token-by-token for the given conversation.
    /// - Parameter messages: An array of message dictionaries in OpenAI chat format.
    /// - Parameter tools: An optional array of tool dictionaries in the provider's native format.
    /// - Returns: An async stream of string chunks (deltas) as they are generated.
    func stream(messages: [[String: String]], tools: [[String: Any]]?) -> AsyncThrowingStream<String, Error>
}

// MARK: - Provider Configuration

/// Lightweight configuration for HTTP-based LLM providers.
struct LLMProviderConfig: Sendable {
    let apiKey: String?
    let baseURL: URL
    let modelName: String
    let timeout: TimeInterval

    init(apiKey: String? = nil, baseURL: URL, modelName: String, timeout: TimeInterval = 300.0) {
        self.apiKey = apiKey
        self.baseURL = baseURL
        self.modelName = modelName
        self.timeout = timeout
    }
}

// MARK: - OpenAI-Compatible Provider

/// Handles OpenAI, Gemini (via compatible endpoint), and any OpenAI-compatible API.
/// Supports structured output via the `response_format` parameter.
struct OpenAILLMProvider: LLMProvider {

    let config: LLMProviderConfig

    init(config: LLMProviderConfig) {
        self.config = config
    }

    func generate(messages: [[String: String]], tools: [[String: Any]]?, responseSchema: [String: Any]?) async throws -> String {
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

        // Inject tools if provided
        if let tools = tools, !tools.isEmpty {
            body["tools"] = tools
        }

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
              let message = choices.first?["message"] as? [String: Any] else {
            throw LLMProviderError.invalidResponse("Missing message object in OpenAI response")
        }

        let content = message["content"] as? String ?? ""
        
        // --- NATIVE TOOL INTERCEPTION BRIDGE ---
        // Maps a native tool_calls array back into the expected LeanCognitiveStep JSON string format
        if let toolCalls = message["tool_calls"] as? [[String: Any]],
           let firstTool = toolCalls.first?["function"] as? [String: Any],
           let toolName = firstTool["name"] as? String {
            
            var argumentsDict: [String: Any] = [:]
            
            // OpenAI typically returns arguments as a JSON String
            if let argsAsString = firstTool["arguments"] as? String,
               let parsedDict = (try? JSONSerialization.jsonObject(with: argsAsString.data(using: .utf8) ?? Data())) as? [String: Any] {
                argumentsDict = parsedDict
            } else if let argsAsDict = firstTool["arguments"] as? [String: Any] {
                argumentsDict = argsAsDict
            }
            
            // Synthesize the LeanCognitiveStep
            let syntheticStep: [String: Any] = [
                "content": content.isEmpty ? "Executing tool \(toolName)..." : content,
                "tool_name": toolName,
                "arguments": argumentsDict
            ]
            
            let syntheticData = try JSONSerialization.data(withJSONObject: syntheticStep)
            return String(data: syntheticData, encoding: .utf8) ?? "{}"
        }

        return content
    }

    func stream(messages: [[String: String]], tools: [[String: Any]]?) -> AsyncThrowingStream<String, Error> {
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

                    var body: [String: Any] = [
                        "model": config.modelName,
                        "messages": messages,
                        "stream": true
                    ]

                    // Inject tools if provided
                    if let tools = tools, !tools.isEmpty {
                        body["tools"] = tools
                    }

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

    func generate(messages: [[String: String]], tools: [[String: Any]]?, responseSchema: [String: Any]?) async throws -> String {
        let url = config.baseURL.appendingPathComponent("api/chat")
        var request = URLRequest(url: url, timeoutInterval: config.timeout)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        var body: [String: Any] = [
            "model": config.modelName,
            "messages": messages,
            "stream": false
        ]

        // Ollama supports tools natively as well
        if let tools = tools, !tools.isEmpty {
            body["tools"] = tools
        }

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
        guard let message = json?["message"] as? [String: Any] else {
            throw LLMProviderError.invalidResponse("Missing message object in Ollama response")
        }

        let content = message["content"] as? String ?? ""
        
        // --- NATIVE TOOL INTERCEPTION BRIDGE ---
        // Maps a native tool_calls array back into the expected LeanCognitiveStep JSON string format
        if let toolCalls = message["tool_calls"] as? [[String: Any]],
           let firstTool = toolCalls.first?["function"] as? [String: Any],
           let toolName = firstTool["name"] as? String {
            
            var argumentsDict: [String: Any] = [:]
            
            // Ollama typically returns arguments as a JSON Dictionary directly
            if let argsAsDict = firstTool["arguments"] as? [String: Any] {
                argumentsDict = argsAsDict
            } else if let argsAsString = firstTool["arguments"] as? String,
                      let parsedDict = (try? JSONSerialization.jsonObject(with: argsAsString.data(using: .utf8) ?? Data())) as? [String: Any] {
                argumentsDict = parsedDict
            }
            
            // Synthesize the LeanCognitiveStep
            let syntheticStep: [String: Any] = [
                "content": content.isEmpty ? "Executing tool \(toolName)..." : content,
                "tool_name": toolName,
                "arguments": argumentsDict
            ]
            
            let syntheticData = try JSONSerialization.data(withJSONObject: syntheticStep)
            return String(data: syntheticData, encoding: .utf8) ?? "{}"
        }

        return content
    }

    func stream(messages: [[String: String]], tools: [[String: Any]]?) -> AsyncThrowingStream<String, Error> {
        return AsyncThrowingStream { continuation in
            Task {
                do {
                    let url = config.baseURL.appendingPathComponent("api/chat")
                    var request = URLRequest(url: url, timeoutInterval: config.timeout)
                    request.httpMethod = "POST"
                    request.setValue("application/json", forHTTPHeaderField: "Content-Type")

                    var body: [String: Any] = [
                        "model": config.modelName,
                        "messages": messages,
                        "stream": true
                    ]

                    // Ollama supports tools natively as well
                    if let tools = tools, !tools.isEmpty {
                        body["tools"] = tools
                    }

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

// MARK: - Error Type

/// Errors specific to LLM provider operations.
enum LLMProviderError: LocalizedError {
    case httpError(Int, String)
    case invalidResponse(String)
    case unsupportedProvider(String)

    var errorDescription: String? {
        switch self {
        case .httpError(let status, let body):
            return LLMProviderError.formatHTTPError(status: status, body: body)
        case .invalidResponse(let detail):
            return "Invalid response: \(detail)"
        case .unsupportedProvider(let name):
            return "Unsupported provider: \(name)"
        }
    }
    
    /// Translates raw HTTP API errors into clean, user-facing guidance.
    private static func formatHTTPError(status: Int, body: String) -> String {
        let lowerBody = body.lowercased()
        
        // 1. Specific Interception: Gemini 429 Quota / Billing Error
        if status == 429 && (lowerBody.contains("gemini") || lowerBody.contains("generativelanguage")) {
            return """
            ⚠️ Google Gemini API Quota Exceeded
            
            Your request was blocked by Google. This typically occurs because:
            1. You are located in a region (e.g., UK, EEA, or Switzerland) where Google requires an active billing account to use the API, even for free-tier models.
            2. You have exceeded the strict rate limits on your current plan.
            
            Action Required:
            Please visit Google AI Studio (https://aistudio.google.com/) to attach a valid billing account to your API key, or switch your Devgentic profile to a different LLM provider (like OpenAI or local Ollama).
            """
        }
        
        // 2. Specific Interception: OpenAI 429 Quota Error
        if status == 429 && lowerBody.contains("openai") {
            return "⚠️ OpenAI API Quota Exceeded. Please check your billing details and account balance at https://platform.openai.com."
        }
        
        // 3. General JSON Error Extraction (prevents dumping huge raw JSON strings into the UI)
        if let data = body.data(using: .utf8),
           let json = try? JSONSerialization.jsonObject(with: data) {
            
            // Google's array-wrapped error format: [{"error": {"message": "..."}}]
            if let array = json as? [[String: Any]],
               let first = array.first,
               let errorObj = first["error"] as? [String: Any],
               let msg = errorObj["message"] as? String {
                 return "API Error (\(status)): \(msg)"
            }
            
            // Standard API error format: {"error": {"message": "..."}}
            if let dict = json as? [String: Any] {
                if let errorObj = dict["error"] as? [String: Any],
                   let msg = errorObj["message"] as? String {
                     return "API Error (\(status)): \(msg)"
                }
                if let msg = dict["error"] as? String {
                     return "API Error (\(status)): \(msg)"
                }
            }
        }
        
        // 4. Fallback for unparseable or unknown errors
        let truncatedBody = body.count > 300 ? String(body.prefix(300)) + "..." : body
        return "HTTP \(status): \(truncatedBody)"
    }
}
