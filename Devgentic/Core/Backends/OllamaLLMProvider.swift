// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2026 Raj Singh
//
//  OllamaLLMProvider.swift
//  Devgentic
//
//  Created by Raj Singh on 09/03/26.
//

import Foundation
import OSLog

private let logger = DGLogger(category: "OllamaLLMProvider")
private let logLLMOps = DGLogger(category: "LLMOps")

// MARK: - Ollama Provider

/// Handles local Ollama API interactions via POST /api/chat.
struct OllamaLLMProvider: LLMProvider {

    let config: LLMProviderConfig
    var modelName: String { config.modelName }

    init(config: LLMProviderConfig) {
        self.config = config
    }

    func generate(messages: [[String: String]], tools: [[String: Any]]?, responseSchema: Any?) async throws -> String {
        // Upcast to [[String: Any]] and delegate — text-only, behaviour-identical.
        try await postChat(messages: messages.map { $0 as [String: Any] }, tools: tools, responseSchema: responseSchema).text
    }

    func generateWithUsage(messages: [[String: String]], tools: [[String: Any]]?, responseSchema: Any?) async throws -> (text: String, usage: TokenUsage?) {
        try await postChat(messages: messages.map { $0 as [String: Any] }, tools: tools, responseSchema: responseSchema)
    }

    /// Multimodal (vision) bot path. Overrides the protocol default — which would
    /// strip images via `toLegacyDict()` — to attach each message's images as
    /// Ollama's per-message `images` array of RAW base64 strings (no `data:` prefix,
    /// per /api/chat). Text-only payloads produce the same body as the legacy path.
    func generate(payload: [ProviderMessage], tools: [[String: Any]]?, responseSchema: Any?) async throws -> String {
        var messages: [[String: Any]] = []
        for pm in payload {
            var msg: [String: Any] = ["role": pm.role, "content": pm.content.textContent]
            var images: [String] = []
            for block in pm.content {
                if case .image(let img) = block {
                    // resolve() throws on a missing/unreadable image → surfaced, not dropped.
                    images.append(try await img.reference.resolve().base64EncodedString())
                }
            }
            if !images.isEmpty { msg["images"] = images }
            messages.append(msg)
        }
        return try await postChat(messages: messages, tools: tools, responseSchema: responseSchema).text
    }

    /// Shared POST `/api/chat` (non-streaming) → extracted assistant content string.
    /// Accepts `[[String: Any]]` so callers can attach per-message `images` arrays.
    private func postChat(messages: [[String: Any]], tools: [[String: Any]]?, responseSchema: Any?) async throws -> (text: String, usage: TokenUsage?) {
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

        let (data, httpResponse) = try await CloudRequestPipeline.executeLocal(
            request: request, rateLimitKey: config.rateLimitKey
        )

        guard (200...299).contains(httpResponse.statusCode) else {
            let errorBody = String(data: data, encoding: .utf8) ?? "Unknown error"
            throw LLMProviderError.httpError(httpResponse.statusCode, errorBody)
        }

        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        guard let message = json?["message"] as? [String: Any] else {
            throw LLMProviderError.invalidResponse("Missing message object in Ollama response")
        }

        let content = message["content"] as? String ?? ""
        return (content, json.flatMap { TokenUsage.fromOllama($0) })
    }

    func generateCognitiveStep(messages: [[String: String]], tools: [[String: Any]]?) async throws -> ModernCognitiveStep {
        // Upcast to [[String: Any]] so the shared dispatch path can treat legacy and
        // native messages uniformly. String values are valid Any values; no data loss.
        let upcast: [[String: Any]] = messages.map { $0 as [String: Any] }
        let body = buildCognitiveBody(messages: upcast, tools: tools)
        return try await dispatchCognitiveRequest(body: body)
    }

    /// Native-turn overload. Accepts provider-shape messages carrying structural
    /// tool_calls / tool role entries produced by `OllamaToolTurnAdapter`. Shares the
    /// dispatch + response parsing logic with the legacy path via `dispatchCognitiveRequest`.
    func generateCognitiveStep(nativeMessages: [[String: Any]], tools: [[String: Any]]?) async throws -> ModernCognitiveStep {
        let body = buildCognitiveBody(messages: nativeMessages, tools: tools)
        return try await dispatchCognitiveRequest(body: body)
    }

