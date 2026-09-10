// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2026 Raj Singh
//
//  ClaudeLLMProvider.swift
//  Devgentic
//
//  Created by Raj Singh on 27/02/26.
//  Updated on 27/03/26: Config-driven parameters, CloudRequestPipeline, extended thinking,
//  multi-tool support in generate(), and improved streaming.
//

import Foundation
import OSLog

private let logger = DGLogger(category: "ClaudeLLMProvider")

/// Handles the official Anthropic Claude API via REST.
/// Adapts Devgentic's standard message payloads to Claude's unique top-level system prompt
/// and `tool_use` content blocks.
struct ClaudeLLMProvider: LLMProvider {

    let config: LLMProviderConfig
    var modelName: String { config.modelName }

    init(config: LLMProviderConfig) {
        self.config = config
    }

    // MARK: - Config-Driven Computed Properties

    /// Reads max_tokens from advanced config, defaulting to 4096.
    private var maxTokens: Int {
        if case .number(let val) = config.options?["maxTokens"] { return Int(val) }
        return 4096
    }

    /// Reads temperature from advanced config. Returns nil to omit from request.
    private var temperature: Double? {
        if case .number(let val) = config.options?["temperature"] { return val }
        return nil
    }

    /// Reads topP from advanced config.
    private var topP: Double? {
        if case .number(let val) = config.options?["topP"] { return val }
        return nil
    }

    /// Reads topK from advanced config.
    private var topK: Int? {
        if case .number(let val) = config.options?["topK"] { return Int(val) }
        return nil
    }

    /// Reads stop sequences from advanced config.
    private var stopSequences: [String]? {
        if case .array(let arr) = config.options?["stopSequences"] {
            return arr.compactMap { if case .string(let s) = $0 { return s } else { return nil } }
        }
        return nil
    }

    /// Whether extended thinking is enabled via advanced config.
    private var extendedThinking: Bool {
        if case .bool(let val) = config.options?["extendedThinking"] { return val }
        return false
    }

    /// Budget tokens for thinking. Defaults to 10000.
    /// ⚠️ Only consulted on `.legacyBudget` models — Opus 4.7+ / Sonnet 5 / Fable 5 reject
    /// `budget_tokens` outright, and use `thinkingEffort` instead.
    private var thinkingBudget: Int {
        if case .number(let val) = config.options?["thinkingBudgetTokens"] { return Int(val) }
        return 10000
    }

    /// Thinking depth for adaptive-era models: `low` | `medium` | `high` | `xhigh` | `max`.
    /// Nil omits `output_config`, which the API reads as its own default (`high`).
    private var thinkingEffort: String? {
        if case .string(let val) = config.options?["thinkingEffort"], !val.isEmpty { return val }
        return nil
    }

    /// The request contract the selected model accepts. See `AnthropicModelGeneration`.
    private var generation: AnthropicModelGeneration {
        AnthropicModelGeneration.classify(modelName: config.modelName)
    }

    /// Max output tokens actually sent.
    ///
    /// ⚠️ On the legacy thinking path the API requires `max_tokens` to be strictly greater than
    /// `budget_tokens`, so a profile configured with 4096/10000 would be rejected on arrival —
    /// hence the floor. Adaptive-era models carry no budget, so the user's value is sent
    /// verbatim rather than silently inflated (that would change what they are billed).
    private var effectiveMaxTokens: Int {
        guard extendedThinking, !generation.usesAdaptiveThinking else { return maxTokens }
        return max(maxTokens, thinkingBudget + 1024)
    }

