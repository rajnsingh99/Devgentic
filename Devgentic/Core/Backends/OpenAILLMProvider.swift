//
//  OpenAILLMProvider.swift
//  Devgentic
//
//  Created by Raj Singh on 09/03/26.
//


import Foundation
import OSLog

private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "com.devgentic.app", category: "OpenAILLMProvider")

// MARK: - OpenAI-Compatible Provider

/// Handles OpenAI, Gemini (via compatible endpoint), and any OpenAI-compatible API.
/// Supports structured output via the `response_format` parameter.
struct OpenAILLMProvider: LLMProvider {

    let config: LLMProviderConfig
    var modelName: String { config.modelName }

    init(config: LLMProviderConfig) {
        self.config = config
    }

    func generate(messages: [[String: String]], tools: [[String: Any]]?, responseSchema: Any?) async throws -> String {
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
        if let schema = responseSchema as? [String: Any] {
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
        return content
    }

    func generateCognitiveStep(messages: [[String: String]], tools: [[String: Any]]?) async throws -> ModernCognitiveStep {
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

        // --- NATIVE REASONING CONFIGURATION ---
        // For OpenAI o1/o3 models that support adjusted reasoning depth.
        if let options = config.options, let effort = options["reasoning_effort"] {
            if case .string(let effortStr) = effort {
                body["reasoning_effort"] = effortStr
            }
        }

        if let tools = tools, !tools.isEmpty {
            body["tools"] = tools
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
        let reasoningContent = message["reasoning_content"] as? String // Capture OpenAI's internal reasoning trace
        var pendingTools: [PendingToolCall] = []

        if let toolCalls = message["tool_calls"] as? [[String: Any]] {
            for toolCall in toolCalls {
                if let function = toolCall["function"] as? [String: Any],
                   let toolName = function["name"] as? String {
                    
                    let id = toolCall["id"] as? String ?? UUID().uuidString
                    var argumentsDict: [String: AnyCodable] = [:]
                    
                    if let argsAsString = function["arguments"] as? String,
                       let parsedDict = (try? JSONSerialization.jsonObject(with: argsAsString.data(using: .utf8) ?? Data())) as? [String: Any] {
                        argumentsDict = parsedDict.mapValues { AnyCodable($0) }
                    } else if let argsAsDict = function["arguments"] as? [String: Any] {
                        argumentsDict = argsAsDict.mapValues { AnyCodable($0) }
                    }
                    
                    pendingTools.append(PendingToolCall(id: id, name: toolName, arguments: argumentsDict))
                }
            }
        }

        let finalReasoning = content.isEmpty && !pendingTools.isEmpty
            ? "Executing \(pendingTools.count) tools..."
            : content

        return ModernCognitiveStep(reasoning: finalReasoning, thought: reasoningContent, toolCalls: pendingTools)
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
