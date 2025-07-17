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

    /// Establishes a streaming connection to the configured remote LLM provider.
    func streamMessage(
        conversationID: UUID,
        userQuery: String,
        history: [ChatMessage],
        openAIThreadID: String?,
        integration: LLMIntegrationModel,
        context: TraceContext // <-- Add context parameter
    ) -> AsyncThrowingStream<String, Error> {
        guard let remoteConfig = integration.remoteConfig else {
            return AsyncThrowingStream { continuation in
                continuation.finish(throwing: NSError(domain: "RemoteConfigError", code: 404, userInfo: [NSLocalizedDescriptionKey: "Missing remote configuration."]))
            }
        }

        let provider = remoteConfig.provider
        logger.info("Remote Orchestration: Routing to provider: \(provider.rawValue). traceID: \(context.traceID)")

        guard !remoteConfig.apiKey.isEmpty else {
            return AsyncThrowingStream { continuation in
                continuation.finish(throwing: NSError(domain: "RemoteConfigError", code: 401, userInfo: [NSLocalizedDescriptionKey: "Missing API key."]))
            }
        }
        
        switch provider {
        case .google:
            let geminiService = GeminiConnect(apiKey: remoteConfig.apiKey)
            return geminiService.streamMessage(
                conversationID: conversationID,
                userQuery: userQuery,
                history: history,
                modelName: remoteConfig.modelName,
                context: context // <-- Pass context down
            )
        case .openAI:
            let openAIService = OpenAIConnect(apiKey: remoteConfig.apiKey)
            return openAIService.streamMessage(
                conversationID: conversationID,
                userQuery: userQuery,
                history: history,
                modelName: remoteConfig.modelName,
                context: context // <-- Pass context down
            )
        case .anthropic:
            let anthropicService = AnthropicConnect(apiKey: remoteConfig.apiKey)
            return anthropicService.streamMessage(
                userQuery: userQuery,
                history: history,
                modelName: remoteConfig.modelName,
                context: context // <-- Pass context down
            )
        }
    }

    /// Sends a message to the configured remote LLM provider (non-streaming).
    func sendMessage(
        conversationID: UUID,
        userQuery: String,
        history: [ChatMessage],
        openAIThreadID: String?,
        integration: LLMIntegrationModel
    ) async throws -> (messages: [ChatMessage], newThreadID: String?, error: Error?) {
        
        guard let remoteConfig = integration.remoteConfig else {
            throw NSError(domain: "RemoteConfigError", code: 404, userInfo: [NSLocalizedDescriptionKey: "Missing remote configuration."])
        }

        switch remoteConfig.provider {
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
