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
        
        // --- TRACING START ---
        // Create a dedicated child span for this remote interaction.
        // This allows us to measure specifically how long the remote provider took, separate from local overhead.
        var remoteSpan = context.newSpan()
        remoteSpan.addMetadata("span_type", value: "remote_execution")
        remoteSpan.addMetadata("provider", value: llmConfig.apiProvider.rawValue)
        remoteSpan.addMetadata("model", value: llmConfig.modelName)
        // ---------------------

        let provider = llmConfig.apiProvider
        logger.info("Remote Orchestration: Routing to provider: \(provider.rawValue). traceID: \(remoteSpan.traceID) spanID: \(remoteSpan.spanID)")

        // 2. Ensure an API key is present.
        guard let apiKey = llmConfig.apiKey, !apiKey.isEmpty else {
            return AsyncThrowingStream { continuation in
                let error = NSError(domain: "RemoteConfigError", code: 401, userInfo: [NSLocalizedDescriptionKey: "Missing API key for \(provider.rawValue)."])
                continuation.finish(throwing: error)
            }
        }
        
        // 3. Route to the appropriate provider-specific connector.
        // We pass 'remoteSpan' instead of 'context' so downstream connectors (HTTP calls) are children of this span.
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
                context: remoteSpan
            )
        case .openAI:
            let openAIService = OpenAIConnect(apiKey: apiKey)
            return openAIService.streamMessage(
                conversationID: conversationID,
                userQuery: userQuery,
                history: history,
                modelName: llmConfig.modelName,
                context: remoteSpan
            )
        case .anthropic:
            let anthropicService = AnthropicConnect(apiKey: apiKey)
            return anthropicService.streamMessage(
                userQuery: userQuery,
                history: history,
                modelName: llmConfig.modelName,
                context: remoteSpan
            )
        case .ollama:
            // This case should not be reached if routing is correct in BackendOrchestrationService.
            return AsyncThrowingStream { continuation in
                let error = NSError(domain: "RoutingError", code: 500, userInfo: [NSLocalizedDescriptionKey: "RemoteOrchestrationService should not be called for Ollama profiles (Local execution only)."])
                continuation.finish(throwing: error)
            }
        case .mlx:
            // Explicit guard for MLX to prevent accidental remote routing
            return AsyncThrowingStream { continuation in
                let error = NSError(domain: "RoutingError", code: 500, userInfo: [NSLocalizedDescriptionKey: "RemoteOrchestrationService cannot handle MLX profiles. MLX models run locally on device."])
                continuation.finish(throwing: error)
            }
        }
    }
}
