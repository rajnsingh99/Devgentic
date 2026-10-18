// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
//
//  LLMProviders.swift
//  Devgentic
//
//  Created by Raj Singh.
//

import Foundation
import OSLog

private let logger = DGLogger(category: "LLMProviders")

// MARK: - LLM Provider Protocol

/// The contract for all Language Model providers in Devgentic.
/// Uses the standard OpenAI-compatible messages format directly,
/// eliminating the need for intermediate Transcript types.
protocol LLMProvider: Sendable {
    var modelName: String { get }

    /// Generates a complete response for the given conversation and returns the full text.
    /// `messages` use OpenAI chat format; `tools` use the provider's native format; `responseSchema` is a JSON Schema
    /// for structured output, embedded in the request body by providers that support it (OpenAI, Ollama).
    func generate(messages: [[String: String]], tools: [[String: Any]]?, responseSchema: Any?) async throws -> String

    /// Streams a response token-by-token for the given conversation, as an async stream of string deltas.
    /// `messages` use OpenAI chat format; `tools` use the provider's native format.
    func stream(messages: [[String: String]], tools: [[String: Any]]?) -> AsyncThrowingStream<String, Error>

    /// Generates a strictly typed cognitive step, bypassing string parsing.
    func generateCognitiveStep(
        messages: [[String: String]],
        tools: [[String: Any]]?
    ) async throws -> ModernCognitiveStep

    // MARK: - Native-Turn Overload (G12 Refactor)

    /// Generates a cognitive step from native-turn messages that carry provider-specific content (tool_calls arrays,
    /// tool_use blocks, functionCall parts). The default coerces each message to `{role, content: String}`, dropping
    /// structural tool-call content; native-tool providers (Ollama, OpenAI, Claude, Gemini) override it.
    func generateCognitiveStep(
        nativeMessages: [[String: Any]],
        tools: [[String: Any]]?
    ) async throws -> ModernCognitiveStep

    /// The native-turn step, streamed: `onTextDelta` receives visible text as it is generated, and the call still
    /// returns the complete step. The default calls the non-streaming variant and never invokes `onTextDelta`.
    /// Tool calls arrive only with the returned step.
    func generateCognitiveStepStreaming(
        nativeMessages: [[String: Any]],
        tools: [[String: Any]]?,
        onTextDelta: @escaping @Sendable (String) -> Void
    ) async throws -> ModernCognitiveStep

    // MARK: - Multimodal Overloads

    /// Generates a complete response from multimodal ProviderMessages.
    /// Default implementation downgrades to legacy format.
    func generate(payload: [ProviderMessage], tools: [[String: Any]]?, responseSchema: Any?) async throws -> String

    /// Generates a cognitive step from multimodal ProviderMessages.
    /// Default implementation downgrades to legacy format.
    func generateCognitiveStep(payload: [ProviderMessage], tools: [[String: Any]]?) async throws -> ModernCognitiveStep

    // MARK: - Usage-Reporting Overloads (#10b)

    /// Like `generate(messages:tools:responseSchema:)` but also returns provider-reported token usage when the
    /// API exposes it. The default reports nil usage (callers estimate via `chars/4`); cloud providers override it.
    func generateWithUsage(messages: [[String: String]], tools: [[String: Any]]?, responseSchema: Any?) async throws -> (text: String, usage: TokenUsage?)

    /// Multimodal counterpart of ``generateWithUsage(messages:tools:responseSchema:)``.
    func generateWithUsage(payload: [ProviderMessage], tools: [[String: Any]]?, responseSchema: Any?) async throws -> (text: String, usage: TokenUsage?)

    /// Like ``stream(messages:tools:)`` but invokes `onUsage` once with the provider-reported
    /// token usage when the stream exposes it (the terminal SSE/usage event). The default
    /// implementation calls `stream` and never invokes `onUsage` (caller then estimates).
    func streamWithUsage(messages: [[String: String]], tools: [[String: Any]]?, onUsage: (@Sendable (TokenUsage) -> Void)?) -> AsyncThrowingStream<String, Error>
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

    // Default-downgrade: report no usage so callers fall back to estimation.
    // Cloud providers override these to surface the API's real token counts (#10b).
    func generateWithUsage(messages: [[String: String]], tools: [[String: Any]]?, responseSchema: Any?) async throws -> (text: String, usage: TokenUsage?) {
        let text = try await generate(messages: messages, tools: tools, responseSchema: responseSchema)
        return (text, nil)
    }

    func generateWithUsage(payload: [ProviderMessage], tools: [[String: Any]]?, responseSchema: Any?) async throws -> (text: String, usage: TokenUsage?) {
        let text = try await generate(payload: payload, tools: tools, responseSchema: responseSchema)
        return (text, nil)
    }

    // Default-downgrade: stream without surfacing usage. Cloud providers override (#10b).
    func streamWithUsage(messages: [[String: String]], tools: [[String: Any]]?, onUsage: (@Sendable (TokenUsage) -> Void)?) -> AsyncThrowingStream<String, Error> {
        stream(messages: messages, tools: tools)
    }