    /// Applies sampling parameters, gated on what the selected model actually accepts.
    ///
    /// ⚠️ Three separate contracts collide here, and getting any of them wrong is a 400 rather
    /// than a degraded response:
    ///   1. `temperature`/`top_p`/`top_k` are REMOVED on Opus 4.7+ / Sonnet 5 / Fable 5.
    ///   2. Every Claude 4+ model rejects `temperature` and `top_p` sent together.
    ///   3. Extended thinking does not permit sampling parameters on the models that still
    ///      accept them otherwise.
    /// `stop_sequences` is unaffected by all three and is always forwarded.
    private func applyGenerationParams(to body: inout [String: Any]) {
        defer {
            if let stops = stopSequences, !stops.isEmpty { body["stop_sequences"] = stops }
        }

        guard generation.acceptsSamplingParams else {
            if temperature != nil || topP != nil || topK != nil {
                logger.notice("""
                    [ANTHROPIC] Dropped temperature/top_p/top_k for model '\(config.modelName)' \
                    (generation: \(generation.rawValue)) — these parameters are removed on this \
                    model and sending them returns 400. CONSEQUENCE: the request uses the model's \
                    own sampling defaults; the Advanced panel's values have no effect here.
                    """)
            }
            return
        }

        guard !extendedThinking else {
            if temperature != nil || topP != nil || topK != nil {
                logger.notice("""
                    [ANTHROPIC] Dropped temperature/top_p/top_k for model '\(config.modelName)' \
                    because Extended Thinking is enabled — thinking does not permit sampling \
                    parameters. CONSEQUENCE: sampling falls back to the model default for this \
                    request; turn thinking off to steer it.
                    """)
            }
            return
        }

        // Claude 4+ rejects temperature and top_p together. Temperature wins: it is the control
        // the panel presents first and the one a user is most likely to have set deliberately.
        if let temp = temperature {
            body["temperature"] = temp
            if topP != nil {
                logger.notice("""
                    [ANTHROPIC] Dropped top_p for model '\(config.modelName)' — temperature and \
                    top_p cannot both be sent to a Claude 4+ model. CONSEQUENCE: temperature \
                    \(temp) is in effect and the configured top_p is ignored for this request.
                    """)
            }
        } else if let topP = topP {
            body["top_p"] = topP
        }

        if let topK = topK { body["top_k"] = topK }
    }

    /// Applies the thinking configuration in whichever shape the selected model accepts.
    ///
    /// ⚠️ Applied by EVERY request builder, not just the cognitive step. The toggle used to be
    /// wired only into `generateCognitiveStep`, so a Bot profile with Extended Thinking on got no
    /// thinking at all while still losing its temperature control — the toggle removed a setting
    /// and delivered nothing.
    ///
    /// - Parameter requestSummary: whether to ask for readable reasoning via
    ///   `display: "summarized"`. ⚠️ Adaptive-era models default to `"omitted"`, which streams
    ///   thinking blocks with EMPTY text — so the cognitive-step builders, whose `thought` field
    ///   the UI renders, must opt in or they would show a blank trace where the legacy shape
    ///   showed reasoning. Builders that never read thinking leave it omitted so the summary is
    ///   not generated into a response nobody displays.
    private func applyThinking(to body: inout [String: Any], requestSummary: Bool = false) {
        guard generation.usesAdaptiveThinking else {
            // Legacy tier: thinking is opt-in via budget_tokens, and omitting the key means off.
            if extendedThinking {
                body["thinking"] = ["type": "enabled", "budget_tokens": thinkingBudget]
            }
            return
        }

        if !extendedThinking && generation.acceptsDisabledThinking {
            // ⚠️ Explicit disable, not omission. Thinking is ON BY DEFAULT on Opus 5 and
            // Sonnet 5, so omitting the key would silently give the user thinking they just
            // switched off. `output_config` is deliberately left unset here: the API's default
            // effort (`high`) is accepted alongside disabled thinking, whereas `xhigh`/`max` are
            // not — so sending nothing is the only value that cannot 400.
            body["thinking"] = ["type": "disabled"]
            return
        }

        // ⚠️ Falling through with thinking OFF is deliberate and only happens on
        // `.adaptiveAlwaysOn` (Fable 5 / Mythos 5), where thinking cannot be turned off at all
        // and `{"type": "disabled"}` is rejected with a 400 at every effort level. Adaptive is
        // documented as equivalent to omitting the key, so it is the honest shape to send. The
        // panel hides the toggle for these models; this log covers a profile that was configured
        // on another model and then re-pointed, where the stored `false` survives.
        if !extendedThinking {
            logger.notice("""
                [ANTHROPIC] Extended Thinking is OFF in the profile but cannot be honoured for \
                model '\(config.modelName)' (generation: \(generation.rawValue)) — thinking is \
                always on for this model and sending {"type": "disabled"} returns 400. \
                CONSEQUENCE: the request runs WITH thinking; the toggle has no effect here, and \
                `max_tokens` (\(effectiveMaxTokens)) caps thinking and reply text together.
                """)
        }

        var thinking: [String: Any] = ["type": "adaptive"]
        if requestSummary { thinking["display"] = "summarized" }
        body["thinking"] = thinking

        guard generation.acceptsEffort, let effort = thinkingEffort else { return }
        guard generation.supportedEffortLevels.contains(effort) else {
            logger.notice("""
                [ANTHROPIC] Dropped effort '\(effort)' for model '\(config.modelName)' \
                (generation: \(generation.rawValue)) — supported levels are \
                \(generation.supportedEffortLevels.joined(separator: ", ")). CONSEQUENCE: the \
                request runs at the API default effort (high) instead of the configured level.
                """)
            return
        }
        body["output_config"] = ["effort": effort]
    }

