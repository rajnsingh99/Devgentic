//
//  MLXLLMProvider.swift
//  Devgentic
//
//  Created by Devgentic Architect
//

import Foundation
import MLXLMCommon

/// Wraps the existing MLXService for on-device inference, adding support for tool calling.
struct MLXLLMProvider: LLMProvider {

    let modelName: String
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
        dialect: ModelDialect = .heuristicJson,
        chatTemplateSource: ChatTemplateSource = .embedded,
        stopSequences: [String] = [],
        advancedConfig: MLXAdvancedConfig? = nil
    ) {
        self.modelName = modelName
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
        var fullText = ""

        let nativeToolsPresent = (tools?.isEmpty == false)
        let repPenalty = effectiveRepPenalty(nativeToolsPresent: nativeToolsPresent)

        let stream = await MLXService.shared.streamChat(
            messages: messages,
            tools: tools,
            maxTokens: generationConfig.maxTokens,
            temperature: Float(generationConfig.temperature),
            topP: Float(generationConfig.topP),
            repetitionPenalty: repPenalty,
            repetitionContextSize: generationConfig.repetitionContextSize,
            chatTemplateSource: chatTemplateSource,
            stopSequences: stopSequences
        )

        for try await token in stream {
            fullText += token
        }

        return fullText
    }

    /// Multimodal (vision) bot path. Overrides the protocol default — which strips
    /// images via `toLegacyDict()` — to route attached images through the on-device
    /// VLM processor (`MLXService.streamVisionChat`). No images → falls back to the
    /// text path. (Detection in `MLXTokenizerAnalyzer` gates which models report
    /// `.visionInput`; Phase D adds the degrade-if-not-vision guard.)
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

        var fullText = ""
        let stream = await MLXService.shared.streamVisionChat(
            messages: messages,
            imageData: imageData,
            maxTokens: generationConfig.maxTokens,
            temperature: Float(generationConfig.temperature),
            topP: Float(generationConfig.topP)
        )
        for try await token in stream {
            fullText += token
        }
        return fullText
    }

    func stream(messages: [[String: String]], tools: [[String: Any]]?) -> AsyncThrowingStream<String, Error> {
        // Capture config values before entering the closure
        let config = generationConfig
        let templateSource = chatTemplateSource
        let stops = stopSequences
        let nativeToolsPresent = (tools?.isEmpty == false)
        let repPenalty = effectiveRepPenalty(nativeToolsPresent: nativeToolsPresent)

        return AsyncThrowingStream { continuation in
            Task {
                do {
                    let tokenStream = await MLXService.shared.streamChat(
                        messages: messages,
                        tools: tools,
                        maxTokens: config.maxTokens,
                        temperature: Float(config.temperature),
                        topP: Float(config.topP),
                        repetitionPenalty: repPenalty,
                        repetitionContextSize: config.repetitionContextSize,
                        chatTemplateSource: templateSource,
                        stopSequences: stops
                    )

                    for try await token in tokenStream {
                        continuation.yield(token)
                    }

                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
        }
    }

    func generateCognitiveStep(messages: [[String: String]], tools: [[String: Any]]?) async throws -> ModernCognitiveStep {
        let fullText = try await generate(messages: messages, tools: tools, responseSchema: nil)
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

        // MLX doesn't expose token counts — use heuristic estimation
        let inputChars = messages.reduce(0) { $0 + ($1["content"]?.count ?? 0) }
        step = ModernCognitiveStep(
            reasoning: step.reasoning,
            thought: step.thought,
            toolCalls: step.toolCalls,
            tokenUsage: .estimated(inputChars: inputChars, outputChars: fullText.count)
        )

        return step
    }
}