    // MARK: - Body Construction

    /// Assembles the /api/chat body. Messages typed as `[[String: Any]]` preserves
    /// nested structural content (tool_calls arrays, tool call arguments dicts)
    /// across the Swift type system — Any-erasure through a generic parameter was
    /// observed to stringify nested arrays on some code paths.
    private func buildCognitiveBody(messages: [[String: Any]], tools: [[String: Any]]?) -> [String: Any] {
        var body: [String: Any] = [
            "model": config.modelName,
            "messages": messages,
            "stream": false
        ]

        // Extended thinking — driven by ProviderConfig.thinkingEnabled (seeded by detection).
        // If enabled but the model doesn't actually support it, Ollama returns HTTP 400
        // which we translate to `LLMProviderError.thinkingUnsupported` below for auto-heal.
        if config.thinkingEnabled {
            body["think"] = true
        }

        if let options = config.options {
            body["options"] = mapToOllamaOptions(options)
        }

        if let tools = tools, !tools.isEmpty {
            body["tools"] = tools
        }

        return body
    }

    /// Sends the /api/chat POST, emits G12 instrumentation, and parses the response
    /// into a `ModernCognitiveStep`. Shared between legacy and native-turn paths so
    /// both benefit from the same error handling, thinking-unsupported auto-heal, and
    /// KV-cache-miss proxy metrics.
    private func dispatchCognitiveRequest(body: [String: Any]) async throws -> ModernCognitiveStep {
        let url = config.baseURL.appendingPathComponent("api/chat")
        var request = URLRequest(url: url, timeoutInterval: config.timeout)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        let requestBodyBytes = request.httpBody?.count ?? 0

        let httpStart = Date()
        let (data, httpResponse) = try await CloudRequestPipeline.executeLocal(
            request: request, rateLimitKey: config.rateLimitKey
        )
        let httpWallDuration = Date().timeIntervalSince(httpStart)

        guard (200...299).contains(httpResponse.statusCode) else {
            let bodyStr = String(data: data, encoding: .utf8) ?? "Unknown error"
            let status = httpResponse.statusCode

            // Detect the specific "does not support thinking" 400 so the caller can auto-heal.
            if status == 400 && bodyStr.lowercased().contains("does not support thinking") {
                throw LLMProviderError.thinkingUnsupported(modelName: config.modelName)
            }

            // Detect "does not support tools" 400. Reasoning-only models (deepseek-r1 family,
            // o1-likes) are rejected at the Ollama server layer before the model runs.
            // The retry strategy aborts immediately on this — no amount of format correction
            // fixes a capability gap.
            if status == 400 && bodyStr.lowercased().contains("does not support tools") {
                throw LLMProviderError.toolsUnsupported(modelName: config.modelName)
            }

            throw LLMProviderError.httpError(status, bodyStr)
        }

        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]

        // G12 instrumentation: KV-cache-miss proxy. If prompt_eval_count on iter 2+ is
        // close to full prompt length, cache is being invalidated every iter; if it's
        // close to the last-turn delta, cache is hitting the prior prefix.
        let promptEvalCount = json?["prompt_eval_count"] as? Int ?? 0
        let promptEvalMs = Double((json?["prompt_eval_duration"] as? Int) ?? 0) / 1_000_000.0
        let evalCount = json?["eval_count"] as? Int ?? 0
        let evalMs = Double((json?["eval_duration"] as? Int) ?? 0) / 1_000_000.0
        let totalMs = Double((json?["total_duration"] as? Int) ?? 0) / 1_000_000.0
        logLLMOps.info("📊 [Ollama:\(config.modelName)] req=\(requestBodyBytes)B wall=\(String(format: "%.2f", httpWallDuration))s | prompt_eval=\(promptEvalCount)tok/\(String(format: "%.0f", promptEvalMs))ms | eval=\(evalCount)tok/\(String(format: "%.0f", evalMs))ms | total=\(String(format: "%.0f", totalMs))ms")