    // MARK: - Request Body Builders

    // ⚠️ These exist so the shape assertions in `AnthropicRequestShapeTests` exercise the SAME
    // code the shipped builders run. A test that rebuilds the body itself only ever proves the
    // test's copy is right — exactly how four contract defects (register A20–A23) reached users
    // with a green suite.

    /// Body for the agent/cognitive-step path. Requests a thinking summary because this path
    /// parses thinking blocks into `ModernCognitiveStep.thought`.
    private func cognitiveStepBody(
        anthropicMessages: [[String: Any]],
        systemPrompt: String?,
        tools: [[String: Any]]?
    ) -> [String: Any] {
        var body: [String: Any] = [
            "model": config.modelName,
            "messages": anthropicMessages,
            "max_tokens": effectiveMaxTokens
        ]
        applyGenerationParams(to: &body)
        applyThinking(to: &body, requestSummary: true)
        if let systemPrompt = systemPrompt { body["system"] = systemPrompt }
        if let tools = tools, !tools.isEmpty { body["tools"] = tools }
        return body
    }

    /// Body for the bot/streaming path. No thinking summary: this stream is the visible reply
    /// and has no second sink for reasoning (see the `thinking_delta` note in the SSE decode).
    private func streamingBody(
        anthropicMessages: [[String: Any]],
        systemPrompt: String?
    ) -> [String: Any] {
        var body: [String: Any] = [
            "model": config.modelName,
            "messages": anthropicMessages,
            "max_tokens": effectiveMaxTokens,
            "stream": true
        ]
        applyGenerationParams(to: &body)
        applyThinking(to: &body)
        if let systemPrompt = systemPrompt { body["system"] = systemPrompt }
        return body
    }

    /// Creates a standard Anthropic URLRequest with proper headers.
    private func makeRequest(streaming: Bool = false) -> URLRequest {
        let url = config.baseURL.appendingPathComponent("messages")
        var request = URLRequest(url: url, timeoutInterval: config.timeout)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        // ⚠️ `anthropic-version` has exactly two valid values (2023-06-01, 2023-01-01) and is NOT
        // a feature switch — every dated capability since ships behind `anthropic-beta`. This
        // used to send "2025-04-14" whenever Extended Thinking was on, which is not a version the
        // API recognises, so enabling the toggle rejected every request from the profile with an
        // invalid_request_error — not just the thinking ones. Turning it back off "fixed" it,
        // which made the cause near-impossible to attribute from the symptom.
        request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")

        if let apiKey = config.apiKey {
            request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        }
        return request
    }

    // MARK: - Agent Flow (NativeAPI Tool Interception)

    func generate(messages: [[String: String]], tools: [[String: Any]]?, responseSchema: Any?) async throws -> String {
        try await generateWithUsage(messages: messages, tools: tools, responseSchema: responseSchema).text
    }

    func generateWithUsage(messages: [[String: String]], tools: [[String: Any]]?, responseSchema: Any?) async throws -> (text: String, usage: TokenUsage?) {
        let (systemPrompt, anthropicMessages) = translateMessages(messages)

        var body: [String: Any] = [
            "model": config.modelName,
            "messages": anthropicMessages,
            "max_tokens": effectiveMaxTokens
        ]

        applyGenerationParams(to: &body)
        applyThinking(to: &body)

        if let systemPrompt = systemPrompt {
            body["system"] = systemPrompt
        }

        if let tools = tools, !tools.isEmpty {
            body["tools"] = tools
        }

        var request = makeRequest()
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, _) = try await CloudRequestPipeline.execute(request: request, provider: .anthropic, rateLimitKey: config.rateLimitKey)

        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        let usage = json.flatMap { TokenUsage.fromAnthropic($0) }

        // Defensive check: warn if response was truncated by max_tokens limit
        if let stopReason = json?["stop_reason"] as? String, stopReason == "max_tokens" {
            logger.warning("⚠️ Anthropic response truncated (stop_reason: max_tokens). Configured max_tokens: \(self.maxTokens). Output may be incomplete — consider increasing maxTokens in advanced config.")
        }

