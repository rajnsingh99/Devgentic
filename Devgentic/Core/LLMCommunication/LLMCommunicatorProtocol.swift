//
//  LLMCommunicatorProtocol.swift
//  Devgentic
//
//  Created by Raj Singh on 15/05/25.
//

import Foundation

/// Protocol defining the contract for a service that communicates with an LLM backend.
protocol LLMCommunicatorProtocol {
    /// Sends a message constructed from string parts to a backend (e.g., Ollama).
    /// - Parameters:
    ///   - parts: An array of `MessagePart` objects for string-based prompt construction.
    ///   - backendType: The target backend. Should be `.ollama`.
    ///   - config: Configuration for the backend connection.
    /// - Returns: An `LLMResponse` object.
    /// - Throws: An error if communication fails.
    func sendMessage(
        parts: [MessagePart],
        to backendType: BackendType,
        config: BackendConfiguration
    ) async throws -> LLMResponse

    /// Sends a structured, Codable payload to a backend (e.g., the Agent).
    /// - Parameters:
    ///   - payload: A `ChatRequestPayload` struct that will be encoded to JSON.
    ///   - backendType: The target backend. Should be `.agent`.
    ///   - config: Configuration for the backend connection.
    /// - Returns: An `LLMResponse` object.
    /// - Throws: An error if communication fails.
    func sendMessage(
        payload: AgentOrchestrationRequest,
        to backendType: BackendType,
        config: BackendConfiguration
    ) async throws -> LLMResponse
}
