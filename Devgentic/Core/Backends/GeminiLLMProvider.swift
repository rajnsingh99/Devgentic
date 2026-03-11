//
//  GeminiLLMProvider.swift
//  Devgentic
//
//  Created by Raj Singh on 27/02/26.
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
    
    // MARK: - Agent Flow (NativeAPI Tool Interception)
    
    func generate(messages: [[String: String]], tools: [[String: Any]]?, responseSchema: Any?) async throws -> String {
        let (contents, systemInstruction) = translateMessages(messages)
        
        var body: [String: Any] = ["contents": contents]
        
        // Inject System Instructions (supported natively in Gemini v1beta)
        if let systemInstruction = systemInstruction {
            body["systemInstruction"] = systemInstruction
        }
        
        // Inject Native Tools
        if let tools = tools, !tools.isEmpty {
            body["tools"] = tools
        }
        
        // Note: We use string appending for the endpoint to prevent URL encoding of the colon (:)
        let url = try buildURL(endpoint: ":generateContent", apiKey: config.apiKey)
        
        var request = URLRequest(url: url, timeoutInterval: config.timeout)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        
        let (data, response) = try await URLSession.shared.data(for: request)
        try validateHTTPResponse(response, data: data)
        
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        guard let candidates = json?["candidates"] as? [[String: Any]],
              let firstCandidate = candidates.first else {
            throw LLMProviderError.invalidResponse("Missing candidates in Gemini response.")
        }
        
        // Handle Safety Blockages
        if let finishReason = firstCandidate["finishReason"] as? String, finishReason == "SAFETY" {
            throw LLMProviderError.invalidResponse("Generation blocked by Gemini Safety Settings.")
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
        
        // --- NATIVE THINKING CONFIGURATION ---
        // Enabled for models that support internal reasoning traces (e.g. Gemini 2.0 Thinking)
        body["thinking_config"] = ["include_thoughts": true]
        
        let url = try buildURL(endpoint: ":generateContent", apiKey: config.apiKey)
        
        var request = URLRequest(url: url, timeoutInterval: config.timeout)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        
        let (data, response) = try await URLSession.shared.data(for: request)
        try validateHTTPResponse(response, data: data)
        
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        guard let candidates = json?["candidates"] as? [[String: Any]],
              let firstCandidate = candidates.first else {
            throw LLMProviderError.invalidResponse("Missing candidates in Gemini response.")
        }
        
        if let finishReason = firstCandidate["finishReason"] as? String, finishReason == "SAFETY" {
            throw LLMProviderError.invalidResponse("Generation blocked by Gemini Safety Settings.")
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
                let anyCodableArgs = args.mapValues { AnyCodable($0) }
                pendingTools.append(PendingToolCall(id: UUID().uuidString, name: name, arguments: anyCodableArgs))
            }
        }
        
        let finalReasoning = textResponse.isEmpty && !pendingTools.isEmpty 
            ? "Executing \(pendingTools.count) tools..." 
            : textResponse
            
        let finalThought = thinkingTrace.isEmpty ? nil : thinkingTrace
            
        return ModernCognitiveStep(reasoning: finalReasoning, thought: finalThought, toolCalls: pendingTools)
    }

    // MARK: - Bot Flow (Strict Preservation)
    
    func stream(messages: [[String: String]], tools: [[String: Any]]?) -> AsyncThrowingStream<String, Error> {
        return AsyncThrowingStream { continuation in
            Task {
                do {
                    let (contents, systemInstruction) = translateMessages(messages)
                    
                    var body: [String: Any] = ["contents": contents]
                    if let systemInstruction = systemInstruction {
                        body["systemInstruction"] = systemInstruction
                    }
                    
                    // We intentionally ignore `tools` here to guarantee the Bot flow remains strictly conversational
                    
                    let url = try buildURL(endpoint: ":streamGenerateContent", apiKey: config.apiKey, streamFormat: "sse")
                    
                    var request = URLRequest(url: url, timeoutInterval: config.timeout)
                    request.httpMethod = "POST"
                    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
                    request.httpBody = try JSONSerialization.data(withJSONObject: body)
                    
                    let (bytes, response) = try await URLSession.shared.bytes(for: request)
                    try validateHTTPResponse(response, data: nil)
                    
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
    
    /// Validates the HTTP response status codes.
    private func validateHTTPResponse(_ response: URLResponse, data: Data?) throws {
        guard let httpResponse = response as? HTTPURLResponse else {
            throw LLMProviderError.invalidResponse("Not an HTTP response")
        }
        
        guard (200...299).contains(httpResponse.statusCode) else {
            let body = data.flatMap { String(data: $0, encoding: .utf8) } ?? "Unknown error"
            throw LLMProviderError.httpError(httpResponse.statusCode, body)
        }
    }
}
