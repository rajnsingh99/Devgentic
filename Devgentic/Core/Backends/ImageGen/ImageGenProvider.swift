// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
//
//  ImageGenProvider.swift
//  Devgentic
//
//  Created by Raj Singh on 15/03/26.
//
//  Defines the contract for image generation providers (OpenAI, Gemini, MLX/Flux2, Ollama).
//  Kept separate from LLMProvider to avoid muddying text-generation interfaces.
//

import Foundation

// MARK: - Image Generation Options

/// Configuration options passed to image generation providers.
struct ImageGenOptions: Sendable {
    let aspectRatio: ImageAspectRatio
    let numberOfImages: Int
    let quality: ImageQuality
    let steps: Int?
    let guidance: Double?
    let advancedSettings: [String: JSONValue]?

    init(
        aspectRatio: ImageAspectRatio = .square,
        numberOfImages: Int = 1,
        quality: ImageQuality = .standard,
        steps: Int? = nil,
        guidance: Double? = nil,
        advancedSettings: [String: JSONValue]? = nil
    ) {
        self.aspectRatio = aspectRatio
        self.numberOfImages = numberOfImages
        self.quality = quality
        self.steps = steps
        self.guidance = guidance
        self.advancedSettings = advancedSettings
    }
}

// MARK: - Image Generation Errors

/// Errors specific to image generation operations.
enum ImageGenError: LocalizedError, Sendable {
    case imageToImageNotSupported(modelName: String)
    case textToImageNotSupported(modelName: String)
    case invalidAspectRatio(requested: String, supported: [String])
    case contentPolicyViolation(detail: String)
    case providerError(underlying: String)
    case modelNotLoaded
    case insufficientMemory(required: String, available: String)
    case invalidResponse(detail: String)

    var errorDescription: String? {
        switch self {
        case .imageToImageNotSupported(let model):
            return "The model '\(model)' does not support Image-to-Image generation. Please select a model with I2I capability (e.g., Gemini)."
        case .textToImageNotSupported(let model):
            return "The model '\(model)' does not support Text-to-Image generation."
        case .invalidAspectRatio(let requested, let supported):
            return "Aspect ratio '\(requested)' is not supported. Available: \(supported.joined(separator: ", "))."
        case .contentPolicyViolation(let detail):
            return "Content policy violation: \(detail)"
        case .providerError(let underlying):
            return "Image generation failed: \(underlying)"
        case .modelNotLoaded:
            return "The image generation model is not loaded. Please wait for it to finish loading."
        case .insufficientMemory(let required, let available):
            return "Insufficient GPU memory. Required: \(required), Available: \(available)."
        case .invalidResponse(let detail):
            return "Invalid response from provider: \(detail)"
        }
    }
}

// MARK: - Image Generation Provider Protocol

/// Protocol for image generation services.
/// Each provider (OpenAI, Gemini, MLX, Ollama) conforms to this protocol.
/// Providers store generated images via MediaStore and return MediaArtifact references.
protocol ImageGenProvider: Sendable {
    /// Generate an image from a text prompt (Text-to-Image).
    /// - Parameters:
    ///   - prompt: The text description of the desired image.
    ///   - negativePrompt: Optional description of what to avoid in the image.
    ///   - options: Generation configuration (aspect ratio, quality, etc.).
    ///   - conversationID: Used for MediaStore storage scoping.
    ///   - progressHandler: Called with (current step, total steps) for progress reporting.
    /// - Returns: A `MediaArtifact` with a disk-backed reference to the generated image.
    func generateImage(
        prompt: String,
        negativePrompt: String?,
        options: ImageGenOptions,
        conversationID: UUID,
        progressHandler: (@Sendable (Int, Int) -> Void)?
    ) async throws -> MediaArtifact

    /// Generate an image variation from an existing image (Image-to-Image).
    /// - Parameters:
    ///   - prompt: Text description guiding the variation.
    ///   - negativePrompt: Optional description of what to avoid.
    ///   - inputImage: The source image data to base the variation on.
    ///   - options: Generation configuration.
    ///   - conversationID: Used for MediaStore storage scoping.
    ///   - progressHandler: Called with (current step, total steps) for progress reporting.
    /// - Returns: A `MediaArtifact` with a disk-backed reference to the generated image.
    /// - Throws: `ImageGenError.imageToImageNotSupported` if the provider doesn't support I2I.
    func generateImageVariation(
        prompt: String,
        negativePrompt: String?,
        inputImage: Data,
        options: ImageGenOptions,
        conversationID: UUID,
        progressHandler: (@Sendable (Int, Int) -> Void)?
    ) async throws -> MediaArtifact
}

// MARK: - Default Implementation

extension ImageGenProvider {
    /// Default: Image-to-Image not supported. Subclasses override if they support I2I.
    func generateImageVariation(
        prompt: String,
        negativePrompt: String?,
        inputImage: Data,
        options: ImageGenOptions,
        conversationID: UUID,
        progressHandler: (@Sendable (Int, Int) -> Void)?
    ) async throws -> MediaArtifact {
        throw ImageGenError.imageToImageNotSupported(modelName: "Unknown")
    }
}
