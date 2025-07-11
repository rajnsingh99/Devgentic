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
    /// - Returns: A tuple containing an array of `ChatMessage`, an optional new OpenAI thread ID, and an optional `Error`.
    func sendMessage(
        conversationID: UUID,
        userQuery: String,
        history: [ChatMessage],
        openAIThreadID: String?,
        // files: [FileSystemItem], // ** REMOVED in Phase 2 **
        integration: LLMIntegrationModel
    ) async throws -> (messages: [ChatMessage], newThreadID: String?, error: Error?) {
        
        guard let remoteConfig = integration.remoteConfig else {
            let errorMessage = "The selected integration '\(integration.displayName)' is missing a remote configuration."
            let errorContent = MessageContent.error(title: "Configuration Error", details: errorMessage)
            return (messages: [ChatMessage(conversationId: conversationID, sender: .agent, content: errorContent)], newThreadID: nil, error: nil)
        }

        let provider = remoteConfig.provider
        logger.info("RemoteOrchestrationService routing message to provider: \(provider.rawValue)")

        guard !remoteConfig.apiKey.isEmpty else {
            let errorMessage = "The \(provider.rawValue) integration is missing an API key."
            let errorContent = MessageContent.error(title: "Configuration Error", details: errorMessage)
            return (messages: [ChatMessage(conversationId: conversationID, sender: .agent, content: errorContent)], newThreadID: nil, error: nil)
        }
        
        guard !remoteConfig.modelName.isEmpty else {
            let errorMessage = "The \(provider.rawValue) integration is missing a model name."
            let errorContent = MessageContent.error(title: "Configuration Error", details: errorMessage)
            return (messages: [ChatMessage(conversationId: conversationID, sender: .agent, content: errorContent)], newThreadID: nil, error: nil)
        }

        switch provider {
        case .google:
            let geminiService = GeminiConnect(apiKey: remoteConfig.apiKey)
            let (messages, error) = try await geminiService.sendMessage(
                conversationID: conversationID,
                userQuery: userQuery,
                history: history,
                modelName: remoteConfig.modelName
            )
            return (messages: messages, newThreadID: nil, error: error)

        case .openAI:
            let openAIService = OpenAIConnect(apiKey: remoteConfig.apiKey)
            let (messages, newThreadID) = try await openAIService.sendMessage(
                conversationID: conversationID,
                userQuery: userQuery,
                openAIThreadID: openAIThreadID,
                modelName: remoteConfig.modelName
            )
            return (messages: messages, newThreadID: newThreadID, error: nil)

        case .anthropic:
            let anthropicService = AnthropicConnect(apiKey: remoteConfig.apiKey)
            let (messages, error) = try await anthropicService.sendMessage(
                conversationID: conversationID,
                userQuery: userQuery,
                history: history,
                modelName: remoteConfig.modelName
            )
            return (messages: messages, newThreadID: nil, error: error)
        }
    }
}
