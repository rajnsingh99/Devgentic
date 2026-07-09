//
//  ImageCapabilityAnalyzer.swift
//  Devgentic
//
//  Created by Raj Singh on 15/03/26.
//
//  Determines whether a given provider + model combination supports
//  Text-to-Image (T2I) and/or Image-to-Image (I2I) generation.
//

import Foundation

// MARK: - Image Modality Support

/// Describes the image generation capabilities of a specific provider + model combination.
struct ImageModalitySupport: Sendable, Hashable {
    /// Whether the model supports generating images from text prompts.
    let supportsTextToImage: Bool
    /// Whether the model supports generating image variations from existing images.
    let supportsImageToImage: Bool
    /// Optional maximum resolution the model can produce.
    let maxResolution: (width: Int, height: Int)?
    /// Optional list of aspect ratios the model natively supports.
    let supportedAspectRatios: [ImageAspectRatio]?

    // Hashable conformance for the tuple
    static func == (lhs: ImageModalitySupport, rhs: ImageModalitySupport) -> Bool {
        lhs.supportsTextToImage == rhs.supportsTextToImage &&
        lhs.supportsImageToImage == rhs.supportsImageToImage &&
        lhs.maxResolution?.width == rhs.maxResolution?.width &&
        lhs.maxResolution?.height == rhs.maxResolution?.height &&
        lhs.supportedAspectRatios == rhs.supportedAspectRatios
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(supportsTextToImage)
        hasher.combine(supportsImageToImage)
        hasher.combine(maxResolution?.width)
        hasher.combine(maxResolution?.height)
        hasher.combine(supportedAspectRatios)
    }
}

// MARK: - Image Capability Analyzer

/// Analyzes provider + model combinations to determine image generation capabilities.
/// Uses hardcoded mappings for cloud providers and metadata inspection for local models.
enum ImageCapabilityAnalyzer {

    /// Analyzes the image generation capabilities for a given provider and model.
    /// - Parameters:
    ///   - provider: The API provider (OpenAI, Gemini, MLX, Ollama).
    ///   - modelName: The specific model name/identifier.
    ///   - modelMetadata: Optional metadata from model inspection.
    /// - Returns: An `ImageModalitySupport` describing T2I and I2I capabilities.
    static func analyze(
        provider: ApiProvider,
        modelName: String,
        modelMetadata: ModelMetadata? = nil
    ) -> ImageModalitySupport {
        switch provider {
        case .openAI:
            return analyzeOpenAI(modelName: modelName)
        case .google:
            return analyzeGemini(modelName: modelName)
        case .mlx:
            return analyzeMLX(modelName: modelName)
        case .ollama:
            return analyzeOllama(modelName: modelName)
        case .anthropic, .openRouter, .openAICompatible:
            // Anthropic has no image generation API; OpenRouter and custom
            // OpenAI-compatible endpoints are wired for text generation only in
            // Devgentic, so all report no image modality support.
            return ImageModalitySupport(
                supportsTextToImage: false,
                supportsImageToImage: false,
                maxResolution: nil,
                supportedAspectRatios: nil
            )
        }
    }

    // MARK: - Per-Provider Analysis

    private static func analyzeOpenAI(modelName: String) -> ImageModalitySupport {
        let name = modelName.lowercased()

        if name.contains("gpt-image") {
            // gpt-image-1 supports both T2I and I2I
            return ImageModalitySupport(
                supportsTextToImage: true,
                supportsImageToImage: true,
                maxResolution: (2048, 2048),
                supportedAspectRatios: [.square, .landscape, .portrait]
            )
        } else if name.contains("dall-e-3") {
            return ImageModalitySupport(
                supportsTextToImage: true,
                supportsImageToImage: false,
                maxResolution: (1792, 1024),
                supportedAspectRatios: [.square, .landscape, .portrait]
            )
        } else if name.contains("dall-e-2") {
            return ImageModalitySupport(
                supportsTextToImage: true,
                supportsImageToImage: true,
                maxResolution: (1024, 1024),
                supportedAspectRatios: [.square]
            )
        }

        // Unknown OpenAI model — assume basic T2I
        return ImageModalitySupport(
            supportsTextToImage: true,
            supportsImageToImage: false,
            maxResolution: (1024, 1024),
            supportedAspectRatios: [.square]
        )
    }

    private static func analyzeGemini(modelName: String) -> ImageModalitySupport {
        let name = modelName.lowercased()

        if name.contains("gemini-2.0-flash") && name.contains("image") {
            return ImageModalitySupport(
                supportsTextToImage: true,
                supportsImageToImage: true,
                maxResolution: (1024, 1024),
                supportedAspectRatios: ImageAspectRatio.allCases
            )
        } else if name.contains("imagen-3") {
            return ImageModalitySupport(
                supportsTextToImage: true,
                supportsImageToImage: false,
                maxResolution: (1024, 1024),
                supportedAspectRatios: [.square, .landscape, .portrait, .photo, .photoPort]
            )
        }

        // Default Gemini — check if image generation endpoint is available
        return ImageModalitySupport(
            supportsTextToImage: name.contains("image") || name.contains("imagen"),
            supportsImageToImage: false,
            maxResolution: (1024, 1024),
            supportedAspectRatios: [.square]
        )
    }

    private static func analyzeMLX(modelName: String) -> ImageModalitySupport {
        // All Flux2 models (Klein 4B, Klein 9B, Dev 32B) support both T2I and I2I
        // via flux-2-swift-mlx library
        return ImageModalitySupport(
            supportsTextToImage: true,
            supportsImageToImage: true,
            maxResolution: (1024, 1024),
            supportedAspectRatios: ImageAspectRatio.allCases
        )
    }

    private static func analyzeOllama(modelName: String) -> ImageModalitySupport {
        // Ollama image generation is experimental — T2I only
        // Known image-capable models include flux variants
        let name = modelName.lowercased()
        let isImageModel = name.contains("flux") || name.contains("image") || name.contains("diffusion")

        return ImageModalitySupport(
            supportsTextToImage: isImageModel,
            supportsImageToImage: false,
            maxResolution: (1024, 1024),
            supportedAspectRatios: [.square]
        )
    }
}