        guard let contentBlocks = json?["content"] as? [[String: Any]] else {
            throw LLMProviderError.invalidResponse("Missing content blocks in Anthropic response.")
        }

        var textResponse = ""
        var syntheticSteps: [[String: Any]] = []

        // Parse parts for both Text (Reasoning) and Tool Use — capture ALL tool_use blocks
        for block in contentBlocks {
            if let type = block["type"] as? String {
                if type == "text" {
                    textResponse += (block["text"] as? String ?? "")
                } else if type == "tool_use" {
                    // --- NATIVE TOOL INTERCEPTION BRIDGE ---
                    let toolName = block["name"] as? String ?? "unknown_tool"
                    let inputArgs = block["input"] as? [String: Any] ?? [:]

                    syntheticSteps.append([
                        "content": textResponse.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "Executing tool \(toolName)..." : textResponse.trimmingCharacters(in: .whitespacesAndNewlines),
                        "tool_name": toolName,
                        "arguments": inputArgs
                    ])
                }
            }
        }

        // If the model called tools, return the first synthesized LeanCognitiveStep JSON string
        // (generate() returns a single string — use generateCognitiveStep() for multi-tool support)
        if let firstStep = syntheticSteps.first {
            let syntheticData = try JSONSerialization.data(withJSONObject: firstStep)
            return (String(data: syntheticData, encoding: .utf8) ?? "{}", usage)
        }