        guard let message = json?["message"] as? [String: Any] else {
            throw LLMProviderError.invalidResponse("Missing message object in Ollama response")
        }

        let content = message["content"] as? String ?? ""
        let thinking = message["thinking"] as? String // Capture raw thinking trace if provided separately
        var pendingTools: [PendingToolCall] = []

        // --- Raw-response diagnostic logging ---
        // Captures what Ollama actually returned so parse regressions can be diagnosed
        // without attaching a debugger. Content preview is capped at 1KB; tool_calls
        // are logged in full (usually small). Thinking presence only, not body.
        // Both summary AND content are at .info level so they appear in release logs —
        // the content body is the single most useful signal when diagnosing why a
        // particular model's output didn't parse into a tool call.
        let rawToolCalls = message["tool_calls"] as? [[String: Any]]
        let contentPreview = content.count > 1000 ? String(content.prefix(1000)) + "…[+\(content.count - 1000) chars]" : content
        logLLMOps.info("📥 [Ollama:raw] content=\(content.count)B | tool_calls=\(rawToolCalls?.count ?? 0) | thinking=\(thinking != nil)")
        logLLMOps.info("📥 [Ollama:content] \(contentPreview)")
        if let toolCalls = rawToolCalls, !toolCalls.isEmpty {
            logLLMOps.info("📥 [Ollama:tool_calls] \(toolCalls)")
        }

        if let toolCalls = rawToolCalls {
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
        // field (format leakage on e.g. qwen-coder whose trained format doesn't map
        // cleanly onto Ollama's OpenAI-style wrapper). Pipe through the cascade pipeline
        // to recover them. (G7 fix) Split prose-before-JSON from the JSON block so the
        // agent's reasoning is preserved instead of discarded by the parser.
        //
        // Tool-name resolution happens one level up: this step's result is
        // re-validated by NativeParsePipeline (ToolNameResolver with the real
        // registry) inside NativeStructuredGenerator. The explicit empty registry
        // is therefore CORRECT — this pipeline only parses and classifies; the
        // provider-format tool dicts in scope would be the wrong type anyway.
        if pendingTools.isEmpty && !content.isEmpty {
            let (prose, jsonBlock) = Self.splitProseAndJSON(content)
            let pipeline = CognitiveParsePipeline(
                expectedDialect: .nativeJSON,
                modelId: config.modelName,
                registeredTools: []
            )
            let parsed = pipeline.parse(raw: jsonBlock.isEmpty ? content : jsonBlock)

            // Prefer the captured prose prefix; fall back to the parser's reasoning
            // only if that parser found a real (non-placeholder) reasoning field.
            // Placeholder strings like "Executing..." are filtered downstream.
            let reasoning = prose.isEmpty ? parsed.reasoning : prose
            let usage = json.flatMap { TokenUsage.fromOllama($0) }
            return ModernCognitiveStep(
                reasoning: reasoning,
                thought: thinking,               // preserve Ollama's separate thinking channel
                toolCalls: parsed.toolCalls,
                tokenUsage: usage ?? parsed.tokenUsage,
                parseOutcome: parsed.parseOutcome  // forward pipeline's verdict (.success / .failed / .genuineCompletion)
            )
        }

        // Extract token usage from Ollama API response
        let usage = json.flatMap { TokenUsage.fromOllama($0) }

        // Empty reasoning stays empty — the UI derives "Executing <tool>..." labels from
        // .toolCall events, not from this field. (G7 / reasoning refactor)
        return ModernCognitiveStep(reasoning: content, thought: thinking, toolCalls: pendingTools, tokenUsage: usage)
    }

    // MARK: - Content-Leak Helpers (G7)

