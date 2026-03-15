//
//  OllamaLLMProvider.swift
//  Devgentic
//
//  Created by Raj Singh on 09/03/26.
//

import Foundation
import OSLog

private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "com.devgentic.app", category: "OllamaLLMProvider")

// MARK: - Ollama Provider

/// Handles local Ollama API interactions via POST /api/chat.
struct OllamaLLMProvider: LLMProvider {

    let config: LLMProviderConfig
    var modelName: String { config.modelName }

    init(config: LLMProviderConfig) {
        self.config = config
    }

    func generate(messages: [[String: String]], tools: [[String: Any]]?, responseSchema: Any?) async throws -> String {
        let url = config.baseURL.appendingPathComponent("api/chat")
        var request = URLRequest(url: url, timeoutInterval: config.timeout)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        var body: [String: Any] = [
            "model": config.modelName,
            "messages": messages,
            "stream": false
        ]

        if let options = config.options {
            body["options"] = mapToOllamaOptions(options)
        }

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
        return content
    }

    func generateCognitiveStep(messages: [[String: String]], tools: [[String: Any]]?) async throws -> ModernCognitiveStep {
        let url = config.baseURL.appendingPathComponent("api/chat")
        var request = URLRequest(url: url, timeoutInterval: config.timeout)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        var body: [String: Any] = [
            "model": config.modelName,
            "messages": messages,
            "stream": false,
            "think": true // Enable native thinking traces if supported by the model/version
        ]

        if let options = config.options {
            body["options"] = mapToOllamaOptions(options)
        }

        if let tools = tools, !tools.isEmpty {
            body["tools"] = tools
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
        let thinking = message["thinking"] as? String // Capture raw thinking trace if provided separately
        var pendingTools: [PendingToolCall] = []

        if let toolCalls = message["tool_calls"] as? [[String: Any]] {
            for toolCall in toolCalls {
                if let function = toolCall["function"] as? [String: Any],
                   let toolName = function["name"] as? String {
                   
                    let id = UUID().uuidString
                    var argumentsDict: [String: JSONValue] = [:]

                    if let argsAsDict = function["arguments"] as? [String: Any] {
                        argumentsDict = argsAsDict.reduce(into: [String: JSONValue]()) { result, pair in result[pair.key] = JSONValue(pair.value) ?? .null }
                    } else if let argsAsString = function["arguments"] as? String,
                              let parsedDict = (try? JSONSerialization.jsonObject(with: argsAsString.data(using: .utf8) ?? Data())) as? [String: Any] {
                        argumentsDict = parsedDict.reduce(into: [String: JSONValue]()) { result, pair in result[pair.key] = JSONValue(pair.value) ?? .null }
                    }
                    
                    pendingTools.append(PendingToolCall(id: id, name: toolName, arguments: argumentsDict))
                }
            }
        }

        // Dialect-Anchored Cascade fallback: when the model returned content but
        // no native tool_calls, the model may have leaked tool calls into the content
        // field (format leakage). Pipe through the cascade pipeline to recover them.
        if pendingTools.isEmpty && !content.isEmpty {
            let pipeline = CognitiveParsePipeline(
                expectedDialect: .nativeJSON,
                modelId: config.modelName
            )
            return pipeline.parse(raw: content)
        }

        let finalReasoning = content.isEmpty && !pendingTools.isEmpty
            ? "Executing \(pendingTools.count) tools..."
            : content

        return ModernCognitiveStep(reasoning: finalReasoning, thought: thinking, toolCalls: pendingTools)
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

                    if let options = config.options {
                        body["options"] = mapToOllamaOptions(options)
                    }

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
    
    private func mapToOllamaOptions(_ options: [String: JSONValue]) -> [String: Any] {
        var mapped: [String: Any] = [:]
        for (key, value) in options {
            let rawValue = value.rawValue
            switch key {
            case "numCtx": mapped["num_ctx"] = rawValue
            case "topP": mapped["top_p"] = rawValue
            case "topK": mapped["top_k"] = rawValue
            case "repeatPenalty": mapped["repeat_penalty"] = rawValue
            default: mapped[key] = rawValue
            }
        }
        return mapped
    }
}
