// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
//
//  GeminiLLMProvider.swift
//  Devgentic
//
//  Created by Raj Singh.
//

import Foundation
import OSLog

private let logger = DGLogger(category: "GeminiLLMProvider")

/// Handles the official Google Gemini API via REST.
/// Adapts Devgentic's standard message payloads to Gemini's unique `contents` and `parts` architecture.
struct GeminiLLMProvider: LLMProvider {
    /// The model this provider's calls are priced as (`ModelPriceList`).
    var pricingKey: PricingKey { PricingKey(provider: .gemini, model: config.modelName) }

    let config: LLMProviderConfig
    var modelName: String { config.modelName }

    init(config: LLMProviderConfig) {
        self.config = config
    }

    // MARK: - Config-Driven Computed Properties

    private var maxOutputTokens: Int? {
        if case .number(let val) = config.options?["maxOutputTokens"] { return Int(val) }
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

    private var topK: Int? {
        if case .number(let val) = config.options?["topK"] { return Int(val) }
        return nil
    }

    private var stopSequences: [String]? {
        if case .array(let arr) = config.options?["stopSequences"] {
            return arr.compactMap { if case .string(let s) = $0 { return s } else { return nil } }
        }
        return nil
    }

    // Why: top-level on the request body, a sibling of `generationConfig`, not a field inside it.
    /// The user's per-category safety thresholds, in Gemini's wire shape.
    private var safetySettings: [[String: String]]? {
        guard case .array(let entries)? = config.options?["safetySettings"] else { return nil }

        let mapped: [[String: String]] = entries.compactMap { entry in
            guard case .object(let fields) = entry,
                  case .string(let category)? = fields["category"],
                  case .string(let threshold)? = fields["threshold"]
            else { return nil }
            // `HARM_BLOCK_THRESHOLD_UNSPECIFIED` is this app's "Default" option — omit the entry
            // entirely so the account default applies, rather than pinning the unspecified value.
            guard threshold != HarmBlockThreshold.unspecified.rawValue else { return nil }
            return ["category": category, "threshold": threshold]
        }
        return mapped.isEmpty ? nil : mapped
    }

    /// Builds the generationConfig section from advanced config options.
    private func buildGenerationConfig() -> [String: Any]? {
        var generationConfig: [String: Any] = [:]
        if let maxTokens = maxOutputTokens { generationConfig["maxOutputTokens"] = maxTokens }
        if let temp = temperature { generationConfig["temperature"] = temp }
        if let topP = topP { generationConfig["topP"] = topP }
        if let topK = topK { generationConfig["topK"] = topK }
        if let stops = stopSequences, !stops.isEmpty { generationConfig["stopSequences"] = stops }
        return generationConfig.isEmpty ? nil : generationConfig
    }

    // MARK: - Thinking

    /// Asks a thinking model for its thought summaries via `generationConfig.thinkingConfig.includeThoughts`.
    /// Sent only to families that think (Gemini 2.5+ and the `-latest` aliases); older or unknown models get none.
    static func requestThoughtSummaries(in body: inout [String: Any], modelName: String) {
        guard modelThinks(modelName) else { return }
        var generationConfig = body["generationConfig"] as? [String: Any] ?? [:]
        var thinkingConfig = generationConfig["thinkingConfig"] as? [String: Any] ?? [:]
        thinkingConfig["includeThoughts"] = true
        generationConfig["thinkingConfig"] = thinkingConfig
        body["generationConfig"] = generationConfig
    }

    /// Whether `modelName` is a Gemini family that supports thinking: `gemini-X.Y…` with X.Y ≥ 2.5,
    /// or a `gemini-…-latest` alias (those point at thinking models). Vendor and `models/` prefixes
    /// are stripped first.
    static func modelThinks(_ modelName: String) -> Bool {
        let id = modelName.lowercased().split(separator: "/").last.map(String.init) ?? ""
        guard id.hasPrefix("gemini-") else { return false }
        if id.hasSuffix("-latest") { return true }
        let version = id.dropFirst("gemini-".count).prefix { $0 != "-" }
        let parts = version.split(separator: ".").compactMap { Int($0) }
        guard let major = parts.first else { return false }
        let minor = parts.count > 1 ? parts[1] : 0
        return major > 2 || (major == 2 && minor >= 5)
    }

    // Why: check before the text branch: a thought part also has `text` and would otherwise be appended to the answer.
    /// The text of a thought part (`{"text": …, "thought": true}`), or nil for any other part.
    static func thoughtText(of part: [String: Any]) -> String? {
        guard (part["thought"] as? Bool) == true else { return nil }
        return part["text"] as? String ?? ""
    }

    // Why: calling the config builder alone drops `safetySettings`, so the user's safety choices silently do nothing.
    /// Applies `generationConfig` and `safetySettings` to a request body.
    /// Every builder must call this, not `buildGenerationConfig()` directly.
    private func applyGenerationSettings(to body: inout [String: Any]) {
        if let generationConfig = buildGenerationConfig() {
            body["generationConfig"] = generationConfig
        }
        if let safetySettings {
            body["safetySettings"] = safetySettings
        }
    }

    // MARK: - Request Body Builders

    // Shared so shape assertions exercise the same code the shipped builders run.

    /// Body for the agent/tool-calling path.
    private func generateBody(messages: [[String: String]], tools: [[String: Any]]?) -> [String: Any] {
        let (contents, systemInstruction) = translateMessages(messages)
        var body: [String: Any] = ["contents": contents]
        if let systemInstruction { body["systemInstruction"] = systemInstruction }
        if let tools, !tools.isEmpty { body["tools"] = tools }
        applyGenerationSettings(to: &body)
        return body
    }

    /// Body for the bot/streaming path. `tools` are deliberately absent (see the call site).
    private func streamingBody(messages: [[String: String]]) -> [String: Any] {
        let (contents, systemInstruction) = translateMessages(messages)
        var body: [String: Any] = ["contents": contents]
        if let systemInstruction { body["systemInstruction"] = systemInstruction }
        applyGenerationSettings(to: &body)
        return body
    }

    // MARK: - Agent Flow (NativeAPI Tool Interception)

    func generate(messages: [[String: String]], tools: [[String: Any]]?, responseSchema: Any?) async throws -> String {
        try await generateWithUsage(messages: messages, tools: tools, responseSchema: responseSchema).text
    }

    func generateWithUsage(messages: [[String: String]], tools: [[String: Any]]?, responseSchema: Any?) async throws -> (text: String, usage: TokenUsage?) {
        let body = generateBody(messages: messages, tools: tools)

        let url = try buildURL(endpoint: ":generateContent")

        var request = makeRequest(url: url)
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, _) = try await CloudRequestPipeline.execute(request: request, provider: .geminiFlash, rateLimitKey: config.rateLimitKey)

        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        // A blocked prompt has no candidates, so check this before the guard below, which would report it as malformed.
        if let blocked = Self.blockError(in: json) { throw blocked }
        guard let candidates = json?["candidates"] as? [[String: Any]],
              let firstCandidate = candidates.first else {
            throw LLMProviderError.invalidResponse("Missing candidates in Gemini response.")
        }

        // Handle Safety Blockages and truncation
        if let finishReason = firstCandidate["finishReason"] as? String {
            if finishReason == "SAFETY" {
                throw LLMProviderError.refused(provider: "Gemini", detail: "blocked by Safety Settings")
            }
            if finishReason == "MAX_TOKENS" {
                let limitDesc = maxOutputTokens.map { String($0) } ?? "model default"
                logger.warning("⚠️ Gemini response truncated (finishReason: MAX_TOKENS). Configured maxOutputTokens: \(limitDesc). Output may be incomplete — consider increasing maxOutputTokens in advanced config.")
            }
        }

        guard let content = firstCandidate["content"] as? [String: Any],
              let parts = content["parts"] as? [[String: Any]] else {
            throw LLMProviderError.invalidResponse("Missing content parts in Gemini response.")
        }

        var textResponse = ""
        var syntheticStep: [String: Any]? = nil

        // Parse parts for both Text and Function Calls
        for part in parts {
            if Self.thoughtText(of: part) == nil, let text = part["text"] as? String {
                textResponse += text
            }

            // --- NATIVE TOOL INTERCEPTION BRIDGE ---
            if let functionCall = part["functionCall"] as? [String: Any],
               let toolName = functionCall["name"] as? String {

                let args = functionCall["args"] as? [String: Any] ?? [:]

                syntheticStep = [
                    "content": textResponse.isEmpty ? "Executing tool \(toolName)..." : textResponse,
                    "tool_name": toolName,
                    "arguments": args
                ]
            }
        }

        // If the model called a tool, intercept and return the synthesized LeanCognitiveStep JSON string
        let usage = json.flatMap { TokenUsage.fromGemini($0, pricing: pricingKey) }
        if let syntheticStep = syntheticStep {
            let syntheticData = try JSONSerialization.data(withJSONObject: syntheticStep)
            return (String(data: syntheticData, encoding: .utf8) ?? "{}", usage)
        }

        // Otherwise, return standard text (Task Completion / User Clarification)
        return (textResponse, usage)
    }

