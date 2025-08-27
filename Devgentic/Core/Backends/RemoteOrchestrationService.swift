//
//  RemoteOrchestrationService.swift
//  Devgentic
//
//  Created by Raj Singh.
//

import Foundation
import os

private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "com.devgentic.app", category: "RemoteOrchestrationService")


class RemoteOrchestrationService {

    init() {
        logger.info("RemoteOrchestrationService initialized.")
    }

    func streamMessage(
        conversationID: UUID,
        userQuery: String,
        history: [ChatMessage],
        profile: BackendProfileModel,
        context: TraceContext
    ) -> AsyncThrowingStream<String, Error> {
        
        // 1. Extract the LLM configuration from the profile's details.
        // This service should only be called with profiles that have a bot configuration.
        guard case .bot(let llmConfig) = profile.details else {
            return AsyncThrowingStream { continuation in
                let error = NSError(domain: "ProfileError", code: 500, userInfo: [NSLocalizedDescriptionKey: "Remote orchestration called with an invalid profile type. Expected a 'Bot'."])
                continuation.finish(throwing: error)
            }
        }

        let provider = llmConfig.apiProvider
        logger.info("Remote Orchestration: Routing to provider: \(provider.rawValue). traceID: \(context.traceID)")

        // 2. Ensure an API key is present.
        guard let apiKey = llmConfig.apiKey, !apiKey.isEmpty else {
            return AsyncThrowingStream { continuation in
                let error = NSError(domain: "RemoteConfigError", code: 401, userInfo: [NSLocalizedDescriptionKey: "Missing API key for \(provider.rawValue)."])
                continuation.finish(throwing: error)
            }
        }
        
        // 3. Route to the appropriate provider-specific connector.
        switch provider {
        case .google:
            let geminiService = GeminiConnect(apiKey: apiKey)
            // Note: The `generationType` is not part of the unified ProviderConfig yet.
            // This would need to be added to BackendProfile's advancedConfiguration if needed.
            return geminiService.streamMessage(
                conversationID: conversationID,
                userQuery: userQuery,
                history: history,
                modelName: llmConfig.modelName,
                generationType: [.text], // Placeholder
                context: context
            )
        case .openAI:
            let openAIService = OpenAIConnect(apiKey: apiKey)
            return openAIService.streamMessage(
                conversationID: conversationID,
                userQuery: userQuery,
                history: history,
                modelName: llmConfig.modelName,
                context: context
            )
        case .anthropic:
            let anthropicService = AnthropicConnect(apiKey: apiKey)
            return anthropicService.streamMessage(
                userQuery: userQuery,
                history: history,
                modelName: llmConfig.modelName,
                context: context
            )
        case .ollama:
            // This case should not be reached if routing is correct in BackendOrchestrationService.
            return AsyncThrowingStream { continuation in
                let error = NSError(domain: "RoutingError", code: 500, userInfo: [NSLocalizedDescriptionKey: "RemoteOrchestrationService should not be called for Ollama profiles."])
                continuation.finish(throwing: error)
            }
        }
    }
}
