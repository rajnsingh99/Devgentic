//
//  ImageGenProviderFactory.swift
//  Devgentic
//
//  Created by Raj Singh on 15/03/26.
//
//  Factory for creating ImageGenProvider instances based on the provider configuration.
//

import Foundation
import os

private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "com.devgentic.app", category: "ImageGenProviderFactory")

// MARK: - Image Generation Provider Factory

/// Creates the appropriate `ImageGenProvider` based on the provider configuration.
enum ImageGenProviderFactory {

    /// Creates an `ImageGenProvider` for the given configuration.
    /// - Parameter config: The provider configuration containing API provider, model name, keys, etc.
    /// - Returns: An `ImageGenProvider` instance ready for image generation.
    /// - Throws: `ImageGenError` if the provider is unsupported or misconfigured.
    static func create(for config: ProviderConfig) throws -> ImageGenProvider {
        switch config.apiProvider {
        case .openAI:
            guard let apiKey = config.apiKey, !apiKey.isEmpty else {
                throw ImageGenError.providerError(underlying: "OpenAI API key is required for image generation.")
            }
            logger.info("Creating OpenAI image provider for model: \(config.modelName)")
            return OpenAIImageGenService(
                apiKey: apiKey,
                modelName: config.modelName,
                baseURL: config.baseURL
            )

        case .google:
            guard let apiKey = config.apiKey, !apiKey.isEmpty else {
                throw ImageGenError.providerError(underlying: "Google API key is required for image generation.")
            }
            logger.info("Creating Gemini image provider for model: \(config.modelName)")
            return GeminiImageGenService(
                apiKey: apiKey,
                modelName: config.modelName
            )

        case .mlx:
            logger.info("Creating MLX image provider for model: \(config.modelName)")
            return MLXImageGenService(modelName: config.modelName)

        case .ollama:
            let baseURL = config.baseURL ?? ProviderDefaults.ollamaBaseURL.absoluteString
            logger.info("Creating Ollama image provider for model: \(config.modelName)")
            return OllamaImageGenService(
                modelName: config.modelName,
                baseURL: baseURL
            )

        case .anthropic:
            throw ImageGenError.providerError(underlying: "Anthropic does not currently support image generation.")
        }
    }
}
