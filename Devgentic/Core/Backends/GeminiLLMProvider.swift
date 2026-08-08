//
//  GeminiLLMProvider.swift
//  Devgentic
//
//  Created by Raj Singh on 27/02/26.
//  Updated on 27/03/26: Config-driven parameters from AdvancedConfig,
//  CloudRequestPipeline integration for rate limiting and retry support.
//

import Foundation
import OSLog

private let logger = DGLogger(category: "GeminiLLMProvider")

/// Handles the official Google Gemini API via REST.
/// Adapts Devgentic's standard message payloads to Gemini's unique `contents` and `parts` architecture.
struct GeminiLLMProvider: LLMProvider {

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

    /// The user's per-category safety thresholds, in Gemini's wire shape.
    ///
    /// ⚠️ These are TOP-LEVEL on the request body, a sibling of `generationConfig` — not a field
    /// inside it. That is why they were missed: `buildGenerationConfig` copied every other advanced
    /// setting, so the omission looked like completeness.
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

    /// Applies `generationConfig` and `safetySettings` to a request body.
    ///
    /// ⚠️ Exists so the two cannot drift apart again. Safety Settings shipped as four pickers that
    /// NO request builder read: a user who set every category to "Block None" to get past a refusal
    /// on legitimate red-team or medical work still had the account defaults applied and still got
    /// blocked, and the inverse failed too — tightening to "Block Low and Above" for a kids-facing
    /// bot added no filtering whatsoever. A safety control that silently does nothing is worse than
    /// no control, because the user believes it worked. Every builder must call this, not
    /// `buildGenerationConfig()` directly.
    private func applyGenerationSettings(to body: inout [String: Any]) {
        if let generationConfig = buildGenerationConfig() {
            body["generationConfig"] = generationConfig
        }
        if let safetySettings {
            body["safetySettings"] = safetySettings
        }
    }

    // MARK: - Request Body Builders

    // ⚠️ Shared so the shape assertions in `AdvancedConfigDeliveryTests` exercise the SAME code the
    // shipped builders run. Safety Settings shipped dead for exactly this reason: nothing compared
    // what the panel wrote against what a request carried.

    /// Body for the agent/tool-calling path.
    private func generateBody(messages: [[String: String]], tools: [[String: Any]]?) -> [String: Any] {
        let (contents, systemInstruction) = translateMessages(messages)
        var body: [String: Any] = ["contents": contents]
        if let systemInstruction { body["systemInstruction"] = systemInstruction }
        if let tools, !tools.isEmpty { body["tools"] = tools }
        applyGenerationSettings(to: &body)
        return body
    }

    /// Body for the bot/streaming path. `tools` are deliberately absent — see the call site.
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
        guard let candidates = json?["candidates"] as? [[String: Any]],
              let firstCandidate = candidates.first else {
            throw LLMProviderError.invalidResponse("Missing candidates in Gemini response.")
        }

        // Handle Safety Blockages and truncation
        if let finishReason = firstCandidate["finishReason"] as? String {
            if finishReason == "SAFETY" {
                throw LLMProviderError.invalidResponse("Generation blocked by Gemini Safety Settings.")
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
            if let text = part["text"] as? String {
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
        let usage = json.flatMap { TokenUsage.fromGemini($0) }
        if let syntheticStep = syntheticStep {
            let syntheticData = try JSONSerialization.data(withJSONObject: syntheticStep)
            return (String(data: syntheticData, encoding: .utf8) ?? "{}", usage)
        }

        // Otherwise, return standard text (Task Completion / User Clarification)
        return (textResponse, usage)
    }

    // MARK: - Multimodal (Phase 3 — native image input)

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
        guard let candidates = json?["candidates"] as? [[String: Any]], let firstCandidate = candidates.first else {
            throw LLMProviderError.invalidResponse("Missing candidates in Gemini response.")
        }
        if let finishReason = firstCandidate["finishReason"] as? String, finishReason == "SAFETY" {
            throw LLMProviderError.invalidResponse("Generation blocked by Gemini Safety Settings.")
        }
        guard let content = firstCandidate["content"] as? [String: Any], let parts = content["parts"] as? [[String: Any]] else {
            throw LLMProviderError.invalidResponse("Missing content parts in Gemini response.")
        }
        var textResponse = ""
        for part in parts { if let text = part["text"] as? String { textResponse += text } }
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

        // --- NATIVE THINKING CONFIGURATION ---
        // Enabled for models that support internal reasoning traces (e.g. Gemini 2.0 Thinking)
        body["thinking_config"] = ["include_thoughts": true]

        let url = try buildURL(endpoint: ":generateContent")

        var request = makeRequest(url: url)
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, _) = try await CloudRequestPipeline.execute(request: request, provider: .geminiFlash, rateLimitKey: config.rateLimitKey)

        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        guard let candidates = json?["candidates"] as? [[String: Any]],
              let firstCandidate = candidates.first else {
            throw LLMProviderError.invalidResponse("Missing candidates in Gemini response.")
        }

        if let finishReason = firstCandidate["finishReason"] as? String {
            if finishReason == "SAFETY" {
                throw LLMProviderError.invalidResponse("Generation blocked by Gemini Safety Settings.")
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
            if let text = part["text"] as? String {
                textResponse += text
            } else if let thought = part["thought"] as? String {
                thinkingTrace += thought
            } else if let functionCall = part["functionCall"] as? [String: Any],
                      let name = functionCall["name"] as? String {

                let args = functionCall["args"] as? [String: Any] ?? [:]
                let jsonArgs = args.reduce(into: [String: JSONValue]()) { result, pair in result[pair.key] = JSONValue(pair.value) ?? .null }
                pendingTools.append(PendingToolCall(id: UUID().uuidString, name: name, arguments: jsonArgs))
            }
        }

        let finalThought = thinkingTrace.isEmpty ? nil : thinkingTrace

        // Extract token usage from Gemini API response
        let usage = json.flatMap { TokenUsage.fromGemini($0) }

        // Empty reasoning stays empty — the UI derives "Executing <tool>..." labels from
        // .toolCall events, not from this field. A placeholder here would pollute any
        // future scratchpad injection with meaningless text. (G7 / reasoning refactor)
        return ModernCognitiveStep(reasoning: textResponse, thought: finalThought, toolCalls: pendingTools, tokenUsage: usage)
    }

    // MARK: - Native-Turn Cognitive Step (G12)

    /// Native-turn overload. Accepts Gemini-shape messages from `GeminiToolTurnAdapter`
    /// (role "model"/"user", parts with functionCall/functionResponse) plus normalized
    /// system/user turns with `parts: [{text}]`.
    /// Extracts role:"system" entries into Gemini's top-level `systemInstruction` field.
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

        body["thinking_config"] = ["include_thoughts": true]

        let url = try buildURL(endpoint: ":generateContent")
        var request = makeRequest(url: url)
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, _) = try await CloudRequestPipeline.execute(request: request, provider: .geminiFlash, rateLimitKey: config.rateLimitKey)

        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        guard let candidates = json?["candidates"] as? [[String: Any]],
              let firstCandidate = candidates.first else {
            throw LLMProviderError.invalidResponse("Missing candidates in Gemini response.")
        }

