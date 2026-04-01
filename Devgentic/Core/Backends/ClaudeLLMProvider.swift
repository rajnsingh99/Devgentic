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

private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "com.devgentic.app", category: "ClaudeLLMProvider")

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
    private var thinkingBudget: Int {
        if case .number(let val) = config.options?["thinkingBudgetTokens"] { return Int(val) }
        return 10000
    }

    /// Applies common generation parameters to the request body.
    private func applyGenerationParams(to body: inout [String: Any]) {
        // When extended thinking is enabled, temperature must be omitted or 1.0
        if !extendedThinking, let temp = temperature {
            body["temperature"] = temp
        }
        if let topP = topP { body["top_p"] = topP }
        if let topK = topK { body["top_k"] = topK }
        if let stops = stopSequences, !stops.isEmpty { body["stop_sequences"] = stops }
    }

    /// Creates a standard Anthropic URLRequest with proper headers.
    private func makeRequest(streaming: Bool = false) -> URLRequest {
        let url = config.baseURL.appendingPathComponent("messages")
        var request = URLRequest(url: url, timeoutInterval: config.timeout)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        // Use newer API version when extended thinking is enabled
        let apiVersion = extendedThinking ? "2025-04-14" : "2023-06-01"
        request.setValue(apiVersion, forHTTPHeaderField: "anthropic-version")

        if let apiKey = config.apiKey {
            request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        }
        return request
    }

    // MARK: - Agent Flow (NativeAPI Tool Interception)

    func generate(messages: [[String: String]], tools: [[String: Any]]?, responseSchema: Any?) async throws -> String {
        let (systemPrompt, anthropicMessages) = translateMessages(messages)

        var body: [String: Any] = [
            "model": config.modelName,
            "messages": anthropicMessages,
            "max_tokens": maxTokens
        ]

        applyGenerationParams(to: &body)

        if let systemPrompt = systemPrompt {
            body["system"] = systemPrompt
        }

        if let tools = tools, !tools.isEmpty {
            body["tools"] = tools
        }

        var request = makeRequest()
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, _) = try await CloudRequestPipeline.execute(request: request, provider: .anthropic)

        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]

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
            return String(data: syntheticData, encoding: .utf8) ?? "{}"
        }

        // Otherwise, return standard text (Task Completion / User Clarification)
        return textResponse.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func generateCognitiveStep(messages: [[String: String]], tools: [[String: Any]]?) async throws -> ModernCognitiveStep {
        let (systemPrompt, anthropicMessages) = translateMessages(messages)

        // When thinking is enabled, max_tokens must be strictly greater than budget_tokens
        let effectiveMaxTokens = extendedThinking ? max(maxTokens, thinkingBudget + 1024) : maxTokens

        var body: [String: Any] = [
            "model": config.modelName,
            "messages": anthropicMessages,
            "max_tokens": effectiveMaxTokens
        ]

        applyGenerationParams(to: &body)

        // --- EXTENDED THINKING CONFIGURATION ---
        // Driven by user's advanced config, not model name string matching.
        if extendedThinking {
            body["thinking"] = ["type": "enabled", "budget_tokens": thinkingBudget]
        }

        if let systemPrompt = systemPrompt {
            body["system"] = systemPrompt
        }

        if let tools = tools, !tools.isEmpty {
            body["tools"] = tools
        }

        var request = makeRequest()
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, _) = try await CloudRequestPipeline.execute(request: request, provider: .anthropic)

        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]

        // Defensive check: warn if response was truncated by max_tokens limit
        let effectiveLimit = extendedThinking ? max(maxTokens, thinkingBudget + 1024) : maxTokens
        if let stopReason = json?["stop_reason"] as? String, stopReason == "max_tokens" {
            logger.warning("⚠️ Anthropic cognitive step truncated (stop_reason: max_tokens). Effective max_tokens: \(effectiveLimit) (thinking: \(self.extendedThinking), budget: \(self.thinkingBudget)). Tool calls may have been cut off — consider increasing maxTokens in advanced config.")
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
        let fallbackReasoning = finalReasoning.isEmpty && !pendingTools.isEmpty ? "Executing \(pendingTools.count) tools..." : finalReasoning

        return ModernCognitiveStep(reasoning: fallbackReasoning, thought: finalThought, toolCalls: pendingTools)
    }

    // MARK: - Bot Flow (Streaming)

    func stream(messages: [[String: String]], tools: [[String: Any]]?) -> AsyncThrowingStream<String, Error> {
        return AsyncThrowingStream { continuation in
            Task {
                do {
                    let (systemPrompt, anthropicMessages) = translateMessages(messages)

                    var body: [String: Any] = [
                        "model": config.modelName,
                        "messages": anthropicMessages,
                        "max_tokens": maxTokens,
                        "stream": true
                    ]

                    applyGenerationParams(to: &body)

                    if let systemPrompt = systemPrompt {
                        body["system"] = systemPrompt
                    }

                    var request = makeRequest(streaming: true)
                    request.httpBody = try JSONSerialization.data(withJSONObject: body)

                    let (bytes, _) = try await CloudRequestPipeline.executeStream(request: request, provider: .anthropic)

                    // Parse Server-Sent Events (SSE)
                    var currentEvent = ""

                    for try await line in bytes.lines {
                        if line.hasPrefix("event: ") {
                            currentEvent = String(line.dropFirst(7)).trimmingCharacters(in: .whitespacesAndNewlines)
                        } else if line.hasPrefix("data: ") {
                            let payload = String(line.dropFirst(6))

                            if currentEvent == "content_block_delta" {
                                guard let data = payload.data(using: .utf8),
                                      let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                                      let delta = json["delta"] as? [String: Any] else {
                                    continue
                                }

                                let deltaType = delta["type"] as? String ?? ""

                                if deltaType == "text_delta", let text = delta["text"] as? String {
                                    // Standard text output
                                    continuation.yield(text)
                                } else if deltaType == "thinking_delta", let thinking = delta["thinking"] as? String {
                                    // Extended thinking trace — yield for display
                                    continuation.yield(thinking)
                                } else if deltaType == "input_json_delta" {
                                    // Tool use argument streaming — log but don't yield in bot mode
                                    logger.debug("Stream tool argument delta received (bot mode ignores)")
                                }
                            } else if currentEvent == "message_stop" {
                                // Clean termination signal
                                break
                            } else if currentEvent == "error" {
                                logger.error("Anthropic stream returned an error event: \(payload)")

                                var errorMessage = "Anthropic stream error"
                                if let data = payload.data(using: .utf8),
                                   let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                                   let errorObj = json["error"] as? [String: Any],
                                   let msg = errorObj["message"] as? String {
                                    errorMessage = msg
                                }

                                continuation.finish(throwing: LLMProviderError.invalidResponse(errorMessage))
                                return
                            }
                        }
                    }

                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
        }
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
