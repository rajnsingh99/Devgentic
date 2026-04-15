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

    func generate(messages: [[String: String]], tools: [[String: Any]]?, responseSchema: Any?) async throws -> String {
        var fullText = ""

        let stream = await MLXService.shared.streamChat(
            messages: messages,
            tools: tools,
            maxTokens: generationConfig.maxTokens,
            temperature: Float(generationConfig.temperature),
            topP: Float(generationConfig.topP),
            repetitionPenalty: Float(generationConfig.repetitionPenalty),
            repetitionContextSize: generationConfig.repetitionContextSize,
            chatTemplateSource: chatTemplateSource,
            stopSequences: stopSequences
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

        return AsyncThrowingStream { continuation in
            Task {
                do {
                    let tokenStream = await MLXService.shared.streamChat(
                        messages: messages,
                        tools: tools,
                        maxTokens: config.maxTokens,
                        temperature: Float(config.temperature),
                        topP: Float(config.topP),
                        repetitionPenalty: Float(config.repetitionPenalty),
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
        let pipeline = CognitiveParsePipeline(
            expectedDialect: dialect,
            modelId: modelName
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
