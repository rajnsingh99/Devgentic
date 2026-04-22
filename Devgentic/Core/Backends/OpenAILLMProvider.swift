//
//  OpenAILLMProvider.swift
//  Devgentic
//
//  Created by Raj Singh on 09/03/26.
//  Updated on 27/03/26: Config-driven parameters, CloudRequestPipeline integration,
//  and removed duplicated HTTP validation code.
//

import Foundation
import OSLog

private let logger = DGLogger(category: "OpenAILLMProvider")

// MARK: - OpenAI-Compatible Provider

/// Handles OpenAI and any OpenAI-compatible API.
/// Supports structured output via the `response_format` parameter.
struct OpenAILLMProvider: LLMProvider {

    let config: LLMProviderConfig
    var modelName: String { config.modelName }

    init(config: LLMProviderConfig) {
        self.config = config
    }

    // MARK: - Config-Driven Computed Properties

    private var maxTokens: Int? {
        if case .number(let val) = config.options?["maxTokens"] {
            let intVal = Int(val)
            return intVal > 0 ? intVal : nil // 0 means "model decides"
        }
        return nil
    }

    private var temperature: Double? {
        if case .number(let val) = config.options?["temperature"] { return val }
        return nil
    }

    private var topP: Double? {
        if case .number(let val) = config.options?["topP"] { return val }
        return nil
    }

    private var stopSequences: [String]? {
        if case .array(let arr) = config.options?["stopSequences"] {
            return arr.compactMap { if case .string(let s) = $0 { return s } else { return nil } }
        }
        return nil
    }

    private var reasoningEffort: String? {
        if case .string(let val) = config.options?["reasoningEffort"], !val.isEmpty { return val }
        return nil
    }

    /// Applies common generation parameters to the request body.
    private func applyGenerationParams(to body: inout [String: Any]) {
        if let maxTokens = maxTokens { body["max_tokens"] = maxTokens }
        if let temp = temperature { body["temperature"] = temp }
        if let topP = topP { body["top_p"] = topP }
        if let stops = stopSequences, !stops.isEmpty { body["stop"] = stops }
        if let effort = reasoningEffort { body["reasoning_effort"] = effort }
    }

    /// Creates a standard OpenAI URLRequest with proper headers.
    private func makeRequest() -> URLRequest {
        let url = config.baseURL.appendingPathComponent("chat/completions")
        var request = URLRequest(url: url, timeoutInterval: config.timeout)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        if let apiKey = config.apiKey {
            request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        }
        return request
    }

    // MARK: - Generate

    func generate(messages: [[String: String]], tools: [[String: Any]]?, responseSchema: Any?) async throws -> String {
        var body: [String: Any] = [
            "model": config.modelName,
            "messages": messages,
            "stream": false
        ]

        applyGenerationParams(to: &body)

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

        var request = makeRequest()
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, _) = try await CloudRequestPipeline.execute(request: request, provider: .openAI, rateLimitKey: config.rateLimitKey)

        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        guard let choices = json?["choices"] as? [[String: Any]],
              let firstChoice = choices.first,
              let message = firstChoice["message"] as? [String: Any] else {
            throw LLMProviderError.invalidResponse("Missing message object in OpenAI response")
        }

        // Defensive check: warn if response was truncated by token limit
        if let finishReason = firstChoice["finish_reason"] as? String, finishReason == "length" {
            let limitDesc = maxTokens.map { String($0) } ?? "model default"
            logger.warning("⚠️ OpenAI response truncated (finish_reason: length). Configured max_tokens: \(limitDesc). Output may be incomplete — consider increasing maxTokens in advanced config.")
        }

