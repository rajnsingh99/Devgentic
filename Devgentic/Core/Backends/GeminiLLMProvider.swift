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

private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "com.devgentic.app", category: "GeminiLLMProvider")

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

    // MARK: - Agent Flow (NativeAPI Tool Interception)

    func generate(messages: [[String: String]], tools: [[String: Any]]?, responseSchema: Any?) async throws -> String {
        let (contents, systemInstruction) = translateMessages(messages)

        var body: [String: Any] = ["contents": contents]

        if let systemInstruction = systemInstruction {
            body["systemInstruction"] = systemInstruction
        }

        if let tools = tools, !tools.isEmpty {
            body["tools"] = tools
        }

        if let generationConfig = buildGenerationConfig() {
            body["generationConfig"] = generationConfig
        }

        let url = try buildURL(endpoint: ":generateContent", apiKey: config.apiKey)

        var request = URLRequest(url: url, timeoutInterval: config.timeout)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, _) = try await CloudRequestPipeline.execute(request: request, provider: .geminiFlash)

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
        if let syntheticStep = syntheticStep {
            let syntheticData = try JSONSerialization.data(withJSONObject: syntheticStep)
            return String(data: syntheticData, encoding: .utf8) ?? "{}"
        }

        // Otherwise, return standard text (Task Completion / User Clarification)
        return textResponse
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

        if let generationConfig = buildGenerationConfig() {
            body["generationConfig"] = generationConfig
        }

        // --- NATIVE THINKING CONFIGURATION ---
        // Enabled for models that support internal reasoning traces (e.g. Gemini 2.0 Thinking)
        body["thinking_config"] = ["include_thoughts": true]

        let url = try buildURL(endpoint: ":generateContent", apiKey: config.apiKey)

        var request = URLRequest(url: url, timeoutInterval: config.timeout)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, _) = try await CloudRequestPipeline.execute(request: request, provider: .geminiFlash)

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

        let finalReasoning = textResponse.isEmpty && !pendingTools.isEmpty
            ? "Executing \(pendingTools.count) tools..."
            : textResponse

        let finalThought = thinkingTrace.isEmpty ? nil : thinkingTrace

        return ModernCognitiveStep(reasoning: finalReasoning, thought: finalThought, toolCalls: pendingTools)
    }

    // MARK: - Bot Flow (Streaming)

    func stream(messages: [[String: String]], tools: [[String: Any]]?) -> AsyncThrowingStream<String, Error> {
        return AsyncThrowingStream { continuation in
            Task {
                do {
                    let (contents, systemInstruction) = translateMessages(messages)

                    var body: [String: Any] = ["contents": contents]
                    if let systemInstruction = systemInstruction {
                        body["systemInstruction"] = systemInstruction
                    }

                    if let generationConfig = buildGenerationConfig() {
                        body["generationConfig"] = generationConfig
                    }

                    // We intentionally ignore `tools` here to guarantee the Bot flow remains strictly conversational

                    let url = try buildURL(endpoint: ":streamGenerateContent", apiKey: config.apiKey, streamFormat: "sse")

                    var request = URLRequest(url: url, timeoutInterval: config.timeout)
                    request.httpMethod = "POST"
                    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
                    request.httpBody = try JSONSerialization.data(withJSONObject: body)

                    let (bytes, _) = try await CloudRequestPipeline.executeStream(request: request, provider: .geminiFlash)

                    // Parse Server-Sent Events (SSE)
                    for try await line in bytes.lines {
                        guard line.hasPrefix("data: ") else { continue }
                        let payload = String(line.dropFirst(6))

                        if payload.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { continue }

                        guard let data = payload.data(using: .utf8),
                              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                              let candidates = json["candidates"] as? [[String: Any]],
                              let firstCandidate = candidates.first,
                              let content = firstCandidate["content"] as? [String: Any],
                              let parts = content["parts"] as? [[String: Any]],
                              let firstPart = parts.first,
                              let text = firstPart["text"] as? String else {
                            continue
                        }

                        continuation.yield(text)
                    }

                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
        }
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
    private func buildURL(endpoint: String, apiKey: String?, streamFormat: String? = nil) throws -> URL {
        let fullPath = config.baseURL.absoluteString + endpoint
        guard var components = URLComponents(string: fullPath) else {
            throw URLError(.badURL)
        }

        var queryItems: [URLQueryItem] = []
        if let key = apiKey {
            queryItems.append(URLQueryItem(name: "key", value: key))
        }
        if let alt = streamFormat {
            queryItems.append(URLQueryItem(name: "alt", value: alt))
        }

        if !queryItems.isEmpty {
            components.queryItems = queryItems
        }

        guard let finalURL = components.url else {
            throw URLError(.badURL)
        }

        return finalURL
    }
}
