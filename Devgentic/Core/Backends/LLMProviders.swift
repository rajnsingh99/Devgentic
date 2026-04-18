//
//  LLMProviders.swift
//  Devgentic
//
//  Created by Devgentic Architect
//
//  URLSession-based LLM provider implementations replacing
//  OllamaLanguageModel, OpenAILanguageModel, and MLXLanguageModel.
//

import Foundation
import OSLog

private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "com.devgentic.app", category: "LLMProviders")

// MARK: - LLM Provider Protocol

/// The contract for all Language Model providers in Devgentic.
/// Uses the standard OpenAI-compatible messages format directly,
/// eliminating the need for intermediate Transcript types.
protocol LLMProvider: Sendable {
    var modelName: String { get }

    /// Generates a complete response for the given conversation.
    /// - Parameters:
    ///   - messages: An array of message dictionaries in OpenAI chat format:
    ///     `[{"role": "system"|"user"|"assistant", "content": "..."}]`
    ///   - tools: An optional array of tool dictionaries in the provider's native format.
    ///   - responseSchema: An optional JSON Schema dictionary for structured output enforcement.
    ///     Providers that support it (OpenAI, Ollama) embed this in the API request body.
    /// - Returns: The full text response from the model.
    func generate(messages: [[String: String]], tools: [[String: Any]]?, responseSchema: Any?) async throws -> String

    /// Streams a response token-by-token for the given conversation.
    /// - Parameter messages: An array of message dictionaries in OpenAI chat format.
    /// - Parameter tools: An optional array of tool dictionaries in the provider's native format.
    /// - Returns: An async stream of string chunks (deltas) as they are generated.
    func stream(messages: [[String: String]], tools: [[String: Any]]?) -> AsyncThrowingStream<String, Error>

    /// Generates a strictly typed cognitive step, bypassing string parsing.
    func generateCognitiveStep(
        messages: [[String: String]],
        tools: [[String: Any]]?
    ) async throws -> ModernCognitiveStep

    // MARK: - Multimodal Overloads (Phase 6)

    /// Generates a complete response from multimodal ProviderMessages.
    /// Default implementation downgrades to legacy format.
    func generate(payload: [ProviderMessage], tools: [[String: Any]]?, responseSchema: Any?) async throws -> String

    /// Generates a cognitive step from multimodal ProviderMessages.
    /// Default implementation downgrades to legacy format.
    func generateCognitiveStep(payload: [ProviderMessage], tools: [[String: Any]]?) async throws -> ModernCognitiveStep
}

extension LLMProvider {
    func generate(payload: [ProviderMessage], tools: [[String: Any]]?, responseSchema: Any?) async throws -> String {
        let legacyMessages = payload.map { $0.toLegacyDict() }
        return try await generate(messages: legacyMessages, tools: tools, responseSchema: responseSchema)
    }

    func generateCognitiveStep(payload: [ProviderMessage], tools: [[String: Any]]?) async throws -> ModernCognitiveStep {
        let legacyMessages = payload.map { $0.toLegacyDict() }
        return try await generateCognitiveStep(messages: legacyMessages, tools: tools)
    }
}

// MARK: - Provider Configuration

/// Lightweight configuration for HTTP-based LLM providers.
struct LLMProviderConfig: Sendable {
    let apiKey: String?
    let baseURL: URL
    let modelName: String
    let timeout: TimeInterval
    let options: [String: JSONValue]?

    /// Profile-scoped rate limit bucket key, derived from (provider + apiKey/baseURL).
    /// Profiles sharing the same API key share the same bucket.
    let rateLimitKey: String

    /// Whether to request extended thinking traces from the model.
    /// Seeded from `ProviderConfig.thinkingEnabled` at provider-construction time.
    /// Currently used by Ollama (maps to `think: true` on /api/chat).
    let thinkingEnabled: Bool

    init(apiKey: String? = nil, baseURL: URL, modelName: String, timeout: TimeInterval = 300.0, options: [String: JSONValue]? = nil, rateLimitKey: String = "default", thinkingEnabled: Bool = false) {
        self.apiKey = apiKey
        self.baseURL = baseURL
        self.modelName = modelName
        self.timeout = timeout
        self.options = options
        self.rateLimitKey = rateLimitKey
        self.thinkingEnabled = thinkingEnabled
    }
}

