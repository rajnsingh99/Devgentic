//
//  LLMCommunicatorProtocol.swift
//  Devgentic
//
//  Created by Raj Singh on 15/05/25.
//

import Foundation

/// Protocol defining the contract for a service that communicates with an LLM backend.
protocol LLMCommunicatorProtocol {
    /// Sends a message, constructed from various parts, to the specified LLM backend.
    /// - Parameters:
    ///   - parts: An array of `MessagePart` objects representing the structured message to send.
    ///   - backendType: The target `BackendType` (e.g., .ollama, .agent).
    ///   - backendConfig: Configuration specific to the backend, like API keys, URLs, model parameters.
    ///                    This will use `MainApplicationViewModel.BackendConfiguration` or a refined version.
    ///   - conversationHistory: Optional: An array of previous `ChatMessage` objects for context.
    ///                          (This can be added later if context management is centralized here)
    /// - Returns: An `LLMResponse` object containing the parsed content and raw response.
    /// - Throws: An error if the communication fails at a network level or if critical parsing/setup fails.
    func sendMessage(
        parts: [MessagePart],
        to backendType: BackendType,
        config: BackendConfiguration // Using existing config struct for now
        // conversationHistory: [ChatMessage]? = nil // Example for future context handling
    ) async throws -> LLMResponse
}