    // MARK: - Multimodal (native image input)

    /// Translates `[ProviderMessage]` into Gemini `contents` + `systemInstruction`,
    /// emitting `parts` with `{"inlineData":{"mimeType":…,"data":<base64>}}` for any
    /// image blocks. Resolving image bytes can throw — propagates to the caller.
    private func translateProviderMessagesGemini(_ payload: [ProviderMessage]) async throws -> (contents: [[String: Any]], systemInstruction: [String: Any]?) {
        var contents: [[String: Any]] = []
        var systemParts: [[String: Any]] = []

        for msg in payload {
            let parts = try await MultimodalTranslator.translateBlocks(
                msg.content,
                text: { ["text": $0] as [String: Any] },
                image: { mimeType, base64 in
                    ["inlineData": ["mimeType": mimeType, "data": base64]] as [String: Any]
                }
            )
            if msg.role == "system" {
                systemParts.append(contentsOf: parts)
            } else {
                let geminiRole = (msg.role == "assistant") ? "model" : "user"
                contents.append(["role": geminiRole, "parts": parts])
            }
        }

        let systemInstruction: [String: Any]? = systemParts.isEmpty ? nil : ["parts": systemParts]
        return (contents, systemInstruction)
    }

    /// Multimodal overload — serializes image blocks natively instead of the
    /// default text-downgrade. Mirrors `generate(messages:)` otherwise.
    func generate(payload: [ProviderMessage], tools: [[String: Any]]?, responseSchema: Any?) async throws -> String {
        let (contents, systemInstruction) = try await translateProviderMessagesGemini(payload)

        var body: [String: Any] = ["contents": contents]
        if let systemInstruction = systemInstruction { body["systemInstruction"] = systemInstruction }
        if let tools = tools, !tools.isEmpty { body["tools"] = tools }
        applyGenerationSettings(to: &body)

        let url = try buildURL(endpoint: ":generateContent")
        var request = makeRequest(url: url)
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, _) = try await CloudRequestPipeline.execute(request: request, provider: .geminiFlash, rateLimitKey: config.rateLimitKey)

        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        // A blocked prompt has no candidates, so check this before the guard below, which would report it as malformed.
        if let blocked = Self.blockError(in: json) { throw blocked }
        guard let candidates = json?["candidates"] as? [[String: Any]], let firstCandidate = candidates.first else {
            throw LLMProviderError.invalidResponse("Missing candidates in Gemini response.")
        }
        if let finishReason = firstCandidate["finishReason"] as? String, finishReason == "SAFETY" {
            throw LLMProviderError.refused(provider: "Gemini", detail: "blocked by Safety Settings")
        }
        guard let content = firstCandidate["content"] as? [String: Any], let parts = content["parts"] as? [[String: Any]] else {
            throw LLMProviderError.invalidResponse("Missing content parts in Gemini response.")
        }
        var textResponse = ""
        for part in parts where Self.thoughtText(of: part) == nil { if let text = part["text"] as? String { textResponse += text } }
        return textResponse.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func generateCognitiveStep(messages: [[String: String]], tools: [[String: Any]]?) async throws -> ModernCognitiveStep {
        let (contents, systemInstruction) = translateMessages(messages)

        var body: [String: Any] = ["contents": contents]

        if let systemInstruction = systemInstruction {
            body["systemInstruction"] = systemInstruction
        }

        if let tools = tools, !tools.isEmpty {
            body["tools"] = tools
        }

        applyGenerationSettings(to: &body)
        Self.requestThoughtSummaries(in: &body, modelName: config.modelName)

        let url = try buildURL(endpoint: ":generateContent")

        var request = makeRequest(url: url)
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, _) = try await CloudRequestPipeline.execute(request: request, provider: .geminiFlash, rateLimitKey: config.rateLimitKey)

        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        // A blocked prompt has no candidates, so check this before the guard below, which would report it as malformed.
        if let blocked = Self.blockError(in: json) { throw blocked }
        guard let candidates = json?["candidates"] as? [[String: Any]],
              let firstCandidate = candidates.first else {
            throw LLMProviderError.invalidResponse("Missing candidates in Gemini response.")
        }

