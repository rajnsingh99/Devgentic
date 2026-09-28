// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
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

    /// The request contract this model accepts (register A55).
    private var modelFamily: OpenAIModelFamily { OpenAIModelFamily.classify(modelName: config.modelName) }

    /// Applies common generation parameters to the request body, in the shape the selected model
    /// actually accepts.
    ///
    /// ⚠️ Register A55: this used to send one shape to everything — `max_tokens`, `temperature`,
    /// `top_p`, plus `reasoning_effort` whenever the picker had been touched. A reasoning model
    /// rejects `max_tokens` and a non-default `temperature`; a normal model rejects
    /// `reasoning_effort`. So the panel's own defaults 400'd on o-series, and setting Reasoning
    /// Effort 400'd everywhere else.
    ///
    /// ⚠️ Every parameter dropped here is LOGGED. Silently omitting a value the user set in the
    /// panel is how a knob becomes decorative without anyone noticing (registers A19/A24/A25).
    // Internal (not private) so tests can inspect the exact body shape without a network mock.
    func applyGenerationParams(to body: inout [String: Any]) {
        let family = modelFamily

        if let maxTokens = maxTokens {
            body[family.maxTokensParameterName] = maxTokens
        }

        if family.acceptsSamplingParameters {
            if let temp = temperature { body["temperature"] = temp }
            if let topP = topP { body["top_p"] = topP }
        } else if temperature != nil || topP != nil {
            logger.notice(
                "[PROFILE] Omitting temperature/top_p for reasoning model '\(config.modelName)'. "
                + "CONSEQUENCE: the request uses the model's fixed default sampling — sending them "
                + "is a 400 on this family, so the panel's values cannot be honoured here."
            )
        }

        if let stops = stopSequences, !stops.isEmpty { body["stop"] = stops }

        if let effort = reasoningEffort {
            if family.acceptsReasoningEffort {
                body["reasoning_effort"] = effort
            } else {
                logger.notice(
                    "[PROFILE] Omitting reasoning_effort '\(effort)' for non-reasoning model "
                    + "'\(config.modelName)'. CONSEQUENCE: the setting has no effect on this model, "
                    + "and sending it would fail the whole request — the picker is hidden for "
                    + "models that cannot use it, so this profile predates that gating."
                )
            }
        }

        // OpenRouter usage accounting: puts the request's `cost` in `usage` so it can be logged
        // alongside the generation id (see `logRouterMetadata`).
        if isOpenRouter {
            body["usage"] = ["include": true]
        }

        // OpenRouter provider routing. Only ever sent to OpenRouter: OpenAI and compatible
        // gateways share this config type, and an unknown top-level `provider` key is a 400 on
        // some of them.
        if denyDataCollection {
            if isOpenRouter {
                body["provider"] = ["data_collection": "deny"]
            } else {
                logger.notice("[PROFILE] Omitting provider.data_collection for non-OpenRouter endpoint (\(providerCategory.rawValue)). CONSEQUENCE: the setting only applies to OpenRouter.")
            }
        }
    }

    private var isOpenRouter: Bool { providerCategory == .openRouter || providerCategory == .openRouterFree }

    /// Logs which upstream served an OpenRouter request, its generation id and its cost.
    ///
    /// ⚠️ Without these a slow, failed or oddly-behaving OpenRouter call cannot be traced: the same
    /// model slug is served by several upstream providers, and the generation id is the only handle
    /// OpenRouter's own dashboard and `/api/v1/generation?id=` lookups accept.
    private func logRouterMetadata(_ json: [String: Any]?) {
        guard isOpenRouter, let json, let summary = Self.routerMetadataSummary(json) else { return }
        logger.info("[OPENROUTER] \(summary)")
    }

    /// The loggable summary of an OpenRouter response (or terminal stream chunk), or nil when it
    /// carries none of the fields. Pure so tests can pin the parsing.
    static func routerMetadataSummary(_ json: [String: Any]) -> String? {
        let id = json["id"] as? String
        let upstream = json["provider"] as? String
        let model = json["model"] as? String
        let usage = json["usage"] as? [String: Any]
        let cost = (usage?["cost"] as? NSNumber)?.doubleValue
        guard id != nil || upstream != nil || cost != nil else { return nil }

        var parts = ["generation: \(id ?? "?")", "upstream: \(upstream ?? "?")"]
        if let model { parts.append("model: \(model)") }
        if let prompt = (usage?["prompt_tokens"] as? NSNumber)?.intValue,
           let completion = (usage?["completion_tokens"] as? NSNumber)?.intValue {
            parts.append("tokens: \(prompt) in / \(completion) out")
        }
        if let cost { parts.append("cost: $" + String(format: "%.6f", cost)) }
        return parts.joined(separator: ", ")
    }

    /// An error object carried INSIDE a successful (HTTP 200) body or stream chunk, as a
    /// `CloudProviderError` so `ProviderErrorClassifier` treats it like the status it names.
    ///
    /// ⚠️ OpenRouter (and some gateways) report failures that happen after the response has started
    /// this way — `{"error": {"code": 502, "message": "..."}}`, sometimes beside a partial `choices`.
    /// Parsed as a normal response it became "Missing message object" (an invalid-response parse
    /// failure, retried as if the model had emitted bad JSON) or, streaming, a silent truncation.
    /// A code outside 4xx/5xx is treated as 502: the upstream failed, the request was fine.
    static func embeddedError(in json: [String: Any], provider: RateLimitCategory) -> CloudProviderError? {
        guard let error = json["error"] as? [String: Any] else { return nil }
        let rawCode = (error["code"] as? Int) ?? (error["code"] as? String).flatMap(Int.init)
        let status = rawCode.flatMap { (400...599).contains($0) ? $0 : nil } ?? 502
        let body = (try? JSONSerialization.data(withJSONObject: ["error": error]))
            .flatMap { String(data: $0, encoding: .utf8) } ?? "\(error)"
        return CloudProviderError(statusCode: status, retryAfterSeconds: nil,
                                  requestId: json["id"] as? String, rawBody: body, provider: provider)
    }

    /// Decodes one streamed `chat/completions` line. Static and pure so the error paths are testable
    /// without a network stream.
    static func streamLineDirective(_ line: String, provider: RateLimitCategory) -> SSELineDirective {
        guard line.hasPrefix("data: ") else { return .skip }
        let payload = String(line.dropFirst(6))

        if payload == "[DONE]" { return .finish }

        guard let chunkData = payload.data(using: .utf8),
              let chunk = try? JSONSerialization.jsonObject(with: chunkData) as? [String: Any] else {
            return .skip
        }

        // A failure after the 200 was sent arrives as an in-band error chunk (OpenRouter does this
        // when the upstream dies mid-generation). Skipping it — which this did — ended the stream
        // "cleanly" with a truncated answer that looked complete.
        if let embedded = embeddedError(in: chunk, provider: provider) {
            return .fail(embedded)
        }

        guard let choices = chunk["choices"] as? [[String: Any]],
              let delta = choices.first?["delta"] as? [String: Any],
              let content = delta["content"] as? String else {
            return .skip
        }
        return .emit(content)
    }

    /// The model's thinking trace. DeepSeek (and OpenAI-compatible servers copying it) use
    /// `reasoning_content`; OpenRouter normalises every upstream to `reasoning`. Only the first was
    /// read, so on OpenRouter the trace was silently dropped — the log showed "Model Reasoning:
    /// (none)" on every step of a reasoning model.
    static func reasoningTrace(in message: [String: Any]) -> String? {
        for key in ["reasoning_content", "reasoning"] {
            if let text = message[key] as? String, !text.isEmpty { return text }
        }
        return nil
    }

    /// OpenRouter's `reasoning_details` array, kept verbatim so it can be echoed back on this
    /// step's assistant turn (see `ModernCognitiveStep.reasoningReplay`).
    static func reasoningReplay(in message: [String: Any]) -> JSONValue? {
        guard let details = message["reasoning_details"] as? [Any], !details.isEmpty else { return nil }
        return JSONValue(details)
    }

    /// OpenRouter "Deny Data Collection" (per profile, off by default).
    private var denyDataCollection: Bool {
        if case .bool(true) = config.options?["denyDataCollection"] { return true }
        return false
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
        logRouterMetadata(json)
        if let json, let embedded = Self.embeddedError(in: json, provider: providerCategory) { throw embedded }
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
        logRouterMetadata(json)
        if let json, let embedded = Self.embeddedError(in: json, provider: providerCategory) { throw embedded }
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
        logRouterMetadata(json)
        if let json, let embedded = Self.embeddedError(in: json, provider: providerCategory) { throw embedded }
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
        let reasoningContent = Self.reasoningTrace(in: message)
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

        return ModernCognitiveStep(reasoning: content, thought: reasoningContent, toolCalls: pendingTools, tokenUsage: usage,
                                   reasoningReplay: Self.reasoningReplay(in: message))
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
        logRouterMetadata(json)
        if let json, let embedded = Self.embeddedError(in: json, provider: providerCategory) { throw embedded }
        guard let choices = json?["choices"] as? [[String: Any]],
              let firstChoice = choices.first,
              let message = firstChoice["message"] as? [String: Any] else {
            throw LLMProviderError.invalidResponse("Missing message object in OpenAI response")
        }

        if let finishReason = firstChoice["finish_reason"] as? String, finishReason == "length" {
            let limitDesc = maxTokens.map { String($0) } ?? "model default"
            logger.warning("⚠️ OpenAI cognitive step truncated (finish_reason: length). Configured max_tokens: \(limitDesc).")
        }

        return Self.step(fromMessage: message, usage: json.flatMap { TokenUsage.fromOpenAI($0) })
    }

    /// Builds a step from one `chat/completions` assistant message — the non-streaming response's
    /// `choices[0].message`, or the message `OpenAIStreamAccumulator` reassembles from a stream.
    /// One function so the two paths cannot disagree about tool-call or reasoning parsing.
    static func step(fromMessage message: [String: Any], usage: TokenUsage?) -> ModernCognitiveStep {
        let content = message["content"] as? String ?? ""
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

        return ModernCognitiveStep(reasoning: content, thought: reasoningTrace(in: message), toolCalls: pendingTools,
                                   tokenUsage: usage, reasoningReplay: reasoningReplay(in: message))
    }

    /// The native-turn step with the visible text streamed through `onTextDelta` (see the protocol).
    ///
    /// Same request as `generateCognitiveStep(nativeMessages:tools:)` plus `stream: true`; the
    /// chunks are reassembled by `OpenAIStreamAccumulator` into the message the non-streaming path
    /// would have received, and parsed by the same `step(fromMessage:usage:)`. Transport, Stop and
    /// the between-chunk stall watchdog come from `SSEStreamParser`; each `data:` payload is passed
    /// through verbatim and decoded here, and an in-band error chunk fails the step.
    func generateCognitiveStepStreaming(
        nativeMessages: [[String: Any]],
        tools: [[String: Any]]?,
        onTextDelta: @escaping @Sendable (String) -> Void
    ) async throws -> ModernCognitiveStep {
        var body: [String: Any] = [
            "model": config.modelName,
            "messages": nativeMessages,
            "stream": true,
            "stream_options": ["include_usage": true],
        ]
        applyGenerationParams(to: &body)
        if let tools = tools, !tools.isEmpty { body["tools"] = tools }
        let bodyData = try JSONSerialization.data(withJSONObject: body)

        let chunks = SSEStreamParser.stream(
            openBytes: {
                var request = self.makeRequest()
                request.httpBody = bodyData
                let (bytes, _) = try await CloudRequestPipeline.executeStream(
                    request: request, provider: self.providerCategory, rateLimitKey: self.config.rateLimitKey
                )
                return bytes
            },
            handleLine: { [providerCategory] line, _ in
                Self.rawChunkDirective(line, provider: providerCategory)
            }
        )

        var accumulator = OpenAIStreamAccumulator()
        let started = Date()
        var firstTextAfter: TimeInterval?
        var chunkCount = 0
        var textDeltaCount = 0
        for try await payload in chunks {
            guard let data = payload.data(using: .utf8),
                  let chunk = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { continue }
            chunkCount += 1
            if let delta = accumulator.consume(chunk), !delta.isEmpty {
                if firstTextAfter == nil { firstTextAfter = Date().timeIntervalSince(started) }
                textDeltaCount += 1
                onTextDelta(delta)
            }
        }
        // The one line that says whether the user SAW anything before the step ended: without it a
        // streamed step and a blocking one log identically ("Response received in 56s").
        logger.info("[STREAM] Step streamed: \(chunkCount) chunk(s), \(textDeltaCount) with visible text; first text after \(firstTextAfter.map { String(format: "%.1fs", $0) } ?? "never (tool calls / thinking only)"), total \(String(format: "%.1fs", Date().timeIntervalSince(started))).")

        if let usageChunk = accumulator.lastUsageChunk { logRouterMetadata(usageChunk) }
        if accumulator.finishReason == "length" {
            let limitDesc = maxTokens.map { String($0) } ?? "model default"
            logger.warning("⚠️ OpenAI streamed cognitive step truncated (finish_reason: length). Configured max_tokens: \(limitDesc).")
        }
        return Self.step(fromMessage: accumulator.message, usage: accumulator.lastUsageChunk.flatMap { TokenUsage.fromOpenAI($0) })
    }

    /// Like `streamLineDirective`, but hands each `data:` payload through WHOLE (as the emitted
    /// string) so the caller can read tool-call and reasoning deltas, not just text.
    static func rawChunkDirective(_ line: String, provider: RateLimitCategory) -> SSELineDirective {
        guard line.hasPrefix("data: ") else { return .skip }
        let payload = String(line.dropFirst(6))
        if payload == "[DONE]" { return .finish }
        if let data = payload.data(using: .utf8),
           let chunk = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let embedded = embeddedError(in: chunk, provider: provider) {
            return .fail(embedded)
        }
        return .emit(payload)
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
                if json["usage"] != nil { self.logRouterMetadata(json) }
                return TokenUsage.fromOpenAI(json)
            },
            handleLine: { [providerCategory] line, _ in
                Self.streamLineDirective(line, provider: providerCategory)
            }
        )
    }
}
