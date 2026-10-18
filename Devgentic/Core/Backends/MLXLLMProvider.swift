// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
//
//  MLXLLMProvider.swift
//  Devgentic
//
//  Created by Raj Singh.
//

import Foundation
import MLXLMCommon
import os

private let logger = Logger(subsystem: DGLogger.subsystem, category: "MLXLLMProvider")

/// Thread-safe sink for the exact token counts MLXService surfaces in its terminal completion event.
/// Locked because `onUsage` writes from the generation task while the caller reads after the stream drains.
/// Local mirror of ChatExecutor's private `StreamUsageBox`.
private final class MLXUsageSink: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: TokenUsage?
    var value: TokenUsage? {
        get { lock.lock(); defer { lock.unlock() }; return stored }
        set { lock.lock(); defer { lock.unlock() }; stored = newValue }
    }
}

/// Wraps the existing MLXService for on-device inference, adding support for tool calling.
struct MLXLLMProvider: LLMProvider {

    let modelName: String

    /// The on-disk model this provider was configured for. Threaded into every generation so
    /// `MLXService` serves THIS model or throws — the actor holds one global "last loaded"
    /// slot, and parallel workflow branches were able to answer from each other's models.
    let modelDirectory: URL?

    let dialect: ModelDialect
    let chatTemplateSource: ChatTemplateSource

    /// Custom stop sequences extracted from the model's tokenizer.
    /// Turn-boundary markers that signal generation should stop immediately.
    private let stopSequences: [String]

    /// Generation parameters from user configuration.
    /// When nil, uses MLXAdvancedConfig defaults optimized for agentic reasoning.
    private let generationConfig: MLXAdvancedConfig

    init(
        modelName: String,
        modelDirectory: URL? = nil,
        dialect: ModelDialect = .heuristicJson,
        chatTemplateSource: ChatTemplateSource = .embedded,
        stopSequences: [String] = [],
        advancedConfig: MLXAdvancedConfig? = nil
    ) {
        self.modelName = modelName
        self.modelDirectory = modelDirectory
        self.dialect = dialect
        self.chatTemplateSource = chatTemplateSource
        self.stopSequences = stopSequences
        self.generationConfig = advancedConfig ?? .default()
    }

    /// Caps the repetition penalty at 1.15 on the native-tools path, where the template prepends a large `<tools>` block.
    /// Higher penalties (1.20-1.30) on small Q4 models can bias first-token sampling toward EOS (zero tokens emitted).
    private static let nativeToolsMaxRepPenalty: Float = 1.15

    /// Resolves the effective repetition penalty for a given call, reducing it when
    /// native tool schemas are being injected via chat template.
    private func effectiveRepPenalty(nativeToolsPresent: Bool) -> Float {
        let configured = Float(generationConfig.repetitionPenalty)
        guard nativeToolsPresent else { return configured }
        return min(configured, Self.nativeToolsMaxRepPenalty)
    }

    func generate(messages: [[String: String]], tools: [[String: Any]]?, responseSchema: Any?) async throws -> String {
        try await generateWithUsage(messages: messages, tools: tools, responseSchema: responseSchema).text
    }

    /// Non-streaming generation that also surfaces MLX's exact terminal token counts.
    /// Overrides the protocol default so synthesis, reflection and planning get real counts; usage is nil only when
    /// generation stops early, in which case the caller estimates.
    func generateWithUsage(messages: [[String: String]], tools: [[String: Any]]?, responseSchema: Any?) async throws -> (text: String, usage: TokenUsage?) {
        // The local-inference gate: holds (or waits for) the local lock and counts this generation.
        let generation = try await LocalInferenceScope.beginGeneration(engine: .mlx, modelID: modelName)
        defer { generation.end() }
        let nativeToolsPresent = (tools?.isEmpty == false)
        let repPenalty = effectiveRepPenalty(nativeToolsPresent: nativeToolsPresent)
        let sink = MLXUsageSink()
        var fullText = ""

        let stream = await MLXService.shared.streamChat(
            expectedModelDirectory: modelDirectory,
            messages: messages,
            tools: tools,
            maxTokens: generationConfig.maxTokens,
            temperature: Float(generationConfig.temperature),
            topP: Float(generationConfig.topP),
            repetitionPenalty: repPenalty,
            repetitionContextSize: generationConfig.repetitionContextSize,
            chatTemplateSource: chatTemplateSource,
            stopSequences: stopSequences,
            onUsage: { sink.value = $0 }
        )

        for try await token in stream {
            fullText += token
        }
        try Self.throwIfCancelled(discarding: fullText, path: "generateWithUsage")

        return (fullText, sink.value)
    }

    // Why: `MLXService` ends its stream normally on cancellation and never throws, so loops would return half an answer.
    /// Ends a cancelled call as a cancellation instead of returning `partial` as a complete answer;
    /// callers that want the partial text catch it and label it partial.
    static func throwIfCancelled(discarding partial: String, path: String) throws {
        guard Task.isCancelled else { return }
        logger.notice("[MLX-GEN] \(path, privacy: .public) was cancelled after \(partial.count) chars. CONSEQUENCE: the partial text is NOT returned as an answer; the caller sees a cancellation.")
        throw CancellationError()
    }

