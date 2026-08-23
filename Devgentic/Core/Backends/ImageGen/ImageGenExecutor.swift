//
//  ImageGenExecutor.swift
//  Devgentic
//
//  Created by Raj Singh on 15/03/26.
//
//  Lightweight, stateless executor for image generation.
//  Unlike ReAct/Plan&Execute executors, this has no iteration loops —
//  it performs a single feasibility check → generate → yield result flow.
//

import Foundation
import os

private let logger = DGLogger(category: "ImageGenExecutor")

// MARK: - Image Generation Executor

/// A stateless executor that orchestrates image generation by:
/// 1. Checking feasibility (intent vs. model capabilities)
/// 2. Delegating to the appropriate `ImageGenProvider`
/// 3. Streaming progress and result events via `AgentStreamEvent`
struct ImageGenExecutor: Sendable {

    /// Executes an image generation request and returns a stream of events.
    /// - Parameters:
    ///   - intent: The resolved user intent (T2I or I2I).
    ///   - provider: The image generation provider to use.
    ///   - capability: The model's image generation capabilities.
    ///   - profile: The backend profile configuration.
    ///   - conversationID: Current conversation ID for storage scoping.
    ///   - options: Generation options (aspect ratio, quality, etc.).
    /// - Returns: An `AsyncThrowingStream` of `AgentStreamEvent`.
    func execute(
        intent: ImageIntent,
        provider: ImageGenProvider,
        capability: ImageModalitySupport,
        profile: BackendProfileModel,
        conversationID: UUID,
        traceContext: TraceContext,
        options: ImageGenOptions
    ) -> AsyncThrowingStream<AgentStreamEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                // Per-generation span — ImageGen previously recorded ZERO telemetry (Gap #7).
                let genSpan = traceContext.newSpan()
                await TraceRecorder.shared.beginSpan(context: genSpan, name: "imageGen", kind: .llmCall)
                let genStart = Date()
                do {
                    // STEP 1: FEASIBILITY CHECK
                    try checkFeasibility(intent: intent, capability: capability, profile: profile, continuation: continuation)

                    // STEP 2: GENERATE
                    let modelName = extractModelName(from: profile)
                    await TraceRecorder.shared.emitLLMRequest(span: genSpan, model: modelName, messageCount: 1)
                    let thoughtId = UUID()
                    continuation.yield(.thought("Generating image with \(modelName)...", id: thoughtId))
                    continuation.yield(.mediaProgress(toolName: "imageGen", percent: 0.0, status: "Starting generation"))

                    let progressHandler: @Sendable (Int, Int) -> Void = { current, total in
                        let percent = total > 0 ? Double(current) / Double(total) : 0.0
                        continuation.yield(.mediaProgress(
                            toolName: "imageGen",
                            percent: percent,
                            status: "Step \(current)/\(total)"
                        ))
                    }

                    let artifact: MediaArtifact

                    switch intent {
                    case .textToImage(let prompt):
                        let negativePrompt = extractNegativePrompt(from: profile)
                        logger.info("Executing T2I: prompt='\(prompt.prefix(50))...'")
                        artifact = try await provider.generateImage(
                            prompt: prompt,
                            negativePrompt: negativePrompt,
                            options: options,
                            conversationID: conversationID,
                            progressHandler: progressHandler
                        )

                    case .imageToImage(let prompt, let sourceImage):
                        let negativePrompt = extractNegativePrompt(from: profile)
                        logger.info("Executing I2I: prompt='\(prompt.prefix(50))...' sourceSize=\(sourceImage.count) bytes")
                        artifact = try await provider.generateImageVariation(
                            prompt: prompt,
                            negativePrompt: negativePrompt,
                            inputImage: sourceImage,
                            options: options,
                            conversationID: conversationID,
                            progressHandler: progressHandler
                        )
                    }

                    // STEP 3: YIELD RESULT
                    continuation.yield(.mediaProgress(toolName: "imageGen", percent: 1.0, status: "Complete"))
                    continuation.yield(.artifactProduced(artifact))

                    let genMs = Int(Date().timeIntervalSince(genStart) * 1000)
                    await TraceRecorder.shared.emitLLMResponse(span: genSpan, durationMs: genMs, preview: "image \(artifact.id)")
                    // Declared so the Model lane counts generation time (see
                    // RunReportProjection.declaredModelMs). The span itself also brackets the
                    // feasibility check, so its wall-clock must not be used.
                    await TraceRecorder.shared.endSpan(
                        spanID: genSpan.spanID, status: .completed,
                        metadata: ["model": modelName, "duration_ms": "\(genMs)"])
                    logger.info("Image generation complete: \(artifact.id)")
                    continuation.yield(.executionFinished(outcome: .completed, reason: nil))
                    continuation.finish()

                } catch is CancellationError {
                    // User stop — no error card, and the outcome is `.cancelled`, not
                    // `.failed` (audit #8).
                    logger.notice("Image generation cancelled")
                    await TraceRecorder.shared.endSpan(spanID: genSpan.spanID, status: .error)
                    continuation.yield(.executionFinished(outcome: .cancelled, reason: "Cancelled by user"))
                    continuation.finish()
                } catch let error as ImageGenError {
                    logger.error("ImageGen error: \(error.localizedDescription)")
                    await TraceRecorder.shared.endSpan(spanID: genSpan.spanID, status: .error)
                    // Keep yielding `.error` (renders the category-aware card); also report a
                    // failed terminal outcome so the trace status isn't recorded as `completed` (Gap #7).
                    continuation.yield(.error(.init(error.localizedDescription)))
                    continuation.yield(.executionFinished(outcome: .failed, reason: error.localizedDescription))
                    continuation.finish()
                } catch {
                    logger.error("Unexpected error during image generation: \(error.localizedDescription)")
                    await TraceRecorder.shared.endSpan(spanID: genSpan.spanID, status: .error)
                    continuation.yield(.error("Image generation failed: \(error.localizedDescription)"))
                    continuation.yield(.executionFinished(outcome: .failed, reason: error.localizedDescription))
                    continuation.finish()
                }
            }
            // Propagate stream teardown (user stop) into the producer — without this the
            // generation kept running orphaned to completion after cancel (audit #8).
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    // MARK: - Private Helpers

    /// Checks if the resolved intent is compatible with the model's capabilities.
    /// Throws an error (via continuation) and halts if there's a mismatch.
    private func checkFeasibility(
        intent: ImageIntent,
        capability: ImageModalitySupport,
        profile: BackendProfileModel,
        continuation: AsyncThrowingStream<AgentStreamEvent, Error>.Continuation
    ) throws {
        switch intent {
        case .imageToImage:
            guard capability.supportsImageToImage else {
                let modelName = extractModelName(from: profile)
                let errorMsg = "The model '\(modelName)' does not support Image-to-Image variations. Please select a model with I2I capability (e.g., Gemini or MLX Flux2), or provide a fresh text prompt."
                continuation.yield(.error(.init(errorMsg)))
                continuation.finish()
                throw ImageGenError.imageToImageNotSupported(modelName: modelName)
            }

        case .textToImage:
            guard capability.supportsTextToImage else {
                let modelName = extractModelName(from: profile)
                let errorMsg = "The model '\(modelName)' does not support Text-to-Image generation."
                continuation.yield(.error(.init(errorMsg)))
                continuation.finish()
                throw ImageGenError.textToImageNotSupported(modelName: modelName)
            }
        }
    }

    /// Extracts the model name from the profile's details.
    private func extractModelName(from profile: BackendProfileModel) -> String {
        switch profile.details {
        case .imageGen(let config):
            return config.llmConfig.modelName
        default:
            return "Unknown"
        }
    }

    /// Extracts the negative prompt from the profile's imageGen details.
    private func extractNegativePrompt(from profile: BackendProfileModel) -> String? {
        switch profile.details {
        case .imageGen(let config):
            return config.negativePrompt
        default:
            return nil
        }
    }
}
