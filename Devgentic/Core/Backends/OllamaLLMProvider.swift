// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
//
//  OllamaLLMProvider.swift
//  Devgentic
//
//  Created by Raj Singh.
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

    /// Multimodal (vision) bot path: attaches each message's images as Ollama's per-message `images` array of raw base64
    /// strings (no `data:` prefix, per /api/chat). Overrides the protocol default, which strips images.
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
    /// This provider's engine, as the local-inference coordinator names it.
    private var inferenceEngine: InferenceEngine {
        .ollama(baseURL: InferenceEngine.normalizedOllamaURL(config.baseURL.absoluteString))
    }

    /// The `num_ctx` this request sends — Ollama reloads a model asked for with a different one.
    private var requestedContext: Int? {
        OllamaContextWindowPolicy.configuredNumCtx(in: config.options)
    }

    private func postChat(messages: [[String: Any]], tools: [[String: Any]]?, responseSchema: Any?) async throws -> (text: String, usage: TokenUsage?) {
        // The local-inference gate: holds (or waits for) the local lock and counts this generation.
        let generation = try await LocalInferenceScope.beginGeneration(engine: inferenceEngine, modelID: config.modelName,
                                                                       contextTokens: requestedContext)
        defer { generation.end() }
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
            body["options"] = Self.mapToOllamaOptions(options)
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

    /// Assembles the /api/chat body. Messages are `[[String: Any]]` to preserve nested structure (tool_calls arrays,
    /// argument dicts): Any-erasure through a generic parameter stringified nested arrays on some paths.
    private func buildCognitiveBody(messages: [[String: Any]], tools: [[String: Any]]?) -> [String: Any] {
        var body: [String: Any] = [
            "model": config.modelName,
            "messages": messages,
            "stream": false
        ]

        // Extended thinking, driven by `ProviderConfig.thinkingEnabled` (seeded by detection). If the model does not support it,
        // Ollama returns HTTP 400, translated below to `LLMProviderError.thinkingUnsupported` for auto-heal.
        if config.thinkingEnabled {
            body["think"] = true
        }

        if let options = config.options {
            body["options"] = Self.mapToOllamaOptions(options)
        }

        if let tools = tools, !tools.isEmpty {
            body["tools"] = tools
        }

        return body
    }

    /// Sends the /api/chat POST and parses the response into a `ModernCognitiveStep`.
    /// Shared by the legacy and native-turn paths: same error handling, thinking auto-heal and KV-cache-miss proxy metrics.
    private func dispatchCognitiveRequest(body: [String: Any]) async throws -> ModernCognitiveStep {
        let generation = try await LocalInferenceScope.beginGeneration(engine: inferenceEngine, modelID: config.modelName,
                                                                       contextTokens: requestedContext)
        defer { generation.end() }
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

            // Detect a "does not support tools" 400: reasoning-only models (deepseek-r1 family) are rejected before they run.
            // The retry strategy aborts immediately; format correction cannot fix a capability gap.
            if status == 400 && bodyStr.lowercased().contains("does not support tools") {
                throw LLMProviderError.toolsUnsupported(modelName: config.modelName)
            }

            throw LLMProviderError.httpError(status, bodyStr)
        }

        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]

        // KV-cache-miss proxy: `prompt_eval_count` on iteration 2+ near the full prompt length means the cache is invalidated,
        // near the last-turn delta means it hits the prior prefix.
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

        // Raw-response diagnostic logging: content preview capped at 1KB, tool_calls logged in full, thinking by presence only.
        // Summary and content log at `.info` so release logs show them; the content is the best signal for parse failures.
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

        // Why: the empty registry is correct and its `.failed` verdict provisional: NativeParsePipeline re-decides.
        // Content fallback: when the model returned content but no native tool_calls, calls may have leaked into the content
        // (e.g. qwen-coder); pipe it through the cascade to recover them, splitting prose from the JSON block.
        if pendingTools.isEmpty && !content.isEmpty {
            return Self.contentFallbackStep(
                content: content,
                thinking: thinking,
                usage: json.flatMap { TokenUsage.fromOllama($0) },
                modelName: config.modelName,
                toolNames: Self.declaredToolNames(in: body["tools"])
            )
        }

        // Extract token usage from Ollama API response
        let usage = json.flatMap { TokenUsage.fromOllama($0) }

        // Empty reasoning stays empty — the UI derives "Executing <tool>..." labels from
        // .toolCall events, not from this field. (G7 / reasoning refactor)
        return ModernCognitiveStep(reasoning: content, thought: thinking, toolCalls: pendingTools, tokenUsage: usage)
    }

    // MARK: - Content-Leak Helpers (G7)

    /// The function names in an Ollama `tools` array (`[{"type":"function","function":{"name":…}}]`).
    static func declaredToolNames(in tools: Any?) -> Set<String> {
        guard let tools = tools as? [[String: Any]] else { return [] }
        return Set(tools.compactMap { ($0["function"] as? [String: Any])?["name"] as? String })
    }

    /// The content-fallback step for a reply whose `tool_calls` were empty but whose `content` was not.
    /// `toolNames` are the tools offered (not a registry), so the cascade can recognise a leaked call by name, even cut off.
    static func contentFallbackStep(
        content: String,
        thinking: String?,
        usage: TokenUsage?,
        modelName: String,
        toolNames: Set<String> = []
    ) -> ModernCognitiveStep {
        // Split the visible text: on raw `content` the first balanced block can sit inside a `<think>` block, so a call the
        // model only considered would run. The cascade strips thinking itself, after this split.
        let visible = OutputSanitizer.stripThinkBlocks(content)
        let (prose, jsonBlock) = Self.splitProseAndJSON(visible)
        let pipeline = CognitiveParsePipeline(
            expectedDialect: .nativeJSON,
            modelId: modelName,
            knownToolNames: toolNames,
            registeredTools: []
        )
        let parsed = pipeline.parse(raw: jsonBlock.isEmpty ? content : jsonBlock)

        // Why: on a failed parse that recovered nothing, hand up the whole content: a prefix cut at the first `{` truncates answers.
        // Prefer the captured prose prefix; fall back to the parser's reasoning only if it found a real (non-placeholder) field.
        let reasoning: String = {
            if parsed.toolCalls.isEmpty, case .failed = parsed.parseOutcome { return content }
            return prose.isEmpty ? parsed.reasoning : prose
        }()
        return ModernCognitiveStep(
            reasoning: reasoning,
            thought: thinking,               // preserve Ollama's separate thinking channel
            toolCalls: parsed.toolCalls,
            tokenUsage: usage ?? parsed.tokenUsage,
            parseOutcome: parsed.parseOutcome,  // forward pipeline's verdict (.success / .failed / .genuineCompletion)
            // These calls were pulled out of text, not a structured channel. If none names a tool this run offers,
            // `NativeParsePipeline` asks whether the text is the answer and needs all of it, not the prose before the first brace.
            callsRecoveredFromText: parsed.toolCalls.isEmpty ? nil : visible
        )
    }

    /// Splits content mixing prose and a bare tool-call JSON into `(prose, jsonBlock)` at the first balanced top-level block.
    /// Strips orphan markdown fences from the prose; with no balanced block, returns `(content, "")`.
    static func splitProseAndJSON(_ content: String) -> (prose: String, jsonBlock: String) {
        // String/escape-aware balanced-block split, so an escaped backslash before a closing quote is handled correctly.
        let (proseSlice, blockSlice, tailSlice) = BalancedJSONScanner.splitProseAndBlock(in: content)
        guard let block = blockSlice else {
            return (stripOrphanFences(content.trimmingCharacters(in: .whitespacesAndNewlines)), "")
        }

        // The tail is rejoined, not dropped. The block itself is excluded: it is a leaked tool call, not the model's reasoning.
        let before = String(proseSlice).trimmingCharacters(in: .whitespacesAndNewlines)
        let after = String(tailSlice).trimmingCharacters(in: .whitespacesAndNewlines)
        let prose = [before, after].filter { !$0.isEmpty }.joined(separator: " ")
        return (stripOrphanFences(prose), String(block))
    }
    /// Removes a leading ```json / ``` opener and trailing ``` closer when they frame the string; the anchored regex
    /// matches only at string boundaries, so prose that mentions backticks is preserved.
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
        let engine = inferenceEngine
        let model = config.modelName
        let context = requestedContext
        let generation = LocalInferenceScope.GenerationSlot()
        // Ollama streams newline-delimited JSON (not SSE). The shared transport owns the read loop, cancellation and
        // stall timeout; the local rate-limit gate is applied by `CloudRequestPipeline.executeLocalStream`.
        return SSEStreamParser.stream(
            // Why: gate in `beforeOpen`, never `openBytes`: only `beforeOpen` pauses the stall watchdog a long wait would trip.
            // The local-inference gate, counted like every other generation: begun in `beforeOpen`, ended in `onClose`.
            // Runs in the transport's reader task, which inherits the run's task-locals.
            beforeOpen: {
                generation.hold(try await LocalInferenceScope.beginGeneration(engine: engine, modelID: model,
                                                                              contextTokens: context))
            },
            onClose: { generation.end() },
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
                    body["options"] = Self.mapToOllamaOptions(options)
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
            // Pass the decoder itself, not a closure around it, so tests exercise exactly this code.
            handleLine: Self.ollamaStreamLine
        )
    }
    
    /// One NDJSON line of an Ollama `/api/chat` stream.
    static func ollamaStreamLine(_ line: String, _ event: String) -> SSELineDirective {
        guard !line.isEmpty,
              let lineData = line.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any] else {
            return .skip
        }
        // Ollama reports a mid-stream failure as `{"error": "…"}` on a 200 response (runner crash, out of memory), with no
        // `message` or `done`; treat it as an error so a cut-off answer is not saved as a success.
        if let error = json["error"] as? String {
            logger.error("[OLLAMA] Server reported an error mid-response: \(error). CONSEQUENCE: the turn fails with that message instead of saving a truncated answer as a success.")
            return .fail(LLMProviderError.invalidResponse("Ollama reported an error mid-response: \(error)"))
        }
        let content = (json["message"] as? [String: Any])?["content"] as? String ?? ""
        let done = (json["done"] as? Bool) ?? false
        if done {
            return content.isEmpty ? .finish : .emitThenFinish(content)
        }
        return content.isEmpty ? .skip : .emit(content)
    }

    /// Maps this app's option keys onto Ollama's `options` object.
    /// `static` and pure so the mapping is testable; every `body["options"]` site calls it, so `stop` rules apply everywhere.
    static func mapToOllamaOptions(_ options: [String: JSONValue]) -> [String: Any] {
        var mapped: [String: Any] = [:]
        for (key, value) in options {
            let rawValue = value.rawValue
            switch key {
            case "numCtx": mapped["num_ctx"] = rawValue
            case "topP": mapped["top_p"] = rawValue
            case "topK": mapped["top_k"] = rawValue
            case "repeatPenalty": mapped["repeat_penalty"] = rawValue

            case "stop":
                // Why: only `stop` is verified to override when empty; the request log prints pre-mapping config, showing `stop: []`.
                // An empty stop list is omitted, never forwarded: an explicit `"stop": []` replaces the model's Modelfile stops.
                // Empty means the user has no stop sequences of their own, not "strip the model's".
                if let list = value.arrayValue, list.isEmpty { continue }
                mapped["stop"] = rawValue

            default: mapped[key] = rawValue
            }
        }
        return mapped
    }
}
