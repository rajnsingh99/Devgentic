//
//  LLMProvider.swift
//  Devgentic
//
//  Created by Devgentic Architect
//
//  The owned LLM abstraction layer replacing OpenFoundationModels.LanguageModel.
//  Operates on the OpenAI-compatible messages format used by all supported providers.
//

import Foundation

// MARK: - LLM Provider Protocol

/// The contract for all Language Model providers in Devgentic.
/// Uses the standard OpenAI-compatible messages format directly,
/// eliminating the need for intermediate Transcript types.
protocol LLMProvider: Sendable {

    /// Generates a complete response for the given conversation.
    /// - Parameters:
    ///   - messages: An array of message dictionaries in OpenAI chat format:
    ///     `[{"role": "system"|"user"|"assistant", "content": "..."}]`
    ///   - responseSchema: An optional JSON Schema dictionary for structured output enforcement.
    ///     Providers that support it (OpenAI, Ollama) embed this in the API request body.
    /// - Returns: The full text response from the model.
    func generate(messages: [[String: String]], responseSchema: [String: Any]?) async throws -> String

    /// Streams a response token-by-token for the given conversation.
    /// - Parameter messages: An array of message dictionaries in OpenAI chat format.
    /// - Returns: An async stream of string chunks (deltas) as they are generated.
    func stream(messages: [[String: String]]) -> AsyncThrowingStream<String, Error>
}

// MARK: - Provider Configuration

/// Lightweight configuration for HTTP-based LLM providers.
struct LLMProviderConfig: Sendable {
    let apiKey: String?
    let baseURL: URL
    let modelName: String
    let timeout: TimeInterval

    init(apiKey: String? = nil, baseURL: URL, modelName: String, timeout: TimeInterval = 300.0) {
        self.apiKey = apiKey
        self.baseURL = baseURL
        self.modelName = modelName
        self.timeout = timeout
    }
}
