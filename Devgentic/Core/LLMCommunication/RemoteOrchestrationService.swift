//
//  RemoteOrchestrationService.swift
//  Devgentic
//
//  Created by Raj Singh.
//

import Foundation
import os

private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "com.devgentic.app", category: "RemoteOrchestrationService")

/// A service for handling communication with remote LLM providers like OpenAI, Gemini, and Anthropic.
class RemoteOrchestrationService {

    init() {
        logger.info("RemoteOrchestrationService initialized.")
    }

    /// Sends a message to the configured remote LLM provider by routing to the appropriate connector service.
    /// - Parameters:
    ///   - conversationID: The ID of the current conversation.
    ///   - userQuery: The user's text input.
    ///   - files: A list of attached files.
    ///   - integration: The `LLMIntegrationModel` containing the configuration for the remote provider.
    /// - Returns: A tuple containing an array of `ChatMessage` and an optional `Error`.
    func sendMessage(
        conversationID: UUID,
        userQuery: String,
        files: [FileSystemItem],
        integration: LLMIntegrationModel
    ) async throws -> ([ChatMessage], Error?) {
        
        // Ensure we have a valid remote configuration
        guard let remoteConfig = integration.remoteConfig else {
            let errorMessage = "The selected integration '\(integration.displayName)' is missing a remote configuration."
            let errorContent = MessageContent.error(title: "Configuration Error", details: errorMessage)
            return ([ChatMessage(conversationId: conversationID, sender: .agent, content: errorContent)], nil)
        }

        let provider = remoteConfig.provider
        logger.info("RemoteOrchestrationService routing message to provider: \(provider.rawValue)")

        // Shared validation for API key and model name
        guard !remoteConfig.apiKey.isEmpty else {
            let errorMessage = "The \(provider.rawValue) integration is missing an API key."
            let errorContent = MessageContent.error(title: "Configuration Error", details: errorMessage)
            return ([ChatMessage(conversationId: conversationID, sender: .agent, content: errorContent)], nil)
        }
        
        guard !remoteConfig.modelName.isEmpty else {
            let errorMessage = "The \(provider.rawValue) integration is missing a model name."
            let errorContent = MessageContent.error(title: "Configuration Error", details: errorMessage)
            return ([ChatMessage(conversationId: conversationID, sender: .agent, content: errorContent)], nil)
        }

        // Switch on the provider to delegate to the correct service
        switch provider {
        case .google:
            let geminiService = GeminiConnect(apiKey: remoteConfig.apiKey)
            return try await geminiService.sendMessage(
                conversationID: conversationID,
                userQuery: userQuery,
                files: files,
                modelName: remoteConfig.modelName
            )

        case .openAI:
            let openAIService = OpenAIConnect(apiKey: remoteConfig.apiKey)
            return try await openAIService.sendMessage(
                conversationID: conversationID,
                userQuery: userQuery,
                files: files,
                modelName: remoteConfig.modelName
            )

        case .anthropic:
            let anthropicService = AnthropicConnect(apiKey: remoteConfig.apiKey)
            return try await anthropicService.sendMessage(
                conversationID: conversationID,
                userQuery: userQuery,
                files: files,
                modelName: remoteConfig.modelName
            )
        }
    }
}