    /// Multimodal (vision) path for bot and agent flows: routes attached images through the on-device VLM processor.
    /// Overrides the protocol default, which strips images; with no images it falls back to the text path.
    /// `tools` are already rendered into the system message; stop sequences and repetition penalty match the text path.
    func generate(payload: [ProviderMessage], tools: [[String: Any]]?, responseSchema: Any?) async throws -> String {
        // Collect attached image bytes (resolve() throws on missing/unreadable → surfaced).
        var imageData: [Data] = []
        for pm in payload {
            for block in pm.content {
                if case .image(let img) = block {
                    imageData.append(try await img.reference.resolve())
                }
            }
        }

        let messages = payload.map { $0.toLegacyDict() }   // role + flattened text

        // No images → ordinary text generation (preserves the legacy downgrade behaviour).
        guard !imageData.isEmpty else {
            return try await generate(messages: messages, tools: tools, responseSchema: responseSchema)
        }

        // [VISION] Confirms the image bytes reach the on-device VLM; its absence after the gate-pass lines means the image
        // was lost between orchestration and the provider.
        logger.info("[VISION] MLX on-device VLM '\(modelName)': routing \(imageData.count) image(s) through streamVisionChat")

        let generation = try await LocalInferenceScope.beginGeneration(engine: .mlx, modelID: modelName)
        defer { generation.end() }
        var fullText = ""
        let stream = await MLXService.shared.streamVisionChat(
            expectedModelDirectory: modelDirectory,
            messages: messages,
            imageData: imageData,
            maxTokens: generationConfig.maxTokens,
            temperature: Float(generationConfig.temperature),
            topP: Float(generationConfig.topP),
            repetitionPenalty: Float(generationConfig.repetitionPenalty),
            repetitionContextSize: generationConfig.repetitionContextSize,
            stopSequences: stopSequences
        )
        for try await token in stream {
            fullText += token
        }
        try Self.throwIfCancelled(discarding: fullText, path: "generate(payload:)")
        return fullText
    }

    func stream(messages: [[String: String]], tools: [[String: Any]]?) -> AsyncThrowingStream<String, Error> {
        streamWithUsage(messages: messages, tools: tools, onUsage: nil)
    }

    /// Streams tokens and surfaces MLX's exact terminal token counts through `onUsage` (see `MLXService.streamChat`).
    /// An early stop-sequence or circuit-breaker exit skips the completion event, so `onUsage` never fires.
    func streamWithUsage(messages: [[String: String]], tools: [[String: Any]]?, onUsage: (@Sendable (TokenUsage) -> Void)?) -> AsyncThrowingStream<String, Error> {
        // Capture config values before entering the closure
        let config = generationConfig
        let templateSource = chatTemplateSource
        let stops = stopSequences
        let nativeToolsPresent = (tools?.isEmpty == false)
        let repPenalty = effectiveRepPenalty(nativeToolsPresent: nativeToolsPresent)

        return AsyncThrowingStream { continuation in
            // Why: create it inside the caller's task so it inherits `LocalInferenceScope.runID`, which the gate below reads.
            // Capture the handle so a consumer teardown reaches MLXService's producer and the evaluator; discarding it would
            // leave the GPU decoding after Stop.
            let producer = Task {
                do {
                    let generation = try await LocalInferenceScope.beginGeneration(engine: .mlx, modelID: modelName)
                    defer { generation.end() }
                    let tokenStream = await MLXService.shared.streamChat(
                        expectedModelDirectory: modelDirectory,
                        messages: messages,
                        tools: tools,
                        maxTokens: config.maxTokens,
                        temperature: Float(config.temperature),
                        topP: Float(config.topP),
                        repetitionPenalty: repPenalty,
                        repetitionContextSize: config.repetitionContextSize,
                        chatTemplateSource: templateSource,
                        stopSequences: stops,
                        onUsage: onUsage
                    )

                    for try await token in tokenStream {
                        continuation.yield(token)
                    }

                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }

            continuation.onTermination = { @Sendable _ in
                producer.cancel()
            }
        }
    }

    func generateCognitiveStep(messages: [[String: String]], tools: [[String: Any]]?) async throws -> ModernCognitiveStep {
        let (fullText, realUsage) = try await generateWithUsage(messages: messages, tools: tools, responseSchema: nil)
        // Empty registry is correct: the only caller, NativeStructuredGenerator, re-validates the result through
        // NativeParsePipeline with the real tool registry, so validation is layered above (as in OllamaLLMProvider).
        let pipeline = CognitiveParsePipeline(
            expectedDialect: dialect,
            modelId: modelName,
            registeredTools: []
        )
        var step = pipeline.parse(raw: fullText)

        // Prefer MLX's exact terminal token counts; fall back to a chars/4 estimate only when the run stopped before the
        // completion event fired (early stop sequence or circuit breaker).
        let inputChars = messages.reduce(0) { $0 + ($1["content"]?.count ?? 0) }
        step = ModernCognitiveStep(
            reasoning: step.reasoning,
            thought: step.thought,
            toolCalls: step.toolCalls,
            tokenUsage: realUsage ?? .estimated(inputChars: inputChars, outputChars: fullText.count)
        )

        return step
    }
}