        let content = message["content"] as? String ?? ""
        return content
    }

    // MARK: - Cognitive Step

    func generateCognitiveStep(messages: [[String: String]], tools: [[String: Any]]?) async throws -> ModernCognitiveStep {
        var body: [String: Any] = [
            "model": config.modelName,
            "messages": messages,
            "stream": false
        ]

        applyGenerationParams(to: &body)

        if let tools = tools, !tools.isEmpty {
            body["tools"] = tools
        }

        var request = makeRequest()
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, _) = try await CloudRequestPipeline.execute(request: request, provider: .openAI, rateLimitKey: config.rateLimitKey)

        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        guard let choices = json?["choices"] as? [[String: Any]],
              let firstChoice = choices.first,
              let message = firstChoice["message"] as? [String: Any] else {
            throw LLMProviderError.invalidResponse("Missing message object in OpenAI response")
        }

        // Defensive check: warn if response was truncated by token limit
        if let finishReason = firstChoice["finish_reason"] as? String, finishReason == "length" {
            let limitDesc = maxTokens.map { String($0) } ?? "model default"
            logger.warning("⚠️ OpenAI cognitive step truncated (finish_reason: length). Configured max_tokens: \(limitDesc). Tool calls may have been cut off — consider increasing maxTokens in advanced config.")
        }

        let content = message["content"] as? String ?? ""
        let reasoningContent = message["reasoning_content"] as? String
        var pendingTools: [PendingToolCall] = []

        if let toolCalls = message["tool_calls"] as? [[String: Any]] {
            for toolCall in toolCalls {
                if let function = toolCall["function"] as? [String: Any],
                   let toolName = function["name"] as? String {

                    let id = toolCall["id"] as? String ?? UUID().uuidString
                    var argumentsDict: [String: JSONValue] = [:]

                    if let argsAsString = function["arguments"] as? String,
                       let parsedDict = (try? JSONSerialization.jsonObject(with: argsAsString.data(using: .utf8) ?? Data())) as? [String: Any] {
                        argumentsDict = parsedDict.reduce(into: [String: JSONValue]()) { result, pair in result[pair.key] = JSONValue(pair.value) ?? .null }
                    } else if let argsAsDict = function["arguments"] as? [String: Any] {
                        argumentsDict = argsAsDict.reduce(into: [String: JSONValue]()) { result, pair in result[pair.key] = JSONValue(pair.value) ?? .null }
                    }

                    pendingTools.append(PendingToolCall(id: id, name: toolName, arguments: argumentsDict))
                }
            }
        }

        // Empty reasoning stays empty — the UI derives "Executing <tool>..." labels from
        // .toolCall events, not from this field. A placeholder here would pollute any
        // future scratchpad injection with meaningless text. (G7 / reasoning refactor)
        // Extract token usage from OpenAI API response
        let usage = json.flatMap { TokenUsage.fromOpenAI($0) }

        return ModernCognitiveStep(reasoning: content, thought: reasoningContent, toolCalls: pendingTools, tokenUsage: usage)
    }

    // MARK: - Native-Turn Cognitive Step (G12)

    /// Native-turn overload. Accepts provider-shape messages carrying structural
    /// `tool_calls` / `tool` role entries produced by `OpenAIToolTurnAdapter`.
    /// OpenAI's message format is already the canonical shape, so the body is
    /// built identically to the legacy path — only the messages' Swift type differs.
    func generateCognitiveStep(nativeMessages: [[String: Any]], tools: [[String: Any]]?) async throws -> ModernCognitiveStep {
        var body: [String: Any] = [
            "model": config.modelName,
            "messages": nativeMessages,
            "stream": false
        ]

        applyGenerationParams(to: &body)

        if let tools = tools, !tools.isEmpty {
            body["tools"] = tools
        }

        var request = makeRequest()
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, _) = try await CloudRequestPipeline.execute(request: request, provider: .openAI, rateLimitKey: config.rateLimitKey)

        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        guard let choices = json?["choices"] as? [[String: Any]],
              let firstChoice = choices.first,
              let message = firstChoice["message"] as? [String: Any] else {
            throw LLMProviderError.invalidResponse("Missing message object in OpenAI response")
        }

        if let finishReason = firstChoice["finish_reason"] as? String, finishReason == "length" {
            let limitDesc = maxTokens.map { String($0) } ?? "model default"
            logger.warning("⚠️ OpenAI cognitive step truncated (finish_reason: length). Configured max_tokens: \(limitDesc).")
        }

        let content = message["content"] as? String ?? ""
        let reasoningContent = message["reasoning_content"] as? String
        var pendingTools: [PendingToolCall] = []

        if let toolCalls = message["tool_calls"] as? [[String: Any]] {
            for toolCall in toolCalls {
                if let function = toolCall["function"] as? [String: Any],
                   let toolName = function["name"] as? String {
                    let id = toolCall["id"] as? String ?? UUID().uuidString
                    var argumentsDict: [String: JSONValue] = [:]
                    if let argsAsString = function["arguments"] as? String,
                       let parsedDict = (try? JSONSerialization.jsonObject(with: argsAsString.data(using: .utf8) ?? Data())) as? [String: Any] {
                        argumentsDict = parsedDict.reduce(into: [String: JSONValue]()) { result, pair in result[pair.key] = JSONValue(pair.value) ?? .null }
                    } else if let argsAsDict = function["arguments"] as? [String: Any] {
                        argumentsDict = argsAsDict.reduce(into: [String: JSONValue]()) { result, pair in result[pair.key] = JSONValue(pair.value) ?? .null }
                    }
                    pendingTools.append(PendingToolCall(id: id, name: toolName, arguments: argumentsDict))
                }
            }
        }

        let usage = json.flatMap { TokenUsage.fromOpenAI($0) }
        return ModernCognitiveStep(reasoning: content, thought: reasoningContent, toolCalls: pendingTools, tokenUsage: usage)
    }

    // MARK: - Streaming

    func stream(messages: [[String: String]], tools: [[String: Any]]?) -> AsyncThrowingStream<String, Error> {
        return AsyncThrowingStream { continuation in
            Task {
                do {
                    var body: [String: Any] = [
                        "model": config.modelName,
                        "messages": messages,
                        "stream": true
                    ]

                    applyGenerationParams(to: &body)

                    if let tools = tools, !tools.isEmpty {
                        body["tools"] = tools
                    }

                    var request = makeRequest()
                    request.httpBody = try JSONSerialization.data(withJSONObject: body)

                    let (bytes, _) = try await CloudRequestPipeline.executeStream(request: request, provider: .openAI, rateLimitKey: config.rateLimitKey)

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
}
