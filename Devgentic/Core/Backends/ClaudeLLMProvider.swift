// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
//
//  ClaudeLLMProvider.swift
//  Devgentic
//
//  Created by Raj Singh.
//

import Foundation
import OSLog

private let logger = DGLogger(category: "ClaudeLLMProvider")

/// Handles the official Anthropic Claude API via REST.
/// Adapts Devgentic's standard message payloads to Claude's unique top-level system prompt
/// and `tool_use` content blocks.
struct ClaudeLLMProvider: LLMProvider {
    /// The model this provider's calls are priced as (`ModelPriceList`).
    var pricingKey: PricingKey { PricingKey(provider: .anthropic, model: config.modelName) }

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
    /// Only consulted on `.legacyBudget` models; Opus 4.7+ / Sonnet 5 / Fable 5 reject it and use `thinkingEffort`.
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

    /// Max output tokens actually sent. On the legacy thinking path the API requires `max_tokens` > `budget_tokens`, so
    /// the value is floored. Adaptive-era models carry no budget, so the user's value is sent verbatim (inflating it would
    /// change what they are billed).
    private var effectiveMaxTokens: Int {
        guard extendedThinking, !generation.usesAdaptiveThinking else { return maxTokens }
        return max(maxTokens, thinkingBudget + 1024)
    }

    /// Applies sampling parameters, gated on what the selected model accepts; a wrong combination is a 400.
    /// `temperature`/`top_p`/`top_k` are removed on Opus 4.7+ / Sonnet 5 / Fable 5, Claude 4+ rejects `temperature` with
    /// `top_p`, and extended thinking forbids sampling parameters on the rest. `stop_sequences` is always forwarded.
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