        if let finishReason = firstCandidate["finishReason"] as? String {
            if finishReason == "SAFETY" {
                throw LLMProviderError.refused(provider: "Gemini", detail: "blocked by Safety Settings")
            }
            if finishReason == "MAX_TOKENS" {
                let limitDesc = maxOutputTokens.map { String($0) } ?? "model default"
                logger.warning("⚠️ Gemini cognitive step truncated (finishReason: MAX_TOKENS). Configured maxOutputTokens: \(limitDesc). Tool calls may have been cut off — consider increasing maxOutputTokens in advanced config.")
            }
        }

        guard let content = firstCandidate["content"] as? [String: Any],
              let parts = content["parts"] as? [[String: Any]] else {
            throw LLMProviderError.invalidResponse("Missing content parts in Gemini response.")
        }

        var textResponse = ""
        var thinkingTrace = ""
        var pendingTools: [PendingToolCall] = []

        for part in parts {
            if let thought = Self.thoughtText(of: part) {
                thinkingTrace += thought
            } else if let text = part["text"] as? String {
                textResponse += text
            } else if let functionCall = part["functionCall"] as? [String: Any],
                      let name = functionCall["name"] as? String {

                let args = functionCall["args"] as? [String: Any] ?? [:]
                let jsonArgs = args.reduce(into: [String: JSONValue]()) { result, pair in result[pair.key] = JSONValue(pair.value) ?? .null }
                pendingTools.append(PendingToolCall(id: UUID().uuidString, name: name, arguments: jsonArgs))
            }
        }