        if let finishReason = firstCandidate["finishReason"] as? String {
            if finishReason == "SAFETY" {
                throw LLMProviderError.invalidResponse("Generation blocked by Gemini Safety Settings.")
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
            if let text = part["text"] as? String {
                textResponse += text
            } else if let thought = part["thought"] as? String {
                thinkingTrace += thought
            } else if let functionCall = part["functionCall"] as? [String: Any],
                      let name = functionCall["name"] as? String {
                let args = functionCall["args"] as? [String: Any] ?? [:]
                let jsonArgs = args.reduce(into: [String: JSONValue]()) { result, pair in result[pair.key] = JSONValue(pair.value) ?? .null }
                pendingTools.append(PendingToolCall(id: UUID().uuidString, name: name, arguments: jsonArgs))
            }
        }

        let finalThought = thinkingTrace.isEmpty ? nil : thinkingTrace
        let usage = json.flatMap { TokenUsage.fromGemini($0) }

        return ModernCognitiveStep(reasoning: textResponse, thought: finalThought, toolCalls: pendingTools, tokenUsage: usage)
    }

    // MARK: - Bot Flow (Streaming)

    func stream(messages: [[String: String]], tools: [[String: Any]]?) -> AsyncThrowingStream<String, Error> {
        streamWithUsage(messages: messages, tools: tools, onUsage: nil)
    }

    func streamWithUsage(messages: [[String: String]], tools: [[String: Any]]?, onUsage: (@Sendable (TokenUsage) -> Void)?) -> AsyncThrowingStream<String, Error> {
        // Transport (read loop, cancellation, stall timeout) is owned by SSEStreamParser.
        SSEStreamParser.stream(
            openBytes: {
                // `tools` are intentionally ignored here so the Bot flow stays strictly conversational.
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
                return hasFinish ? TokenUsage.fromGemini(json) : nil
            },
            handleLine: { line, _ in
                guard line.hasPrefix("data: ") else { return .skip }
                let payload = String(line.dropFirst(6))

                if payload.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return .skip }

                guard let data = payload.data(using: .utf8),
                      let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let candidates = json["candidates"] as? [[String: Any]],
                      let firstCandidate = candidates.first,
                      let content = firstCandidate["content"] as? [String: Any],
                      let parts = content["parts"] as? [[String: Any]],
                      let firstPart = parts.first,
                      let text = firstPart["text"] as? String else {
                    return .skip
                }
                return .emit(text)
            }
        )
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

    /// Constructs the final URL with necessary query parameters.
    /// Builds the request URL. The API key is intentionally NOT placed here — it
    /// goes in the `x-goog-api-key` header (see `makeRequest`) so the secret never
    /// lands in the URL, where it would leak into Google/proxy access logs, OS
    /// network logging, and failing-URL error userInfo. Only the non-secret
    /// `alt=sse` stream marker is a query item.
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

    /// Builds a POST request with JSON content-type and the API key in the
    /// `x-goog-api-key` header — Google's documented header alternative to `?key=`,
    /// matching how Claude (`x-api-key`) and OpenAI (`Authorization`) pass theirs.
    /// The caller sets `httpBody`.
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

// ⚠️ Thin pass-throughs with NO logic of their own — the only reason asserting on them is
// equivalent to asserting on a live request.
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