    /// Applies the thinking configuration in whichever shape the selected model accepts; every request builder calls it.
    /// `requestSummary` asks for readable reasoning via `display: "summarized"`: adaptive-era models default to `omitted`,
    /// which streams empty thinking text, so builders whose `thought` the UI renders opt in and others leave it off.
    private func applyThinking(to body: inout [String: Any], requestSummary: Bool = false) {
        guard generation.usesAdaptiveThinking else {
            // Legacy tier: thinking is opt-in via budget_tokens, and omitting the key means off.
            if extendedThinking {
                body["thinking"] = ["type": "enabled", "budget_tokens": thinkingBudget]
            }
            return
        }

        if !extendedThinking {
            switch generation.thinkingOffShape {
            case .disabled:
                // Explicit disable, not omission: thinking is on by default on Opus 5 and Sonnet 5. `output_config` stays unset
                // because `xhigh`/`max` effort is rejected alongside disabled thinking, so sending nothing cannot 400.
                body["thinking"] = ["type": "disabled"]
                return

            case .betweenTools:
                // Sonnet 5.5's "off": `disabled` is a 400. `between_tools` is sent bare (`display` makes it a 400, so `requestSummary`
                // is ignored) and is rejected at `xhigh`/`max`, so no effort is sent and the accepted default (`high`) applies.
                body["thinking"] = ["type": "between_tools"]
                if let effort = thinkingEffort {
                    logger.notice("""
                        [ANTHROPIC] Effort '\(effort)' not sent for model '\(config.modelName)' — \
                        thinking is OFF, which this model expresses as {"type": "between_tools"}, \
                        and that shape takes no other setting. CONSEQUENCE: the request runs at the \
                        API default effort; turn thinking on for the effort control to apply.
                        """)
                }
                return

            case .notOffered:
                // Falling through with thinking off is deliberate for Fable 5 / Mythos 5 / Opus 5.5, which cannot disable thinking:
                // `disabled` is a 400 and adaptive equals omitting the key. The log covers a profile re-pointed from another model.
                logger.notice("""
                    [ANTHROPIC] Extended Thinking is OFF in the profile but cannot be honoured for \
                    model '\(config.modelName)' (generation: \(generation.rawValue)) — thinking is \
                    always on for this model and sending {"type": "disabled"} returns 400. \
                    CONSEQUENCE: the request runs WITH thinking; the toggle has no effect here, and \
                    `max_tokens` (\(effectiveMaxTokens)) caps thinking and reply text together.
                    """)
            }
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
                request runs at the API default effort (\(AnthropicModelGeneration.defaultEffort(for: config.modelName))) \
                instead of the configured level.
                """)
            return
        }
        body["output_config"] = ["effort": effort]
    }

    // MARK: - Request Body Builders

    // These let the shape assertions in `AnthropicRequestShapeTests` exercise the same code the shipped builders run;
    // a test that rebuilds the body itself only proves its own copy.

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
        if let systemPrompt = systemPrompt, !systemPrompt.isEmpty { body["system"] = systemPrompt }
        if let tools = tools, !tools.isEmpty { body["tools"] = tools }
        // An agent step is sent again with each tool result appended: mark its reusable prefix.
        AnthropicPromptCaching.markBreakpoints(in: &body)
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
        // A bot conversation's next message shares this one's system message and history.
        AnthropicPromptCaching.markBreakpoints(in: &body)
        return body
    }

    /// Creates a standard Anthropic URLRequest with proper headers.
    private func makeRequest(streaming: Bool = false) -> URLRequest {
        let url = config.baseURL.appendingPathComponent("messages")
        var request = URLRequest(url: url, timeoutInterval: config.timeout)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        // `anthropic-version` has only two valid values ("2023-06-01", "2023-01-01") and is not a feature switch: dated capabilities ship behind
        // `anthropic-beta`. Any other value rejects every request from the profile.
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
        let usage = json.flatMap { TokenUsage.fromAnthropic($0, pricing: pricingKey) }

        // A refusal is HTTP 200, so it is checked before anything reads the content; then warn if max_tokens truncated.
        if let refusal = Self.refusalError(in: json) { throw refusal }
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

    // MARK: - Multimodal (native image input)

    /// Translates provider-agnostic `[ProviderMessage]` into Anthropic messages, emitting native content-block arrays for
    /// image blocks; text-only messages stay a plain content string. Resolving image bytes can throw, and the error
    /// propagates to the caller, never a silent drop.
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
        // The image path is a bot conversation too (any image makes every later turn take it), and
        // it re-sends prior images each message — the most expensive prefix to re-read.
        AnthropicPromptCaching.markBreakpoints(in: &body)

        var request = makeRequest()
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, _) = try await CloudRequestPipeline.execute(request: request, provider: .anthropic, rateLimitKey: config.rateLimitKey)
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        logCacheUsage(json.flatMap { TokenUsage.fromAnthropic($0, pricing: pricingKey) }, path: "image")

        // A refusal is HTTP 200, so it is checked before anything reads the content.
        if let refusal = Self.refusalError(in: json) { throw refusal }
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

        // Warns if the response was truncated by max_tokens. On the adaptive tier `max_tokens` caps thinking and response text
        // together, so a profile tuned before thinking was enabled can truncate. A refusal is HTTP 200, so it is checked first.
        if let refusal = Self.refusalError(in: json) { throw refusal }
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
        let usage = json.flatMap { TokenUsage.fromAnthropic($0, pricing: pricingKey) }
        logCacheUsage(usage, path: "agent-text")

        // Empty reasoning stays empty: the UI derives "Executing <tool>..." labels from .toolCall events, not this field, and a
        // placeholder would pollute any scratchpad injection with meaningless text.
        return ModernCognitiveStep(reasoning: finalReasoning, thought: finalThought, toolCalls: pendingTools, tokenUsage: usage,
                                   reasoningReplay: pendingTools.isEmpty ? nil : Self.thinkingReplay(in: contentBlocks))
    }

    // MARK: - Native-Turn Cognitive Step (G12)

    /// Native-turn overload. Accepts provider-shape messages from `ClaudeToolTurnAdapter` (which may contain `tool_use` /
    /// `tool_result` content arrays) plus canonical `{role, content: string}` messages from PromptBuilder; extracts
    /// `role: "system"` messages into Claude's top-level `system` field.
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

        // The SAME builder as the text path (thinking summary, tools, cache breakpoints), so the
        // shape tests that render `cognitiveStepBody` cover this path too.
        let body = cognitiveStepBody(anthropicMessages: anthropicMessages, systemPrompt: systemPrompt, tools: tools)

        var request = makeRequest()
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, _) = try await CloudRequestPipeline.execute(request: request, provider: .anthropic, rateLimitKey: config.rateLimitKey)

        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]

        // A refusal is HTTP 200, so it is checked before anything reads the content.
        if let refusal = Self.refusalError(in: json) { throw refusal }
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
        let usage = json.flatMap { TokenUsage.fromAnthropic($0, pricing: pricingKey) }
        logCacheUsage(usage, path: "agent")

        return ModernCognitiveStep(reasoning: finalReasoning, thought: finalThought, toolCalls: pendingTools, tokenUsage: usage,
                                   reasoningReplay: pendingTools.isEmpty ? nil : Self.thinkingReplay(in: contentBlocks))
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
            // Usage arrives in two partials (input on `message_start`, output on `message_delta`);
            // the parser combines them, and the call is priced once, whole — see `TokenUsage.priced`.
            onUsage: onUsage.map { report in
                let key = pricingKey
                return { @Sendable usage in report(usage.priced(key)) }
            },
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
                       let input = TokenUsage.anthropicInput(usage) {
                        let partial = TokenUsage(inputTokens: input.total, outputTokens: 0,
                                                 cacheReadTokens: input.read, cacheWriteTokens: input.written)
                        self.logCacheUsage(partial, path: "bot")
                        return partial
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
            // The decoder itself, not a closure around it, so tests run exactly this.
            handleLine: Self.anthropicStreamLine
        )
    }

    // MARK: - Stream decode (static so it is testable without a network)

    /// One SSE line of an Anthropic stream.
    static func anthropicStreamLine(_ line: String, _ event: String) -> SSELineDirective {
        guard line.hasPrefix("data: ") else { return .skip }
        let payload = String(line.dropFirst(6))
        let json = payload.data(using: .utf8).flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }

        switch event {
        case "content_block_delta":
            guard let delta = json?["delta"] as? [String: Any] else { return .skip }
            if delta["type"] as? String == "text_delta", let text = delta["text"] as? String {
                return .emit(text)
            }
            // `thinking_delta` is deliberately not emitted: this stream is the bot's visible reply with no second sink, so reasoning
            // would splice into the answer. The agent path keeps reasoning via `ModernCognitiveStep.thought`.
            return .skip
        case "message_delta":
            // A refusal arrives here as a stop reason on a 200 stream; without this the stream ends with an empty or cut-off answer.
            if let refusal = refusalError(in: json) {
                logger.notice("[ANTHROPIC] Stream ended in a REFUSAL (\(refusal.localizedDescription)). CONSEQUENCE: the turn fails with that reason instead of saving a silent partial answer; not retried.")
                return .fail(refusal)
            }
            return .skip
        case "message_stop":
            return .finish
        case "error":
            let error = json?["error"] as? [String: Any]
            let type = error?["type"] as? String
            let message = error?["message"] as? String ?? "Anthropic stream error"
            // Mapped to the HTTP status it stands for, so the retry classifier treats an in-stream `overloaded_error` like the
            // same failure sent as a 529.
            if let status = streamErrorStatus(forType: type) {
                logger.notice("[ANTHROPIC] In-stream error '\(type ?? "?")' mapped to HTTP \(status). CONSEQUENCE: classified like that status — retried when transient (overloaded, rate limit, server error), fatal otherwise.")
                return .fail(LLMProviderError.httpError(status, payload))
            }
            logger.error("[ANTHROPIC] In-stream error of unknown type '\(type ?? "nil")': \(message). CONSEQUENCE: the turn fails as an invalid response and is not retried.")
            return .fail(LLMProviderError.invalidResponse(message))
        default:
            return .skip
        }
    }

    /// The response's `thinking` / `redacted_thinking` blocks verbatim, signature included, for replay on the next tool turn;
    /// nil when there are none. Anthropic requires the last assistant turn's thinking blocks to be passed back unchanged when
    /// a tool loop continues on the same model, so they are only replayed into the same run, on the same model, unedited.
    static func thinkingReplay(in blocks: [[String: Any]]) -> JSONValue? {
        let thinking = blocks.filter { ["thinking", "redacted_thinking"].contains($0["type"] as? String ?? "") }
        guard !thinking.isEmpty else { return nil }
        return .array(thinking.compactMap { JSONValue($0) })
    }

    /// The HTTP status an Anthropic stream `error.type` corresponds to, or nil for one this table does
    /// not know. Mirrors Anthropic's documented error types.
    static func streamErrorStatus(forType type: String?) -> Int? {
        switch type {
        case "invalid_request_error": return 400
        case "authentication_error": return 401
        case "billing_error": return 402
        case "permission_error": return 403
        case "not_found_error": return 404
        case "request_too_large": return 413
        case "rate_limit_error": return 429
        case "api_error": return 500
        case "timeout_error": return 504
        case "overloaded_error": return 529
        default: return nil
        }
    }

    /// The refusal in a response or a `message_delta`, or nil. Reads `stop_details` (category +
    /// explanation) so the user is told WHY, not merely that it happened.
    static func refusalError(in json: [String: Any]?) -> LLMProviderError? {
        let delta = json?["delta"] as? [String: Any]
        let stopReason = (json?["stop_reason"] as? String) ?? (delta?["stop_reason"] as? String)
        guard stopReason == "refusal" else { return nil }
        let details = (json?["stop_details"] as? [String: Any]) ?? (delta?["stop_details"] as? [String: Any])
        let parts = [(details?["category"] as? String).map { "category: \($0)" }, details?["explanation"] as? String]
            .compactMap { $0 }.filter { !$0.isEmpty }
        return .refused(provider: "Claude", detail: parts.isEmpty ? "no reason given" : parts.joined(separator: " — "))
    }

    // MARK: - Private Helpers

    /// `[ANTHROPIC-CACHE]` — how much of a breakpoint-marked request's prompt came from the cache.
    /// The only evidence that caching works: nothing else in a run changes when it does.
    private func logCacheUsage(_ usage: TokenUsage?, path: String) {
        guard let usage else { return }
        let uncached = usage.inputTokens - usage.cacheReadTokens - usage.cacheWriteTokens
        if usage.cacheReadTokens > 0 || usage.cacheWriteTokens > 0 {
            logger.info("[ANTHROPIC-CACHE] \(path) '\(self.config.modelName)': read \(usage.cacheReadTokens), wrote \(usage.cacheWriteTokens), uncached \(uncached) of \(usage.inputTokens) prompt tokens.")
        } else {
            logger.debug("[ANTHROPIC-CACHE] \(path) '\(self.config.modelName)': nothing cached for \(usage.inputTokens) prompt tokens. CONSEQUENCE: none if the prefix is under the model's cache minimum (~1,024 tokens); otherwise the breakpoints are not matching between requests.")
        }
    }

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

// Thin pass-throughs to the private builders above that add no logic, so asserting on them equals asserting on a
// live request.
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
