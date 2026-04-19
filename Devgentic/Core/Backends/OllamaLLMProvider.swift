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

        let (data, response) = try await URLSession.shared.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse,
              (200...299).contains(httpResponse.statusCode) else {
            let body = String(data: data, encoding: .utf8) ?? "Unknown error"
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            throw LLMProviderError.httpError(status, body)
        }

        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        guard let message = json?["message"] as? [String: Any] else {
            throw LLMProviderError.invalidResponse("Missing message object in Ollama response")
        }

        let content = message["content"] as? String ?? ""
        return content
    }

    func generateCognitiveStep(messages: [[String: String]], tools: [[String: Any]]?) async throws -> ModernCognitiveStep {
        let url = config.baseURL.appendingPathComponent("api/chat")
        var request = URLRequest(url: url, timeoutInterval: config.timeout)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

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

        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        let requestBodyBytes = request.httpBody?.count ?? 0

        let httpStart = Date()
        let (data, response) = try await URLSession.shared.data(for: request)
        let httpWallDuration = Date().timeIntervalSince(httpStart)

        guard let httpResponse = response as? HTTPURLResponse,
              (200...299).contains(httpResponse.statusCode) else {
            let bodyStr = String(data: data, encoding: .utf8) ?? "Unknown error"
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0

            // Detect the specific "does not support thinking" 400 so the caller can auto-heal.
            if status == 400 && bodyStr.lowercased().contains("does not support thinking") {
                throw LLMProviderError.thinkingUnsupported(modelName: config.modelName)
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

        if let toolCalls = message["tool_calls"] as? [[String: Any]] {
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
        if pendingTools.isEmpty && !content.isEmpty {
            let (prose, jsonBlock) = Self.splitProseAndJSON(content)
            let pipeline = CognitiveParsePipeline(
                expectedDialect: .nativeJSON,
                modelId: config.modelName
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
                tokenUsage: usage ?? parsed.tokenUsage
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
    /// If no balanced JSON block is found, returns `(content, "")` so callers
    /// can fall back to passing the original content to the parser.
    static func splitProseAndJSON(_ content: String) -> (prose: String, jsonBlock: String) {
        var depth = 0
        var startIndex: String.Index?
        var inString = false
        var prevChar: Character = "\0"
        let openers: Set<Character> = ["{", "["]
        let closers: Set<Character> = ["}", "]"]

        for (index, char) in zip(content.indices, content) {
            if char == "\"" && prevChar != "\\" {
                inString.toggle()
            }
            if !inString {
                if openers.contains(char) {
                    if depth == 0 { startIndex = index }
                    depth += 1
                } else if closers.contains(char) {
                    depth -= 1
                    if depth == 0, let start = startIndex {
                        let prose = String(content[..<start]).trimmingCharacters(in: .whitespacesAndNewlines)
                        let jsonBlock = String(content[start...index])
                        return (prose, jsonBlock)
                    }
                }
            }
            prevChar = char
        }
        return (content.trimmingCharacters(in: .whitespacesAndNewlines), "")
    }

    func stream(messages: [[String: String]], tools: [[String: Any]]?) -> AsyncThrowingStream<String, Error> {
        return AsyncThrowingStream { continuation in
            Task {
                do {
                    let url = config.baseURL.appendingPathComponent("api/chat")
                    var request = URLRequest(url: url, timeoutInterval: config.timeout)
                    request.httpMethod = "POST"
                    request.setValue("application/json", forHTTPHeaderField: "Content-Type")

                    var body: [String: Any] = [
                        "model": config.modelName,
                        "messages": messages,
                        "stream": true
                    ]

                    if let options = config.options {
                        body["options"] = mapToOllamaOptions(options)
                    }

                    // Ollama supports tools natively as well
                    if let tools = tools, !tools.isEmpty {
                        body["tools"] = tools
                    }

                    request.httpBody = try JSONSerialization.data(withJSONObject: body)

                    let (bytes, response) = try await URLSession.shared.bytes(for: request)

                    guard let httpResponse = response as? HTTPURLResponse,
                          (200...299).contains(httpResponse.statusCode) else {
                        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
                        throw LLMProviderError.httpError(status, "Ollama streaming error")
                    }

                    // Ollama streams newline-delimited JSON objects
                    for try await line in bytes.lines {
                        guard !line.isEmpty,
                              let lineData = line.data(using: .utf8),
                              let json = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any],
                              let message = json["message"] as? [String: Any],
                              let content = message["content"] as? String else {
                            continue
                        }

                        continuation.yield(content)

                        // Check if Ollama signals completion
                        if let done = json["done"] as? Bool, done { break }
                    }

                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
        }
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