        let finalThought = thinkingTrace.isEmpty ? nil : thinkingTrace

        // Extract token usage from Gemini API response
        let usage = json.flatMap { TokenUsage.fromGemini($0, pricing: pricingKey) }

        // Empty reasoning stays empty: the UI derives "Executing <tool>..." labels from `.toolCall` events, not this field.
        return ModernCognitiveStep(reasoning: textResponse, thought: finalThought, toolCalls: pendingTools, tokenUsage: usage,
                                   reasoningReplay: pendingTools.isEmpty ? nil : Self.thoughtSignatureReplay(in: parts))
    }

    // MARK: - Native-Turn Cognitive Step (G12)

    /// Native-turn overload: accepts Gemini-shape messages from `GeminiToolTurnAdapter` (functionCall/functionResponse parts)
    /// plus normalized system/user turns with `parts: [{text}]`. Extracts `role: system` entries into `systemInstruction`.
    func generateCognitiveStep(nativeMessages: [[String: Any]], tools: [[String: Any]]?) async throws -> ModernCognitiveStep {
        var contents: [[String: Any]] = []
        var systemParts: [[String: Any]] = []
        for msg in nativeMessages {
            let role = (msg["role"] as? String) ?? "user"
            if role == "system" {
                if let parts = msg["parts"] as? [[String: Any]] {
                    systemParts.append(contentsOf: parts)
                } else if let text = msg["content"] as? String {
                    // Fallback: canonical shape that wasn't normalized.
                    systemParts.append(["text": text])
                }
            } else {
                contents.append(msg)
            }
        }

        var body: [String: Any] = ["contents": contents]

        if !systemParts.isEmpty {
            body["systemInstruction"] = ["parts": systemParts]
        }

        if let tools = tools, !tools.isEmpty {
            body["tools"] = tools
        }

        applyGenerationSettings(to: &body)
        Self.requestThoughtSummaries(in: &body, modelName: config.modelName)

        let url = try buildURL(endpoint: ":generateContent")
        var request = makeRequest(url: url)
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, _) = try await CloudRequestPipeline.execute(request: request, provider: .geminiFlash, rateLimitKey: config.rateLimitKey)

        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        // A blocked prompt has no candidates, so check this before the guard below, which would report it as malformed.
        if let blocked = Self.blockError(in: json) { throw blocked }
        guard let candidates = json?["candidates"] as? [[String: Any]],
              let firstCandidate = candidates.first else {
            throw LLMProviderError.invalidResponse("Missing candidates in Gemini response.")
        }

        if let finishReason = firstCandidate["finishReason"] as? String {
            if finishReason == "SAFETY" {
                throw LLMProviderError.refused(provider: "Gemini", detail: "blocked by Safety Settings")
            }
            if finishReason == "MAX_TOKENS" {
                let limitDesc = maxOutputTokens.map { String($0) } ?? "model default"
                logger.warning("⚠️ Gemini cognitive step truncated (finishReason: MAX_TOKENS). Configured maxOutputTokens: \(limitDesc).")
            }
        }

        guard let content = firstCandidate["content"] as? [String: Any],
              let parts = content["parts"] as? [[String: Any]] else {
            throw LLMProviderError.invalidResponse("Missing content parts in Gemini response.")
        }

        var textResponse = ""
        var thinkingTrace = ""
        var pendingTools: [PendingToolCall] = []

        for part in parts {
            if let thought = Self.thoughtText(of: part) {
                thinkingTrace += thought
            } else if let text = part["text"] as? String {
                textResponse += text
            } else if let functionCall = part["functionCall"] as? [String: Any],
                      let name = functionCall["name"] as? String {
                let args = functionCall["args"] as? [String: Any] ?? [:]
                let jsonArgs = args.reduce(into: [String: JSONValue]()) { result, pair in result[pair.key] = JSONValue(pair.value) ?? .null }
                pendingTools.append(PendingToolCall(id: UUID().uuidString, name: name, arguments: jsonArgs))
            }
        }

        let finalThought = thinkingTrace.isEmpty ? nil : thinkingTrace
        let usage = json.flatMap { TokenUsage.fromGemini($0, pricing: pricingKey) }

        return ModernCognitiveStep(reasoning: textResponse, thought: finalThought, toolCalls: pendingTools, tokenUsage: usage,
                                   reasoningReplay: pendingTools.isEmpty ? nil : Self.thoughtSignatureReplay(in: parts))
    }

    // MARK: - Bot Flow (Streaming)

    func stream(messages: [[String: String]], tools: [[String: Any]]?) -> AsyncThrowingStream<String, Error> {
        streamWithUsage(messages: messages, tools: tools, onUsage: nil)
    }

    func streamWithUsage(messages: [[String: String]], tools: [[String: Any]]?, onUsage: (@Sendable (TokenUsage) -> Void)?) -> AsyncThrowingStream<String, Error> {
        // Transport (read loop, cancellation, stall timeout) is owned by SSEStreamParser.
        SSEStreamParser.stream(
            openBytes: {
                // `tools` are ignored here so the Bot flow stays conversational.
                let body = self.streamingBody(messages: messages)

                let url = try self.buildURL(endpoint: ":streamGenerateContent", streamFormat: "sse")

                var request = self.makeRequest(url: url)
                request.httpBody = try JSONSerialization.data(withJSONObject: body)

                let (bytes, _) = try await CloudRequestPipeline.executeStream(
                    request: request, provider: .geminiFlash, rateLimitKey: self.config.rateLimitKey
                )
                return bytes
            },
            onUsage: onUsage,
            extractUsage: { line, _ in
                guard line.hasPrefix("data: ") else { return nil }
                let payload = String(line.dropFirst(6))
                guard let data = payload.data(using: .utf8),
                      let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
                // usageMetadata is cumulative; count only the final chunk (the one carrying
                // a finishReason) so earlier chunks don't double-count.
                let hasFinish = (json["candidates"] as? [[String: Any]])?.first?["finishReason"] != nil
                return hasFinish ? TokenUsage.fromGemini(json, pricing: self.pricingKey) : nil
            },
            // Pass the decoder itself, not a closure around it, so tests exercise exactly this code.
            handleLine: Self.geminiStreamLine
        )
    }

    // MARK: - Stream decode and blocking (static so they are testable without a network)

    /// Each function-call part's `thoughtSignature`, in call order (null where a part had none), or nil if none had one.
    /// Thinking models need it back on the replayed model turn; positional, as the adapter rebuilds parts in decode order.
    static func thoughtSignatureReplay(in parts: [[String: Any]]) -> JSONValue? {
        let signatures: [JSONValue] = parts.compactMap { part in
            guard part["functionCall"] != nil else { return nil }
            return (part["thoughtSignature"] as? String).map(JSONValue.string) ?? .null
        }
        guard signatures.contains(where: { $0 != .null }) else { return nil }
        return .object(["functionCallThoughtSignatures": .array(signatures)])
    }

    /// Finish reasons that mean Gemini's safety or policy systems stopped the answer.
    static let blockingFinishReasons: Set<String> = [
        "SAFETY", "RECITATION", "BLOCKLIST", "PROHIBITED_CONTENT", "SPII", "IMAGE_SAFETY",
    ]

    /// The block error in a Gemini response or stream chunk, or nil.
    /// Covers `promptFeedback.blockReason` (prompt refused, no candidates) and a blocking `finishReason`.
    static func blockError(in json: [String: Any]?) -> LLMProviderError? {
        if let reason = (json?["promptFeedback"] as? [String: Any])?["blockReason"] as? String {
            return .refused(provider: "Gemini", detail: "prompt blocked: \(reason)")
        }
        if let finish = ((json?["candidates"] as? [[String: Any]])?.first)?["finishReason"] as? String,
           blockingFinishReasons.contains(finish) {
            return .refused(provider: "Gemini", detail: "stopped: \(finish)")
        }
        return nil
    }

    /// One SSE line of a Gemini `streamGenerateContent` stream.
    static func geminiStreamLine(_ line: String, _ event: String) -> SSELineDirective {
        guard line.hasPrefix("data: ") else { return .skip }
        let payload = String(line.dropFirst(6))
        if payload.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return .skip }
        guard let data = payload.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return .skip }

        if let blocked = blockError(in: json) {
            logger.notice("[GEMINI] Stream blocked (\(blocked.localizedDescription)). CONSEQUENCE: the turn fails with that reason instead of ending as a silent empty or partial answer; not retried.")
            return .fail(blocked)
        }
        guard let candidates = json["candidates"] as? [[String: Any]],
              let content = candidates.first?["content"] as? [String: Any],
              let parts = content["parts"] as? [[String: Any]] else { return .skip }
        // Take every text part, not `parts.first`: a chunk can carry several.
        // Thought parts (`"thought": true`) are not the answer and are left out.
        let text = parts.filter { ($0["thought"] as? Bool) != true }.compactMap { $0["text"] as? String }.joined()
        return text.isEmpty ? .skip : .emit(text)
    }

    // MARK: - Private Helpers

    /// Translates OpenAI-formatted messages to Gemini's `contents` and `systemInstruction` format.
    private func translateMessages(_ messages: [[String: String]]) -> (contents: [[String: Any]], systemInstruction: [String: Any]?) {
        var contents: [[String: Any]] = []
        var systemInstructionParts: [[String: String]] = []

        for msg in messages {
            let role = msg["role"] ?? "user"
            let text = msg["content"] ?? ""

            if role == "system" {
                systemInstructionParts.append(["text": text])
            } else {
                // Gemini supports "user" and "model" roles
                let geminiRole = (role == "assistant") ? "model" : "user"
                contents.append([
                    "role": geminiRole,
                    "parts": [["text": text]]
                ])
            }
        }

        var systemInstruction: [String: Any]? = nil
        if !systemInstructionParts.isEmpty {
            systemInstruction = [
                "parts": systemInstructionParts
            ]
        }

        return (contents, systemInstruction)
    }

    // Why: a key in the URL leaks into access logs, OS network logging and error userInfo.
    /// Builds the request URL; only the non-secret `alt=sse` stream marker is a query item.
    /// The API key goes in the `x-goog-api-key` header (see `makeRequest`), never the URL.
    private func buildURL(endpoint: String, streamFormat: String? = nil) throws -> URL {
        let fullPath = config.baseURL.absoluteString + endpoint
        guard var components = URLComponents(string: fullPath) else {
            throw URLError(.badURL)
        }

        if let alt = streamFormat {
            components.queryItems = [URLQueryItem(name: "alt", value: alt)]
        }

        guard let finalURL = components.url else {
            throw URLError(.badURL)
        }

        return finalURL
    }

    /// Builds a POST request with JSON content type and the API key in the `x-goog-api-key` header, Google's header
    /// alternative to `?key=`. The caller sets `httpBody`.
    private func makeRequest(url: URL) -> URLRequest {
        var request = URLRequest(url: url, timeoutInterval: config.timeout)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let apiKey = config.apiKey {
            request.setValue(apiKey, forHTTPHeaderField: "x-goog-api-key")
        }
        return request
    }
}

// MARK: - Test Seam

// Thin pass-throughs with no logic of their own, so asserting on them equals asserting on a live request.
extension GeminiLLMProvider {

    /// Renders the agent request body without issuing a request.
    func debugRequestBody(messages: [[String: String]], tools: [[String: Any]]?) -> [String: Any] {
        generateBody(messages: messages, tools: tools)
    }

    /// Renders the bot/streaming request body without opening a stream.
    func debugStreamingRequestBody(messages: [[String: String]]) -> [String: Any] {
        streamingBody(messages: messages)
    }
}