// MARK: - Error Type

/// Errors specific to LLM provider operations.
enum LLMProviderError: LocalizedError {
    case httpError(Int, String)
    case invalidResponse(String)
    case unsupportedProvider(String)
    /// Thrown when an Ollama model rejects `think: true` with HTTP 400.
    /// Caught by `BackendOrchestrationService` to auto-disable + retry transparently.
    case thinkingUnsupported(modelName: String)

    var errorDescription: String? {
        switch self {
        case .httpError(let status, let body):
            return LLMProviderError.formatHTTPError(status: status, body: body)
        case .invalidResponse(let detail):
            return "Invalid response: \(detail)"
        case .unsupportedProvider(let name):
            return "Unsupported provider: \(name)"
        case .thinkingUnsupported(let modelName):
            return "'\(modelName)' does not support extended thinking."
        }
    }
    
    /// Translates raw HTTP API errors into clean, user-facing guidance.
    static func formatHTTPError(status: Int, body: String) -> String {
        let lowerBody = body.lowercased()
        
        // 1. Specific Interception: Gemini 429 Quota / Billing Error
        if status == 429 && (lowerBody.contains("gemini") || lowerBody.contains("generativelanguage")) {
            return """
            ⚠️ Google Gemini API Quota Exceeded
            
            Your request was blocked by Google. This typically occurs because:
            1. You are located in a region (e.g., UK, EEA, or Switzerland) where Google requires an active billing account to use the API, even for free-tier models.
            2. You have exceeded the strict rate limits on your current plan.
            
            Action Required:
            Please visit Google AI Studio (https://aistudio.google.com/) to attach a valid billing account to your API key, or switch your Devgentic profile to a different LLM provider (like OpenAI or local Ollama).
            """
        }
        
        // 2. Specific Interception: OpenAI 429 Quota Error
        if status == 429 && lowerBody.contains("openai") {
            return "⚠️ OpenAI API Quota Exceeded. Please check your billing details and account balance at https://platform.openai.com."
        }
        
        // 3. General JSON Error Extraction (prevents dumping huge raw JSON strings into the UI)
        if let data = body.data(using: .utf8),
           let json = try? JSONSerialization.jsonObject(with: data) {
            
            // Google's array-wrapped error format: [{"error": {"message": "..."}}]
            if let array = json as? [[String: Any]],
               let first = array.first,
               let errorObj = first["error"] as? [String: Any],
               let msg = errorObj["message"] as? String {
                 return "API Error (\(status)): \(msg)"
            }
            
            // Standard API error format: {"error": {"message": "..."}}
            if let dict = json as? [String: Any] {
                if let errorObj = dict["error"] as? [String: Any],
                   let msg = errorObj["message"] as? String {
                     return "API Error (\(status)): \(msg)"
                }
                if let msg = dict["error"] as? String {
                     return "API Error (\(status)): \(msg)"
                }
            }
        }
        
        // 4. Fallback for unparseable or unknown errors
        let truncatedBody = body.count > 300 ? String(body.prefix(300)) + "..." : body
        return "HTTP \(status): \(truncatedBody)"
    }
}

// MARK: - Cloud Provider Error (Structured)

/// A structured error type for cloud LLM providers that carries rich metadata
/// for retry strategies and debugging. Thrown by `CloudRequestPipeline`.
struct CloudProviderError: Error, LocalizedError, Sendable {
    /// The HTTP status code from the provider response.
    let statusCode: Int

    /// Seconds to wait before retrying, extracted from the `retry-after` response header.
    let retryAfterSeconds: TimeInterval?

    /// The provider-assigned request ID for debugging and support tickets.
    let requestId: String?

    /// The raw response body string for error message extraction.
    let rawBody: String

    /// The rate limit category this request belongs to (for `GlobalRateLimiter` coordination).
    let provider: RateLimitCategory

    var errorDescription: String? {
        LLMProviderError.formatHTTPError(status: statusCode, body: rawBody)
    }
}