        // Otherwise, return standard text (Task Completion / User Clarification)
        return (textResponse.trimmingCharacters(in: .whitespacesAndNewlines), usage)
    }

    // MARK: - Multimodal (Phase 3 — native image input)

    /// Translates provider-agnostic `[ProviderMessage]` into Anthropic messages,
    /// emitting native content-block arrays (`{"type":"image","source":{"type":"base64",…}}`)
    /// for any image blocks. Text-only messages stay as a plain content string.
    /// Resolving image bytes can throw (file gone/unreadable) — the error propagates
    /// to the caller (node failure / chat error), never a silent drop.
    private func translateProviderMessages(_ payload: [ProviderMessage]) async throws -> (system: String?, anthropicMessages: [[String: Any]]) {
        var systemPrompt = ""
        var anthropicMessages: [[String: Any]] = []

        for msg in payload {
            if msg.role == "system" {
                if !systemPrompt.isEmpty { systemPrompt += "\n\n" }
                systemPrompt += msg.content.textContent
                continue
            }
            let anthropicRole = (msg.role == "assistant") ? "assistant" : "user"

            if msg.content.isTextOnly {
                anthropicMessages.append(["role": anthropicRole, "content": msg.content.textContent])
                continue
            }

            let blocks = try await MultimodalTranslator.translateBlocks(
                msg.content,
                text: { ["type": "text", "text": $0] as [String: Any] },
                image: { mimeType, base64 in
                    ["type": "image",
                     "source": ["type": "base64", "media_type": mimeType, "data": base64]] as [String: Any]
                }
            )
            anthropicMessages.append(["role": anthropicRole, "content": blocks])
        }

        return (systemPrompt.isEmpty ? nil : systemPrompt, anthropicMessages)
    }

    /// Multimodal overload — serializes image blocks natively instead of the
    /// default text-downgrade. Mirrors `generate(messages:)` otherwise.
    func generate(payload: [ProviderMessage], tools: [[String: Any]]?, responseSchema: Any?) async throws -> String {
        let (systemPrompt, anthropicMessages) = try await translateProviderMessages(payload)

        var body: [String: Any] = [
            "model": config.modelName,
            "messages": anthropicMessages,
            "max_tokens": effectiveMaxTokens
        ]
        applyGenerationParams(to: &body)
        applyThinking(to: &body)
        if let systemPrompt = systemPrompt { body["system"] = systemPrompt }
        if let tools = tools, !tools.isEmpty { body["tools"] = tools }

        var request = makeRequest()
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, _) = try await CloudRequestPipeline.execute(request: request, provider: .anthropic, rateLimitKey: config.rateLimitKey)
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]

        if let stopReason = json?["stop_reason"] as? String, stopReason == "max_tokens" {
            logger.warning("⚠️ Anthropic multimodal response truncated (stop_reason: max_tokens). Configured max_tokens: \(self.maxTokens).")
        }
        guard let contentBlocks = json?["content"] as? [[String: Any]] else {
            throw LLMProviderError.invalidResponse("Missing content blocks in Anthropic response.")
        }

        var textResponse = ""
        var syntheticSteps: [[String: Any]] = []
        for block in contentBlocks {
            if let type = block["type"] as? String {
                if type == "text" {
                    textResponse += (block["text"] as? String ?? "")
                } else if type == "tool_use" {
                    let toolName = block["name"] as? String ?? "unknown_tool"
                    let inputArgs = block["input"] as? [String: Any] ?? [:]
                    syntheticSteps.append([
                        "content": textResponse.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "Executing tool \(toolName)..." : textResponse.trimmingCharacters(in: .whitespacesAndNewlines),
                        "tool_name": toolName,
                        "arguments": inputArgs
                    ])
                }
            }
        }
        if let firstStep = syntheticSteps.first {
            let syntheticData = try JSONSerialization.data(withJSONObject: firstStep)
            return String(data: syntheticData, encoding: .utf8) ?? "{}"
        }
        return textResponse.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func generateCognitiveStep(messages: [[String: String]], tools: [[String: Any]]?) async throws -> ModernCognitiveStep {
        let (systemPrompt, anthropicMessages) = translateMessages(messages)

        let body = cognitiveStepBody(
            anthropicMessages: anthropicMessages, systemPrompt: systemPrompt, tools: tools)

        var request = makeRequest()
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, _) = try await CloudRequestPipeline.execute(request: request, provider: .anthropic, rateLimitKey: config.rateLimitKey)

        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]

        // Defensive check: warn if response was truncated by max_tokens limit.
        // ⚠️ On the adaptive tier `max_tokens` caps thinking AND response text together, so a
        // profile tuned before thinking was enabled can truncate without any budget being set.
        if let stopReason = json?["stop_reason"] as? String, stopReason == "max_tokens" {
            logger.warning("""
                [ANTHROPIC] ⚠️ Cognitive step truncated (stop_reason: max_tokens) for model \
                '\(self.config.modelName)'. Effective max_tokens: \(self.effectiveMaxTokens) \
                (thinking: \(self.extendedThinking), shape: \(self.generation.rawValue)). \
                CONSEQUENCE: tool calls may have been cut off — raise Max Output Tokens in the \
                Advanced panel.
                """)
        }

        guard let contentBlocks = json?["content"] as? [[String: Any]] else {
            throw LLMProviderError.invalidResponse("Missing content blocks in Anthropic response.")
        }

        var reasoning = ""
        var thinkingTrace = ""
        var pendingTools: [PendingToolCall] = []

        for block in contentBlocks {
            let type = block["type"] as? String ?? ""
            if type == "text" {
                reasoning += (block["text"] as? String ?? "")
            } else if type == "thinking" {
                thinkingTrace += (block["thinking"] as? String ?? "")
            } else if type == "tool_use" {
                let id = block["id"] as? String ?? UUID().uuidString
                let name = block["name"] as? String ?? "unknown_tool"
                let input = block["input"] as? [String: Any] ?? [:]

                let arguments = input.reduce(into: [String: JSONValue]()) { result, pair in result[pair.key] = JSONValue(pair.value) ?? .null }
                pendingTools.append(PendingToolCall(id: id, name: name, arguments: arguments))
            }
        }

        let finalReasoning = reasoning.trimmingCharacters(in: .whitespacesAndNewlines)
        let finalThought = thinkingTrace.isEmpty ? nil : thinkingTrace

        // Extract token usage from Anthropic API response
        let usage = json.flatMap { TokenUsage.fromAnthropic($0) }

        // Empty reasoning stays empty — the UI derives "Executing <tool>..." labels from
        // .toolCall events, not from this field. A placeholder here would pollute any
        // future scratchpad injection with meaningless text. (G7 / reasoning refactor)
        return ModernCognitiveStep(reasoning: finalReasoning, thought: finalThought, toolCalls: pendingTools, tokenUsage: usage)
    }

    // MARK: - Native-Turn Cognitive Step (G12)

    /// Native-turn overload. Accepts provider-shape messages from `ClaudeToolTurnAdapter`
    /// which may contain `content` arrays of `tool_use` / `tool_result` blocks, plus
    /// canonical `{role, content: string}` messages from PromptBuilder.
    /// Extracts `role: "system"` messages into Claude's top-level `system` field.
    func generateCognitiveStep(nativeMessages: [[String: Any]], tools: [[String: Any]]?) async throws -> ModernCognitiveStep {
        var systemPrompt = ""
        var anthropicMessages: [[String: Any]] = []
        for msg in nativeMessages {
            let role = (msg["role"] as? String) ?? "user"
            if role == "system" {
                if !systemPrompt.isEmpty { systemPrompt += "\n\n" }
                systemPrompt += (msg["content"] as? String) ?? ""
            } else {
                anthropicMessages.append(msg)
            }
        }

        var body: [String: Any] = [
            "model": config.modelName,
            "messages": anthropicMessages,
            "max_tokens": effectiveMaxTokens
        ]
        applyGenerationParams(to: &body)
        // `requestSummary: true` because this builder parses thinking blocks into `thought`.
        applyThinking(to: &body, requestSummary: true)

        if !systemPrompt.isEmpty {
            body["system"] = systemPrompt
        }
        if let tools = tools, !tools.isEmpty {
            body["tools"] = tools
        }

        var request = makeRequest()
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, _) = try await CloudRequestPipeline.execute(request: request, provider: .anthropic, rateLimitKey: config.rateLimitKey)

        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]

        if let stopReason = json?["stop_reason"] as? String, stopReason == "max_tokens" {
            logger.warning("""
                [ANTHROPIC] ⚠️ Cognitive step truncated (stop_reason: max_tokens) for model \
                '\(self.config.modelName)'. Effective max_tokens: \(self.effectiveMaxTokens) \
                (thinking: \(self.extendedThinking), shape: \(self.generation.rawValue)). \
                CONSEQUENCE: tool calls may have been cut off — raise Max Output Tokens in the \
                Advanced panel.
                """)
        }

        guard let contentBlocks = json?["content"] as? [[String: Any]] else {
            throw LLMProviderError.invalidResponse("Missing content blocks in Anthropic response.")
        }

        var reasoning = ""
        var thinkingTrace = ""
        var pendingTools: [PendingToolCall] = []

        for block in contentBlocks {
            let type = block["type"] as? String ?? ""
            if type == "text" {
                reasoning += (block["text"] as? String ?? "")
            } else if type == "thinking" {
                thinkingTrace += (block["thinking"] as? String ?? "")
            } else if type == "tool_use" {
                let id = block["id"] as? String ?? UUID().uuidString
                let name = block["name"] as? String ?? "unknown_tool"
                let input = block["input"] as? [String: Any] ?? [:]
                let arguments = input.reduce(into: [String: JSONValue]()) { result, pair in result[pair.key] = JSONValue(pair.value) ?? .null }
                pendingTools.append(PendingToolCall(id: id, name: name, arguments: arguments))
            }
        }

        let finalReasoning = reasoning.trimmingCharacters(in: .whitespacesAndNewlines)
        let finalThought = thinkingTrace.isEmpty ? nil : thinkingTrace
        let usage = json.flatMap { TokenUsage.fromAnthropic($0) }

        return ModernCognitiveStep(reasoning: finalReasoning, thought: finalThought, toolCalls: pendingTools, tokenUsage: usage)
    }

    // MARK: - Bot Flow (Streaming)

    func stream(messages: [[String: String]], tools: [[String: Any]]?) -> AsyncThrowingStream<String, Error> {
        streamWithUsage(messages: messages, tools: tools, onUsage: nil)
    }

    func streamWithUsage(messages: [[String: String]], tools: [[String: Any]]?, onUsage: (@Sendable (TokenUsage) -> Void)?) -> AsyncThrowingStream<String, Error> {
        // Transport (read loop, cancellation, stall timeout) is owned by SSEStreamParser;
        // this provides only the request and the per-line SSE decode.
        SSEStreamParser.stream(
            openBytes: {
                let (systemPrompt, anthropicMessages) = self.translateMessages(messages)

                let body = self.streamingBody(
                    anthropicMessages: anthropicMessages, systemPrompt: systemPrompt)

                var request = self.makeRequest(streaming: true)
                request.httpBody = try JSONSerialization.data(withJSONObject: body)

                let (bytes, _) = try await CloudRequestPipeline.executeStream(
                    request: request, provider: .anthropic, rateLimitKey: self.config.rateLimitKey
                )
                return bytes
            },
            onUsage: onUsage,
            extractUsage: { line, event in
                guard line.hasPrefix("data: ") else { return nil }
                let payload = String(line.dropFirst(6))
                guard let data = payload.data(using: .utf8),
                      let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
                // Claude streams usage split across events: input on `message_start`,
                // final output on `message_delta`. Returned as partials; the parser sums them.
                switch event {
                case "message_start":
                    if let message = json["message"] as? [String: Any],
                       let usage = message["usage"] as? [String: Any],
                       let input = usage["input_tokens"] as? Int {
                        return TokenUsage(inputTokens: input, outputTokens: 0)
                    }
                    return nil
                case "message_delta":
                    if let usage = json["usage"] as? [String: Any],
                       let output = usage["output_tokens"] as? Int {
                        return TokenUsage(inputTokens: 0, outputTokens: output)
                    }
                    return nil
                default:
                    return nil
                }
            },
            handleLine: { line, event in
                guard line.hasPrefix("data: ") else { return .skip }
                let payload = String(line.dropFirst(6))

                switch event {
                case "content_block_delta":
                    guard let data = payload.data(using: .utf8),
                          let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                          let delta = json["delta"] as? [String: Any] else {
                        return .skip
                    }
                    let deltaType = delta["type"] as? String ?? ""
                    if deltaType == "text_delta", let text = delta["text"] as? String {
                        return .emit(text)
                    }
                    // ⚠️ `thinking_delta` is deliberately NOT emitted. This branch was unreachable
                    // until thinking was wired into the streaming builder, because that builder
                    // never set `body["thinking"]` — so emitting it was a latent bug, not a
                    // feature: this stream is the bot's visible reply and has no second sink, so
                    // reasoning would splice straight into the answer text with no separation.
                    // The agent path keeps its reasoning: `generateCognitiveStep` parses
                    // `thinking` blocks into `ModernCognitiveStep.thought`, which the UI renders
                    // apart from the response.
                    // input_json_delta (tool-call argument streaming) is ignored in bot mode.
                    return .skip
                case "message_stop":
                    return .finish
                case "error":
                    var errorMessage = "Anthropic stream error"
                    if let data = payload.data(using: .utf8),
                       let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                       let errorObj = json["error"] as? [String: Any],
                       let msg = errorObj["message"] as? String {
                        errorMessage = msg
                    }
                    return .fail(LLMProviderError.invalidResponse(errorMessage))
                default:
                    return .skip
                }
            }
        )
    }

    // MARK: - Private Helpers

    /// Translates standard roles to Anthropic's expected format.
    /// Anthropic strictly requires `user` and `assistant` roles in the messages array,
    /// and extracts the `system` role to a top-level parameter.
    private func translateMessages(_ messages: [[String: String]]) -> (system: String?, anthropicMessages: [[String: Any]]) {
        var systemPrompt = ""
        var anthropicMessages: [[String: Any]] = []

        for msg in messages {
            let role = msg["role"] ?? "user"
            let text = msg["content"] ?? ""

            if role == "system" {
                if !systemPrompt.isEmpty { systemPrompt += "\n\n" }
                systemPrompt += text
            } else {
                let anthropicRole = (role == "assistant") ? "assistant" : "user"
                anthropicMessages.append([
                    "role": anthropicRole,
                    "content": text
                ])
            }
        }

        return (systemPrompt.isEmpty ? nil : systemPrompt, anthropicMessages)
    }
}

// MARK: - Test Seam

// ⚠️ Thin pass-throughs to the private builders above — they add NO logic of their own, which is
// the only reason asserting on them is equivalent to asserting on a live request.
extension ClaudeLLMProvider {

    /// Renders the agent/cognitive-step request body without issuing a request.
    func debugRequestBody(messages: [[String: String]], tools: [[String: Any]]?) -> [String: Any] {
        let (systemPrompt, anthropicMessages) = translateMessages(messages)
        return cognitiveStepBody(
            anthropicMessages: anthropicMessages, systemPrompt: systemPrompt, tools: tools)
    }

    /// Renders the bot/streaming request body without opening a stream.
    func debugStreamingRequestBody(messages: [[String: String]]) -> [String: Any] {
        let (systemPrompt, anthropicMessages) = translateMessages(messages)
        return streamingBody(anthropicMessages: anthropicMessages, systemPrompt: systemPrompt)
    }

    /// Builds the request (headers only matter) without issuing it.
    func debugMakeRequest() -> URLRequest { makeRequest() }
}