    /// Splits a content string that mixes prose and a bare tool-call JSON into
    /// `(prose, jsonBlock)`. Walks the string once with brace-depth tracking to
    /// find the first balanced top-level `{...}` or `[...]` block; everything
    /// before that block is returned as prose, the block itself as jsonBlock.
    ///
    /// Strips orphan markdown code fences (```json opener, ``` closer) from the
    /// returned prose — those are wrapping syntax, not reasoning text, and
    /// leaking them into `step.reasoning` shows up in the UI as `Model
    /// Reasoning: ```json` which is nonsense.
    ///
    /// If no balanced JSON block is found, returns `(content, "")` so callers
    /// can fall back to passing the original content to the parser.
    static func splitProseAndJSON(_ content: String) -> (prose: String, jsonBlock: String) {
        // String/escape-aware balanced-block split (#15). Replaces the old `prevChar != "\\"`
        // scan, which mishandled `\\"` — an escaped backslash before a real closing quote.
        let (proseSlice, blockSlice) = BalancedJSONScanner.splitProseAndBlock(in: content)
        guard let block = blockSlice else {
            return (stripOrphanFences(content.trimmingCharacters(in: .whitespacesAndNewlines)), "")
        }
        let prose = String(proseSlice).trimmingCharacters(in: .whitespacesAndNewlines)
        return (stripOrphanFences(prose), String(block))
    }

    /// Removes a leading ` ```json `/` ``` ` opener and trailing ` ``` ` closer
    /// when they frame the string as wrapping syntax. Real reasoning that
    /// happens to mention backticks inside the prose is preserved — the
    /// anchored regex only matches at string boundaries.
    private static func stripOrphanFences(_ prose: String) -> String {
        var result = prose
        result = result.replacingOccurrences(
            of: #"^```(?:[a-zA-Z0-9_-]+)?\s*"#,
            with: "",
            options: .regularExpression
        )
        result = result.replacingOccurrences(
            of: #"```\s*$"#,
            with: "",
            options: .regularExpression
        )
        return result.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func stream(messages: [[String: String]], tools: [[String: Any]]?) -> AsyncThrowingStream<String, Error> {
        streamWithUsage(messages: messages, tools: tools, onUsage: nil)
    }

    func streamWithUsage(messages: [[String: String]], tools: [[String: Any]]?, onUsage: (@Sendable (TokenUsage) -> Void)?) -> AsyncThrowingStream<String, Error> {
        // Ollama streams newline-delimited JSON (not SSE). The shared transport owns the
        // read loop, cancellation, and stall timeout (#13); the local rate-limit gate is
        // applied by CloudRequestPipeline.executeLocalStream (#12).
        SSEStreamParser.stream(
            openBytes: {
                let url = self.config.baseURL.appendingPathComponent("api/chat")
                var request = URLRequest(url: url, timeoutInterval: self.config.timeout)
                request.httpMethod = "POST"
                request.setValue("application/json", forHTTPHeaderField: "Content-Type")

                var body: [String: Any] = [
                    "model": self.config.modelName,
                    "messages": messages,
                    "stream": true
                ]
                if let options = self.config.options {
                    body["options"] = self.mapToOllamaOptions(options)
                }
                // `tools` are ignored on the bot stream (strictly conversational, like
                // the cloud providers) — tool-calling is the agent path.
                request.httpBody = try JSONSerialization.data(withJSONObject: body)

                let (bytes, httpResponse) = try await CloudRequestPipeline.executeLocalStream(
                    request: request, rateLimitKey: self.config.rateLimitKey
                )
                guard (200...299).contains(httpResponse.statusCode) else {
                    throw LLMProviderError.httpError(httpResponse.statusCode, "Ollama streaming error")
                }
                return bytes
            },
            onUsage: onUsage,
            extractUsage: { line, _ in
                guard let data = line.data(using: .utf8),
                      let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                      (json["done"] as? Bool) == true else { return nil }
                return TokenUsage.fromOllama(json)
            },
            handleLine: { line, _ in
                guard !line.isEmpty,
                      let lineData = line.data(using: .utf8),
                      let json = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any] else {
                    return .skip
                }
                let content = (json["message"] as? [String: Any])?["content"] as? String ?? ""
                let done = (json["done"] as? Bool) ?? false
                if done {
                    return content.isEmpty ? .finish : .emitThenFinish(content)
                }
                return content.isEmpty ? .skip : .emit(content)
            }
        )
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
