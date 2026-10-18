// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
//
//  MLXImageGenService.swift
//  Devgentic
//
//  Created by Raj Singh.
//

import Foundation
import os

/// Whether this build can generate images on-device with MLX. The ONE place the rest of the app
/// asks: provider pickers, the capability analyzer and the provider factory all read it, so
/// the image-generation picker never offers a provider the factory cannot build.
enum MLXImageGenAvailability {
    static var isCompiledIn: Bool {
        #if MLX_IMAGE_GEN
        return true
        #else
        return false
        #endif
    }

    /// Shown when a saved image profile still names MLX in a build without it.
    static let unavailableMessage =
        "On-device MLX image generation isn't included in this build. "
        + "Switch this profile to OpenAI, Gemini, or Ollama."
}

#if MLX_IMAGE_GEN
import Flux2Core
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

private let logger = DGLogger(category: "MLXImageGenService")

// MARK: - Shared Pipeline Manager

/// Manages a shared Flux2Pipeline instance to avoid redundant model loading.
/// Thread-safe via actor isolation — only one pipeline exists at a time.
private actor Flux2PipelineManager {
    static let shared = Flux2PipelineManager()

    private var pipeline: Flux2Pipeline?
    private var loadedModel: Flux2Model?

    /// Returns (or creates) a pipeline for the requested model.
    /// If the currently loaded model differs, the old pipeline is released first.
    func getPipeline(for model: Flux2Model, quality: ImageQuality) async throws -> Flux2Pipeline {
        if let existing = pipeline, loadedModel == model {
            return existing
        }

        // Release previous pipeline
        if let old = pipeline {
            await old.clearAll()
            pipeline = nil
            loadedModel = nil
            logger.info("Released previous Flux2 pipeline for model switch.")
        }

        let quantization: Flux2QuantizationConfig = quality == .hd ? .balanced : .memoryEfficient

        let newPipeline = Flux2Pipeline(
            model: model,
            quantization: quantization,
            memoryOptimization: .moderate
        )

        logger.info("Loading Flux2 pipeline: model=\(model.rawValue), quantization=\(String(describing: quantization))")
        try await newPipeline.loadModels()

        pipeline = newPipeline
        loadedModel = model
        return newPipeline
    }

    func releasePipeline() async {
        if let old = pipeline {
            await old.clearAll()
            pipeline = nil
            loadedModel = nil
            logger.info("Flux2 pipeline released.")
        }
    }
}

// MARK: - MLX Image Generation Service

/// Local image generation on Apple Silicon using Flux2 models via flux-2-swift-mlx.
/// Supports both Text-to-Image and Image-to-Image for all Flux2 model variants.
struct MLXImageGenService: ImageGenProvider, Sendable {
    let modelName: String

    init(modelName: String) {
        self.modelName = modelName
    }

    // MARK: - Text-to-Image

    func generateImage(
        prompt: String,
        negativePrompt: String?,
        options: ImageGenOptions,
        conversationID: UUID,
        progressHandler: (@Sendable (Int, Int) -> Void)?
    ) async throws -> MediaArtifact {
        let model = resolveFlux2Model()
        let (width, height) = options.aspectRatio.dimensions(baseSize: 1024)
        let (validWidth, validHeight) = LatentUtils.validateDimensions(height: height, width: width)

        let fullPrompt: String
        if let neg = negativePrompt, !neg.isEmpty {
            fullPrompt = "\(prompt)\n\nAvoid: \(neg)"
        } else {
            fullPrompt = prompt
        }

        let steps = options.steps ?? model.defaultSteps
        let guidance = Float(options.guidance ?? Double(model.defaultGuidance))

        logger.info("MLX T2I: model=\(model.rawValue), size=\(validWidth)x\(validHeight), steps=\(steps), guidance=\(guidance)")

        let pipeline = try await Flux2PipelineManager.shared.getPipeline(for: model, quality: options.quality)

        let cgImage = try await pipeline.generateTextToImage(
            prompt: fullPrompt,
            height: validHeight,
            width: validWidth,
            steps: steps,
            guidance: guidance,
            onProgress: progressHandler
        )

        return try await storeCGImage(cgImage, prompt: prompt, conversationID: conversationID)
    }

    // MARK: - Image-to-Image

    func generateImageVariation(
        prompt: String,
        negativePrompt: String?,
        inputImage: Data,
        options: ImageGenOptions,
        conversationID: UUID,
        progressHandler: (@Sendable (Int, Int) -> Void)?
    ) async throws -> MediaArtifact {
        let model = resolveFlux2Model()
        let (width, height) = options.aspectRatio.dimensions(baseSize: 1024)
        let (validWidth, validHeight) = LatentUtils.validateDimensions(height: height, width: width)

        let fullPrompt: String
        if let neg = negativePrompt, !neg.isEmpty {
            fullPrompt = "\(prompt)\n\nAvoid: \(neg)"
        } else {
            fullPrompt = prompt
        }

        let steps = options.steps ?? model.defaultSteps
        let guidance = Float(options.guidance ?? Double(model.defaultGuidance))

        logger.info("MLX I2I: model=\(model.rawValue), size=\(validWidth)x\(validHeight), steps=\(steps), guidance=\(guidance), inputSize=\(inputImage.count) bytes")

        let pipeline = try await Flux2PipelineManager.shared.getPipeline(for: model, quality: options.quality)

        let cgImage = try await pipeline.generateImageToImage(
            prompt: fullPrompt,
            imageData: [inputImage],
            height: validHeight,
            width: validWidth,
            steps: steps,
            guidance: guidance,
            onProgress: progressHandler
        )

        return try await storeCGImage(cgImage, prompt: prompt, conversationID: conversationID)
    }

    // MARK: - Helpers

    /// Maps the user-configured model name string to a Flux2Model enum case.
    private func resolveFlux2Model() -> Flux2Model {
        let normalized = modelName.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)

        // Try direct rawValue match first
        if let direct = Flux2Model(rawValue: normalized) {
            return direct
        }

        // Pattern matching for common name variants
        if normalized.contains("klein") && normalized.contains("4b") {
            return normalized.contains("base") ? .klein4BBase : .klein4B
        }
        if normalized.contains("klein") && normalized.contains("9b") {
            return normalized.contains("base") ? .klein9BBase : .klein9B
        }

        // Default to dev for unrecognized names
        logger.warning("Unrecognized Flux2 model name '\(self.modelName)', defaulting to .dev")
        return .dev
    }

    /// Converts a CGImage to PNG data, stores it via MediaStore, and returns a MediaArtifact.
    private func storeCGImage(_ cgImage: CGImage, prompt: String, conversationID: UUID) async throws -> MediaArtifact {
        guard let pngData = cgImageToPNGData(cgImage) else {
            throw ImageGenError.invalidResponse(detail: "Failed to encode generated image as PNG")
        }

        let reference = try await MediaStore.shared.store(
            data: pngData,
            mimeType: "image/png",
            conversationID: conversationID
        )

        return MediaArtifact(
            id: UUID(),
            kind: .image,
            reference: reference,
            mimeType: "image/png",
            label: String(prompt.prefix(60)),
            metadata: [
                "prompt": .string(prompt),
                "model": .string(modelName),
                "provider": .string("mlx")
            ],
            createdAt: Date()
        )
    }

    /// Converts a CGImage to PNG-encoded Data using ImageIO.
    private func cgImageToPNGData(_ image: CGImage) -> Data? {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil) else {
            return nil
        }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else {
            return nil
        }
        return data as Data
    }
}

#endif // MLX_IMAGE_GEN