    /// Default fallback that coerces native messages to `[[String: String]]`, dropping structural tool-call
    /// content. Non-string values are JSON-encoded so the legacy path still gets valid JSON fragments.
    func generateCognitiveStep(
        nativeMessages: [[String: Any]],
        tools: [[String: Any]]?
    ) async throws -> ModernCognitiveStep {
        let legacy: [[String: String]] = nativeMessages.map { msg in
            var out: [String: String] = [:]
            for (key, value) in msg {
                if let str = value as? String {
                    out[key] = str
                } else if JSONSerialization.isValidJSONObject(value),
                          let data = try? JSONSerialization.data(withJSONObject: value),
                          let encoded = String(data: data, encoding: .utf8) {
                    out[key] = encoded
                } else {
                    out[key] = "\(value)"
                }
            }
            return out
        }
        return try await generateCognitiveStep(messages: legacy, tools: tools)
    }

    func generateCognitiveStepStreaming(
        nativeMessages: [[String: Any]],
        tools: [[String: Any]]?,
        onTextDelta: @escaping @Sendable (String) -> Void
    ) async throws -> ModernCognitiveStep {
        try await generateCognitiveStep(nativeMessages: nativeMessages, tools: tools)
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

    /// Additional HTTP headers applied to every request (e.g. OpenRouter's
    /// optional `X-Title` attribution). Never carries auth — the API key stays
    /// in `apiKey` so redaction and key-rotation paths see one field.
    let extraHeaders: [String: String]

    init(apiKey: String? = nil, baseURL: URL, modelName: String, timeout: TimeInterval = 300.0, options: [String: JSONValue]? = nil, rateLimitKey: String = "default", thinkingEnabled: Bool = false, extraHeaders: [String: String] = [:]) {
        self.apiKey = apiKey
        self.baseURL = baseURL
        self.modelName = modelName
        self.timeout = timeout
        self.options = options
        self.rateLimitKey = rateLimitKey
        self.thinkingEnabled = thinkingEnabled
        self.extraHeaders = extraHeaders
    }
}

// Why: logging a provider via `String(describing:)` reflects into this config, and reflection renders children through
// `debugDescription`; conforming here covers every enclosing provider, even keys with no known vendor prefix.
/// Redacts the API key from `description` and `debugDescription`.
extension LLMProviderConfig: CustomStringConvertible, CustomDebugStringConvertible {
    var description: String {
        let key = apiKey.map { $0.isEmpty ? "empty" : "set (\($0.count) chars)" } ?? "none"
        return "LLMProviderConfig(apiKey: \(key), baseURL: \(baseURL.absoluteString), modelName: \"\(modelName)\", "
            + "timeout: \(timeout), options: \(options.map { "\($0.count) key(s)" } ?? "nil"), "
            + "rateLimitKey: \"\(rateLimitKey)\", thinkingEnabled: \(thinkingEnabled), "
            + "extraHeaders: \(extraHeaders.keys.sorted()))"
    }

    var debugDescription: String { description }
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
    /// Thrown when an Ollama model rejects the `tools` parameter with HTTP 400 ("does not support tools"), as reasoning-only
    /// models (deepseek-r1, o1 family) do. Retrying cannot fix a capability gap, so the retry strategy aborts immediately;
    /// the message suggests switching profile type or model.
    case toolsUnsupported(modelName: String)
    /// The provider's own safety system declined the request (Anthropic `stop_reason: "refusal"`, Gemini
    /// `promptFeedback.blockReason` or a safety `finishReason`). It arrives as HTTP 200 and is deterministic for the
    /// same request, so it is never retried.
    case refused(provider: String, detail: String)
    /// A stream that closed cleanly but never reported it had finished (no `finish_reason`), cut off upstream by a proxy or
    /// gateway. Transient: the same request normally completes.
    case streamEndedEarly(provider: String)

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
        case .toolsUnsupported(let modelName):
            return "\(modelName) doesn't support tool calling. Use this model in a Bot profile for chat or switch to a tool-capable model."
        case .refused(let provider, let detail):
            return "\(provider) declined to answer this request (\(detail)). Rephrasing it may help, or try a different model."
        case .streamEndedEarly(let provider):
            return "The \(provider) response stream ended before the model finished. This is usually a dropped connection; retrying normally works."
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

        // 2b. Payment required — OpenRouter signals an out-of-credits account with 402.
        if status == 402 {
            return "⚠️ Provider account is out of credits (HTTP 402). Add credits to your account (OpenRouter: https://openrouter.ai/credits) and try again."
        }

        // 2c. OpenRouter found no upstream provider that satisfies the data policy — the usual
        // result of the profile's "Deny Data Collection" switch on a `:free` model.
        if status == 404 && lowerBody.contains("data policy") {
            return "⚠️ No provider for this model meets your data policy — it is only served by providers that store prompts. Pick another model, or turn off \"Deny Data Collection\" in the profile's Advanced Configuration (if it is already off, check your privacy settings at https://openrouter.ai/settings/privacy)."
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
