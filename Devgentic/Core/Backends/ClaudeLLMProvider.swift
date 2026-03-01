//
//  ClaudeLLMProvider.swift
//  Devgentic
//
//  Created by Raj Singh on 27/02/26.
//

import Foundation
import OSLog

private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "com.devgentic.app", category: "ClaudeProvider")

/// Handles the official Anthropic Claude API via REST.
/// Adapts Devgentic's standard message payloads to Claude's unique top-level system prompt
/// and `tool_use` content blocks.
struct ClaudeLLMProvider: LLMProvider {
    
    let config: LLMProviderConfig
    
    init(config: LLMProviderConfig) {
        self.config = config
    }
    
    // MARK: - Agent Flow (NativeAPI Tool Interception)
    
    func generate(messages: [[String: String]], tools: [[String: Any]]?, responseSchema: [String: Any]?) async throws -> String {
        let (systemPrompt, anthropicMessages) = translateMessages(messages)
        
        var body: [String: Any] = [
            "model": config.modelName,
            "messages": anthropicMessages,
            "max_tokens": 4096 // Anthropic requires max_tokens to be explicitly set
        ]
        
        if let systemPrompt = systemPrompt {
            body["system"] = systemPrompt
        }
        
        if let tools = tools, !tools.isEmpty {
            body["tools"] = tools
        }
        
        let url = config.baseURL.appendingPathComponent("messages")
        var request = URLRequest(url: url, timeoutInterval: config.timeout)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        
        if let apiKey = config.apiKey {
            request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        }
        
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        
        let (data, response) = try await URLSession.shared.data(for: request)
        try validateHTTPResponse(response, data: data)
        
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        
        guard let contentBlocks = json?["content"] as? [[String: Any]] else {
            throw LLMProviderError.invalidResponse("Missing content blocks in Anthropic response.")
        }
        
        var textResponse = ""
        var syntheticStep: [String: Any]? = nil
        
        // Parse parts for both Text (Reasoning) and Tool Use
        for block in contentBlocks {
            if let type = block["type"] as? String {
                if type == "text" {
                    textResponse += (block["text"] as? String ?? "")
                } else if type == "tool_use" {
                    // --- NATIVE TOOL INTERCEPTION BRIDGE ---
                    let toolName = block["name"] as? String ?? "unknown_tool"
                    let inputArgs = block["input"] as? [String: Any] ?? [:]
                    
                    syntheticStep = [
                        "content": textResponse.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "Executing tool \(toolName)..." : textResponse.trimmingCharacters(in: .whitespacesAndNewlines),
                        "tool_name": toolName,
                        "arguments": inputArgs
                    ]
                }
            }
        }
        
        // If the model called a tool, intercept and return the synthesized LeanCognitiveStep JSON string
        if let syntheticStep = syntheticStep {
            let syntheticData = try JSONSerialization.data(withJSONObject: syntheticStep)
            return String(data: syntheticData, encoding: .utf8) ?? "{}"
        }
        
        // Otherwise, return standard text (Task Completion / User Clarification)
        return textResponse.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - Bot Flow (Strict Preservation)
    
    func stream(messages: [[String: String]], tools: [[String: Any]]?) -> AsyncThrowingStream<String, Error> {
        return AsyncThrowingStream { continuation in
            Task {
                do {
                    let (systemPrompt, anthropicMessages) = translateMessages(messages)
                    
                    var body: [String: Any] = [
                        "model": config.modelName,
                        "messages": anthropicMessages,
                        "max_tokens": 4096,
                        "stream": true
                    ]
                    
                    if let systemPrompt = systemPrompt {
                        body["system"] = systemPrompt
                    }
                    
                    let url = config.baseURL.appendingPathComponent("messages")
                    var request = URLRequest(url: url, timeoutInterval: config.timeout)
                    request.httpMethod = "POST"
                    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
                    request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
                    
                    if let apiKey = config.apiKey {
                        request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
                    }
                    
                    request.httpBody = try JSONSerialization.data(withJSONObject: body)
                    
                    let (bytes, response) = try await URLSession.shared.bytes(for: request)
                    try validateHTTPResponse(response, data: nil)
                    
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
                                      let delta = json["delta"] as? [String: Any],
                                      let text = delta["text"] as? String else {
                                    continue
                                }
                                continuation.yield(text)
                            } else if currentEvent == "error" {
                                logger.error("Anthropic stream returned an error event: \(payload)")
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
    
    /// Validates the HTTP response status codes.
    private func validateHTTPResponse(_ response: URLResponse, data: Data?) throws {
        guard let httpResponse = response as? HTTPURLResponse else {
            throw LLMProviderError.invalidResponse("Not an HTTP response")
        }
        
        guard (200...299).contains(httpResponse.statusCode) else {
            let body = data.flatMap { String(data: $0, encoding: .utf8) } ?? "Unknown error"
            
            // Anthropic specific error formatting
            if httpResponse.statusCode == 429 && body.lowercased().contains("overloaded") {
                throw LLMProviderError.httpError(429, "Anthropic API is currently overloaded. Please try again in a moment.")
            }
            
            throw LLMProviderError.httpError(httpResponse.statusCode, body)
        }
    }
}
