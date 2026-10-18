// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
//
//  ImageGenExecutor.swift
//  Devgentic
//
//  Created by Raj Singh.
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

    /// Whether `error` ended the generation because the user stopped it. The task's own cancellation flag is checked first,
    /// since a cloud provider's Stop can surface as `URLError(.cancelled)` or wrapped in `ImageGenError.providerError`.
    static func isStop(_ error: Error) -> Bool {
        if Task.isCancelled { return true }
        if error is CancellationError { return true }
        if let urlError = error as? URLError, urlError.code == .cancelled { return true }
        return false
    }

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
                // Per-generation span for telemetry.
                let genSpan = traceContext.newSpan()
                await TraceRecorder.shared.beginSpan(context: genSpan, name: "imageGen", kind: .llmCall)
                let genStart = Date()
                do {
                    // No feasibility gate: `capability` is guessed from the model's name, so it may label but never refuse. The provider
                    // attempts the request, and one that cannot do it throws its own `imageToImageNotSupported`, handled below.
                    let modelName = extractModelName(from: profile)
                    logCapabilityDisagreement(intent: intent, capability: capability, modelName: modelName)
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
                        logger.info("Executing T2I: prompt=\(prompt.count) chars")
                        artifact = try await provider.generateImage(
                            prompt: prompt,
                            negativePrompt: negativePrompt,
                            options: options,
                            conversationID: conversationID,
                            progressHandler: progressHandler
                        )

                    case .imageToImage(let prompt, let sourceImage, let inferred):
                        let negativePrompt = extractNegativePrompt(from: profile)
                        logger.info("Executing I2I: prompt=\(prompt.count) chars sourceSize=\(sourceImage.count) bytes inferred=\(inferred)")
                        do {
                            artifact = try await provider.generateImageVariation(
                                prompt: prompt,
                                negativePrompt: negativePrompt,
                                inputImage: sourceImage,
                                options: options,
                                conversationID: conversationID,
                                progressHandler: progressHandler
                            )
                        } catch ImageGenError.imageToImageNotSupported where inferred {
                            // The edit was only inferred from the wording (no image attached) and this provider cannot edit, so the prompt is
                            // drawn fresh rather than raising an error for a request the user never explicitly made.
                            logger.notice("[IMAGEGEN] '\(modelName)' cannot edit images, and this edit was inferred (no image attached). CONSEQUENCE: generating a NEW image from the prompt instead of showing an error.")
                            continuation.yield(.thought("\(modelName) can't edit the previous image, so this is a new image from your prompt.", id: UUID()))
                            artifact = try await provider.generateImage(
                                prompt: prompt,
                                negativePrompt: negativePrompt,
                                options: options,
                                conversationID: conversationID,
                                progressHandler: progressHandler
                            )
                        }
                    }

                    // STEP 3: YIELD RESULT
                    continuation.yield(.mediaProgress(toolName: "imageGen", percent: 1.0, status: "Complete"))
                    continuation.yield(.artifactProduced(artifact))

                    let genMs = Int(Date().timeIntervalSince(genStart) * 1000)
                    await TraceRecorder.shared.emitLLMResponse(span: genSpan, durationMs: genMs, preview: "image \(artifact.id)")
                    // Declared so the Model lane counts generation time (see `RunReportProjection.declaredModelMs`); the span also
                    // brackets the feasibility check, so its wall-clock is not used.
                    await TraceRecorder.shared.endSpan(
                        spanID: genSpan.spanID, status: .completed,
                        metadata: ["model": modelName, "duration_ms": "\(genMs)"])
                    logger.info("Image generation complete: \(artifact.id)")
                    continuation.yield(.executionFinished(outcome: .completed, reason: nil))
                    continuation.finish()

                } catch where Self.isStop(error) {
                    // User stop — no error card, and the outcome is `.cancelled`, not
                    // `.failed` (audit #8).
                    logger.notice("[IMAGEGEN] Image generation cancelled (\(String(describing: type(of: error)))). CONSEQUENCE: recorded as cancelled, no error card.")
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

    /// Logs when the guessed capability disagrees with what is about to be attempted, and changes nothing;
    /// the label is a hint for diagnosis, never a reason to refuse.
    private func logCapabilityDisagreement(intent: ImageIntent, capability: ImageModalitySupport, modelName: String) {
        switch intent {
        case .imageToImage where !capability.supportsImageToImage:
            logger.notice("[IMAGEGEN] '\(modelName)' is not labelled as supporting image-to-image, but the label is guessed from the name. CONSEQUENCE: attempting it anyway — the provider reports a real refusal if there is one.")
        case .textToImage where !capability.supportsTextToImage:
            logger.notice("[IMAGEGEN] '\(modelName)' is not labelled as supporting text-to-image, but the label is guessed from the name. CONSEQUENCE: attempting it anyway — the provider reports a real refusal if there is one.")
        default:
            break
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
