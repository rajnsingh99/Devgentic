//
//  NativeStructuredGenerator.swift
//  Devgentic
//
//  G12 Native-Turn Refactor:
//  - Holds both a `ToolSchemaAdapter` (outgoing tool definitions) and a
//    `ToolTurnAdapter` (conversational assistant/tool turns).
//  - On the native path the executor owns `liveConversationTurns` and threads them
//    into `generateNativeStep` each iteration. Scratchpad is NOT compiled into a
//    user message — observations flow as real `tool` role turns.
//  - MLX / dialect generators remain on the legacy `<working_memory>` path; this
//    generator is only used when the provider supports native tool-calling
//    (Claude, OpenAI, Gemini, Ollama-native).
//

import Foundation
import OSLog

private let logLLMOps = DGLogger(category: "LLMOps")

/// Native-tool-calling generator. Used for cloud providers and Ollama-native.
/// Cooperates with the executor's native-turn state machine via `generateNativeStep`.
struct NativeStructuredGenerator: CognitiveGenerator {
    let toolAdapter: ToolSchemaAdapter
    let toolTurnAdapter: ToolTurnAdapter
    let dialectRules: String?

    init(
        toolAdapter: ToolSchemaAdapter = NativeJSONSchemaAdapter(),
        toolTurnAdapter: ToolTurnAdapter = OllamaToolTurnAdapter(),
        dialectRules: String? = nil
    ) {
        self.toolAdapter = toolAdapter
        self.toolTurnAdapter = toolTurnAdapter
        self.dialectRules = dialectRules
    }

    /// Builds the initial canonical `{role, content}` messages (system + history) for
    /// the executor to seed `liveConversationTurns` at iter 1. Working memory is
    /// explicitly excluded — the native path doesn't re-serialize observations as a
    /// user message; it emits them as real `tool` role turns between iterations.
    func compileMessages(from context: SemanticContext) -> [[String: String]] {
        return buildStandardMessages(
            context: context,
            dialectRules: dialectRules,
            isNativeFlow: true,
            layerConfig: context.promptLayerConfig,
            includeWorkingMemory: false,
            // Like working memory: the native executor delivers attachments in the
            // kickoff user turn it appends after these seeded messages — rendering
            // them here too would emit a duplicate consecutive user message.
            includeAttachmentContext: false
        )
    }

    /// `CognitiveGenerator` protocol conformance — required entrypoint for executors
    /// that don't use the native-turn state machine (tests, alternate executors).
    /// `ReActAgentExecutor` branches on `NativeStructuredGenerator` and uses
    /// `generateNativeStep` instead, so this path is only exercised by callers that
    /// don't know about the native conversation array. Still functional — just loses
    /// the cross-iteration KV cache benefit.
    func generateCognitiveStep(model: any LLMProvider, context: SemanticContext, iteration: Int) async throws -> ModernCognitiveStep {
        let executionMessages = compileMessages(from: context)
        let nativeTools = toolAdapter.formatForNativeAPI(context.availableTools)
        let raw = try await model.generateCognitiveStep(messages: executionMessages, tools: nativeTools)
        return NativeParsePipeline(
            registeredTools: context.availableTools,
            modelId: model.modelName,
            iteration: iteration
        ).validate(step: raw)
    }

    /// Native-turn generation. The executor builds and maintains `nativeMessages`
    /// across iterations (system, history, user, assistant(tool_calls), tool(result), …);
    /// this method just forwards it to the provider's native API, then validates
    /// tool names against the registered registry before returning.
    func generateNativeStep(
        model: any LLMProvider,
        nativeMessages: [[String: Any]],
        availableTools: [AgentTool],
        iteration: Int
    ) async throws -> ModernCognitiveStep {
        let reqId = UUID().uuidString.prefix(8)
        logLLMOps.info("⚡️ [Native:\(reqId)] Start Generation - Iteration: \(iteration) | turns=\(nativeMessages.count)")

        let nativeTools = toolAdapter.formatForNativeAPI(availableTools)

        logLLMOps.debug("📤 [Native:\(reqId)] Sending native-turn request to model...")
        let startTime = Date()

        let raw = try await model.generateCognitiveStep(
            nativeMessages: nativeMessages,
            tools: nativeTools
        )

        let duration = Date().timeIntervalSince(startTime)
        logLLMOps.info("✅ [Native:\(reqId)] Response received in \(String(format: "%.4f", duration))s")
        logLLMOps.debug("📄 [Native:\(reqId)] Raw step. \(raw.toolCalls.count) tool calls pre-validation.")

        // Validate tool names + repair arg keys against the runtime registry.
        // This catches hallucinated tool names from models that sneak wrong names
        // past the provider's API (Ollama content-fallback, or occasional cloud
        // provider drift under prompt pressure).
        let validated = NativeParsePipeline(
            registeredTools: availableTools,
            modelId: model.modelName,
            iteration: iteration
        ).validate(step: raw)

        logLLMOps.info("✅ [Native:\(reqId)] Post-validate: \(validated.toolCalls.count) tool(s), outcome=\(String(describing: validated.parseOutcome))")

        return validated
    }
}
