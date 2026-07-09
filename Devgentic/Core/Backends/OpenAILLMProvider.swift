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
    /// Rate-limit category the pipeline meters and attributes errors under.
    /// `.openAI` for OpenAI proper; `.openRouter` when this provider serves an
    /// OpenAI-compatible OpenRouter profile.
    let providerCategory: RateLimitCategory
    var modelName: String { config.modelName }

    init(config: LLMProviderConfig, providerCategory: RateLimitCategory = .openAI) {
        self.config = config
        self.providerCategory = providerCategory
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
        for (header, value) in config.extraHeaders {
            request.setValue(value, forHTTPHeaderField: header)
        }
        return request
    }

    // MARK: - Generate

    func generate(messages: [[String: String]], tools: [[String: Any]]?, responseSchema: Any?) async throws -> String {
        try await generateWithUsage(messages: messages, tools: tools, responseSchema: responseSchema).text
    }

    func generateWithUsage(messages: [[String: String]], tools: [[String: Any]]?, responseSchema: Any?) async throws -> (text: String, usage: TokenUsage?) {
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

        let (data, _) = try await CloudRequestPipeline.execute(request: request, provider: providerCategory, rateLimitKey: config.rateLimitKey)

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
        return (content, json.flatMap { TokenUsage.fromOpenAI($0) })
    }

    // MARK: - Multimodal (Phase 3 — native image input)

    /// Translates `[ProviderMessage]` into OpenAI chat messages, emitting a content
    /// array (`{"type":"text"…}` + `{"type":"image_url","image_url":{"url":"data:…;base64,…"}}`)
    /// for any image blocks. Text-only messages keep a plain content string.
    private func translateProviderMessagesOpenAI(_ payload: [ProviderMessage]) async throws -> [[String: Any]] {
        var out: [[String: Any]] = []
        for msg in payload {
            if msg.content.isTextOnly {
                out.append(["role": msg.role, "content": msg.content.textContent])
                continue
            }
            let content = try await MultimodalTranslator.translateBlocks(
                msg.content,
                text: { ["type": "text", "text": $0] as [String: Any] },
                image: { mimeType, base64 in
                    ["type": "image_url",
                     "image_url": ["url": "data:\(mimeType);base64,\(base64)"]] as [String: Any]
                }
            )
            out.append(["role": msg.role, "content": content])
        }
        return out
    }

    /// Multimodal overload — serializes image blocks natively instead of the
    /// default text-downgrade. Mirrors `generate(messages:)` otherwise.
    func generate(payload: [ProviderMessage], tools: [[String: Any]]?, responseSchema: Any?) async throws -> String {
        let openAIMessages = try await translateProviderMessagesOpenAI(payload)
        var body: [String: Any] = [
            "model": config.modelName,
            "messages": openAIMessages,
            "stream": false
        ]
        applyGenerationParams(to: &body)
        if let tools = tools, !tools.isEmpty { body["tools"] = tools }
        if let schema = responseSchema as? [String: Any] {
            body["response_format"] = [
                "type": "json_schema",
                "json_schema": ["name": "cognitive_step", "strict": true, "schema": schema] as [String: Any]
            ] as [String: Any]
        }

        var request = makeRequest()
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, _) = try await CloudRequestPipeline.execute(request: request, provider: providerCategory, rateLimitKey: config.rateLimitKey)

        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        guard let choices = json?["choices"] as? [[String: Any]],
              let firstChoice = choices.first,
              let message = firstChoice["message"] as? [String: Any] else {
            throw LLMProviderError.invalidResponse("Missing message object in OpenAI response")
        }
        if let finishReason = firstChoice["finish_reason"] as? String, finishReason == "length" {
            logger.warning("⚠️ OpenAI multimodal response truncated (finish_reason: length).")
        }
        return message["content"] as? String ?? ""
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

        let (data, _) = try await CloudRequestPipeline.execute(request: request, provider: providerCategory, rateLimitKey: config.rateLimitKey)

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

        let (data, _) = try await CloudRequestPipeline.execute(request: request, provider: providerCategory, rateLimitKey: config.rateLimitKey)

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
        streamWithUsage(messages: messages, tools: tools, onUsage: nil)
    }

    func streamWithUsage(messages: [[String: String]], tools: [[String: Any]]?, onUsage: (@Sendable (TokenUsage) -> Void)?) -> AsyncThrowingStream<String, Error> {
        // Transport (read loop, cancellation, stall timeout) is owned by SSEStreamParser.
        SSEStreamParser.stream(
            openBytes: {
                var body: [String: Any] = [
                    "model": self.config.modelName,
                    "messages": messages,
                    "stream": true,
                    // Ask the API to append a terminal usage-only chunk so real token
                    // counts are available on the stream (#10b). Harmless when ignored.
                    "stream_options": ["include_usage": true]
                ]
                self.applyGenerationParams(to: &body)
                // `tools` are ignored on the bot stream (strictly conversational, like
                // Claude/Gemini) — tool-calling is the agent path, and the stream decode
                // only surfaces text deltas anyway.

                var request = self.makeRequest()
                request.httpBody = try JSONSerialization.data(withJSONObject: body)

                let (bytes, _) = try await CloudRequestPipeline.executeStream(
                    request: request, provider: self.providerCategory, rateLimitKey: self.config.rateLimitKey
                )
                return bytes
            },
            onUsage: onUsage,
            extractUsage: { line, _ in
                guard line.hasPrefix("data: ") else { return nil }
                let payload = String(line.dropFirst(6))
                guard payload != "[DONE]",
                      let data = payload.data(using: .utf8),
                      let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
                // `usage` is present only on the terminal include_usage chunk.
                return TokenUsage.fromOpenAI(json)
            },
            handleLine: { line, _ in
                guard line.hasPrefix("data: ") else { return .skip }
                let payload = String(line.dropFirst(6))

                if payload == "[DONE]" { return .finish }

                guard let chunkData = payload.data(using: .utf8),
                      let chunk = try? JSONSerialization.jsonObject(with: chunkData) as? [String: Any],
                      let choices = chunk["choices"] as? [[String: Any]],
                      let delta = choices.first?["delta"] as? [String: Any],
                      let content = delta["content"] as? String else {
                    return .skip
                }
                return .emit(content)
            }
        )
    }
}
