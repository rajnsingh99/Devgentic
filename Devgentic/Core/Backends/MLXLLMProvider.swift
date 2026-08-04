//
//  MLXLLMProvider.swift
//  Devgentic
//
//  Created by Devgentic Architect
//

import Foundation
import MLXLMCommon
import os

private let logger = Logger(subsystem: "com.devgentic", category: "MLXLLMProvider")

/// Thread-safe sink for the exact token counts MLXService surfaces via its terminal
/// completion event. `@unchecked Sendable` + a lock because the `@Sendable onUsage`
/// closure writes from the generation task while the calling method reads after the
/// stream drains. Local mirror of ChatExecutor's private `StreamUsageBox` (kept local
/// rather than widening that type's visibility).
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

    /// When the chat template's `{% if tools %}` branch fires, it prepends a large
    /// `<tools>...</tools>` block of JSON schemas to the system message. Recent-token
    /// repetition penalty at configured levels (1.20-1.30 for small Q4 models) can then
    /// distort the first-token sampling distribution enough to favor EOS — observed as
    /// "47s prefill, zero tokens emitted" failures. Capping at 1.15 for the native-tools
    /// path is a safe operating point: still penalizes degenerate loops, doesn't starve
    /// the model of initial tokens.
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

    /// Non-streaming generation that ALSO surfaces MLX's exact terminal token counts.
    /// Overrides the protocol default (text + nil usage → caller estimates via chars/4)
    /// so non-streaming callers (synthesis, reflection, planning) get real MLX numbers.
    /// Usage is nil only when generation stops early (no completion event) — the caller
    /// then estimates exactly as before, so this never regresses those paths.
    func generateWithUsage(messages: [[String: String]], tools: [[String: Any]]?, responseSchema: Any?) async throws -> (text: String, usage: TokenUsage?) {
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

        return (fullText, sink.value)
    }

    /// Multimodal (vision) path — serves BOTH the bot flow and, since MLX/legacy
    /// agent vision, the agent flow. Overrides the protocol default (which strips
    /// images via `toLegacyDict()`) to route attached images through the on-device
    /// VLM processor (`MLXService.streamVisionChat`). No images → falls back to the
    /// text path. (Detection in `MLXTokenizerAnalyzer` gates which models report
    /// `.visionInput`; the degrade-if-not-vision guard lives in the orchestrator.)
    ///
    /// `tools` here are the legacy/dialect PROMPTED tools already rendered into the
    /// system message, so `streamVisionChat` needs no tool-schema injection — but it
    /// DOES get the same stop sequences + repetition penalty as the text path, because
    /// the agent loop that calls this runs a small VLM that can loop just as badly with
    /// an image attached as without. The `nativeToolsPresent` cap does not apply: these
    /// tools never hit an `{% if tools %}` template branch (the processor owns
    /// templating here), so the configured penalty is used as-is.
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

        // [VISION] Confirms the bytes actually reach the on-device VLM (the last hop
        // before generation). Absence of this after a [MULTIMODAL]/[VISION] gate-pass
        // line means the image was lost between orchestration and the provider.
        logger.info("[VISION] MLX on-device VLM '\(modelName)': routing \(imageData.count) image(s) through streamVisionChat")

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
        return fullText
    }

    func stream(messages: [[String: String]], tools: [[String: Any]]?) -> AsyncThrowingStream<String, Error> {
        streamWithUsage(messages: messages, tools: tools, onUsage: nil)
    }

    /// Streams tokens AND surfaces MLX's exact terminal token counts through `onUsage`
    /// (see `MLXService.streamChat`). Overrides the protocol default (which drops usage,
    /// forcing the caller to estimate) so the Bot streaming path's usage badge and the
    /// context-window gauge show real MLX numbers. An early stop-sequence / circuit-breaker
    /// exit skips the completion event → `onUsage` never fires → the caller estimates,
    /// identical to the prior behaviour.
    func streamWithUsage(messages: [[String: String]], tools: [[String: Any]]?, onUsage: (@Sendable (TokenUsage) -> Void)?) -> AsyncThrowingStream<String, Error> {
        // Capture config values before entering the closure
        let config = generationConfig
        let templateSource = chatTemplateSource
        let stops = stopSequences
        let nativeToolsPresent = (tools?.isEmpty == false)
        let repPenalty = effectiveRepPenalty(nativeToolsPresent: nativeToolsPresent)

        return AsyncThrowingStream { continuation in
            // Capture the handle so a consumer teardown propagates all the way down to
            // MLXService's producer and the vendored evaluator. Discarding it here would
            // leave the GPU decoding after Stop even though MLXService now cancels
            // correctly — this is the outermost link in that chain.
            let producer = Task {
                do {
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
        // Empty registry is correct here: the only caller of this method is
        // NativeStructuredGenerator, which re-validates the result through
        // NativeParsePipeline (ToolNameResolver with the real [AgentTool]
        // registry). MLX never routes to the native generator today, so this
        // path is effectively dormant — but if it ever runs, validation is
        // layered above, same as OllamaLLMProvider's content fallback.
        let pipeline = CognitiveParsePipeline(
            expectedDialect: dialect,
            modelId: modelName,
            registeredTools: []
        )
        var step = pipeline.parse(raw: fullText)

        // Prefer MLX's exact terminal token counts (now surfaced via generateWithUsage);
        // fall back to a chars/4 estimate only when the run stopped before the completion
        // event fired (early stop sequence / circuit breaker).
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
