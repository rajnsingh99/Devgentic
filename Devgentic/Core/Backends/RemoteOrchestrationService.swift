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
    /// This function is already compliant with the new architecture, returning a raw data stream.
    func streamMessage(
        conversationID: UUID,
        userQuery: String,
        history: [ChatMessage],
        openAIThreadID: String?,
        integration: LLMIntegrationModel,
        context: TraceContext
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
                generationType: remoteConfig.generationType,
                context: context
            )
        case .openAI:
            let openAIService = OpenAIConnect(apiKey: remoteConfig.apiKey)
            return openAIService.streamMessage(
                conversationID: conversationID,
                userQuery: userQuery,
                history: history,
                modelName: remoteConfig.modelName,
                context: context
            )
        case .anthropic:
            let anthropicService = AnthropicConnect(apiKey: remoteConfig.apiKey)
            return anthropicService.streamMessage(
                userQuery: userQuery,
                history: history,
                modelName: remoteConfig.modelName,
                context: context
            )
        }
    }

    /// **REFACTORED for Step 2.2**
    /// Sends a message to the configured remote LLM provider (non-streaming) and returns raw data.
    /// This method no longer creates ChatMessage objects, fulfilling the "pure data provider" requirement.
    func sendMessage(
        conversationID: UUID,
        userQuery: String,
        history: [ChatMessage],
        openAIThreadID: String?,
        integration: LLMIntegrationModel
    ) async throws -> (responseText: String?, responseImageData: Data?, newThreadID: String?, error: Error?) {
        
        guard let remoteConfig = integration.remoteConfig else {
            throw NSError(domain: "RemoteConfigError", code: 404, userInfo: [NSLocalizedDescriptionKey: "Missing remote configuration."])
        }

        switch remoteConfig.provider {
        case .google:
            let geminiService = GeminiConnect(apiKey: remoteConfig.apiKey)
            let (text, data, error) = try await geminiService.sendMessage(
                conversationID: conversationID,
                userQuery: userQuery,
                history: history,
                modelName: remoteConfig.modelName,
                generationType: remoteConfig.generationType
            )
            return (responseText: text, responseImageData: data, newThreadID: nil, error: error)
            
        case .openAI:
            // This assumes OpenAIConnect is similarly refactored to return raw data.
            let openAIService = OpenAIConnect(apiKey: remoteConfig.apiKey)
            let (messages, newThreadID) = try await openAIService.sendMessage(
                conversationID: conversationID,
                userQuery: userQuery,
                openAIThreadID: openAIThreadID,
                modelName: remoteConfig.modelName
            )
            // We extract the raw text content here.
            let responseText = messages.first?.content.textContent
            return (responseText: responseText, responseImageData: nil, newThreadID: newThreadID, error: nil)

        case .anthropic:
            // This assumes AnthropicConnect is similarly refactored.
            let anthropicService = AnthropicConnect(apiKey: remoteConfig.apiKey)
            let (messages, error) = try await anthropicService.sendMessage(
                conversationID: conversationID,
                userQuery: userQuery,
                history: history,
                modelName: remoteConfig.modelName
            )
            // We extract the raw text content here.
            let responseText = messages.first?.content.textContent
            return (responseText: responseText, responseImageData: nil, newThreadID: nil, error: error)
        }
    }
}
