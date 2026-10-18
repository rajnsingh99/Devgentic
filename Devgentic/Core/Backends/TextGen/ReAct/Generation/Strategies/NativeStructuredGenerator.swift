// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
//
//  NativeStructuredGenerator.swift
//  Devgentic
//
//  Created by Raj Singh.
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

    /// Builds the initial `{role, content}` messages (system + history) that seed `liveConversationTurns` at iteration 1.
    /// Working memory is excluded; the native path emits observations as `tool` role turns between iterations.
    func compileMessages(from context: SemanticContext) -> [[String: String]] {
        return buildStandardMessages(
            context: context,
            dialectRules: dialectRules,
            isNativeFlow: true,
            layerConfig: context.promptLayerConfig,
            includeWorkingMemory: false,
            // Why: rendering them here too would emit a duplicate consecutive user message
            // Excluded like working memory: the executor delivers attachments in its kickoff user turn.
            includeAttachmentContext: false,
            // Per-message context (history, time, retrieval) leads the executor's kickoff turn; workflow nodes have no kickoff.
            includeTurnContext: context.workflowContext != nil
        )
    }

    /// `CognitiveGenerator` conformance for executors that skip the native-turn state machine (tests, alternate executors).
    /// `ReActAgentExecutor` uses `generateNativeStep` instead; this path loses the cross-iteration KV cache benefit.
    func generateCognitiveStep(model: any LLMProvider, context: SemanticContext, iteration: Int) async throws -> ModernCognitiveStep {
        let executionMessages = compileMessages(from: context)
        let nativeTools = toolAdapter.formatForNativeAPI(context.availableTools)
        let raw = try await model.generateCognitiveStep(messages: executionMessages, tools: nativeTools)
        try Self.refuseEmptyReply(raw, model: model.modelName, reqId: "conformance")
        return NativeParsePipeline(
            registeredTools: context.availableTools,
            modelId: model.modelName,
            iteration: iteration
        ).validate(step: raw)
    }

    /// Native-turn generation: forwards the executor's `nativeMessages` to the provider's native API.
    /// Validates tool names against the registered registry before returning.
    func generateNativeStep(
        model: any LLMProvider,
        nativeMessages: [[String: Any]],
        availableTools: [AgentTool],
        iteration: Int,
        runToolNames: Set<String> = [],
        onTextDelta: (@Sendable (String) -> Void)? = nil
    ) async throws -> ModernCognitiveStep {
        let reqId = UUID().uuidString.prefix(8)
        logLLMOps.info("⚡️ [Native:\(reqId)] Start Generation - Iteration: \(iteration) | turns=\(nativeMessages.count)")

        let nativeTools = toolAdapter.formatForNativeAPI(availableTools)

        logLLMOps.debug("📤 [Native:\(reqId)] Sending native-turn request to model...")
        let startTime = Date()

        // Streamed when the caller wants the text live (see `AgentStreamEvent.draftText`); a
        // provider without a streaming implementation falls back to the blocking call.
        let raw: ModernCognitiveStep
        if let onTextDelta {
            raw = try await model.generateCognitiveStepStreaming(
                nativeMessages: nativeMessages, tools: nativeTools, onTextDelta: onTextDelta)
        } else {
            raw = try await model.generateCognitiveStep(
                nativeMessages: nativeMessages,
                tools: nativeTools
            )
        }

        let duration = Date().timeIntervalSince(startTime)
        logLLMOps.info("✅ [Native:\(reqId)] Response received in \(String(format: "%.4f", duration))s")
        try Self.refuseEmptyReply(raw, model: model.modelName, reqId: String(reqId))
        logLLMOps.debug("📄 [Native:\(reqId)] Raw step. \(raw.toolCalls.count) tool calls pre-validation.")

        // Validates tool names and repairs argument keys against the runtime registry.
        // `runToolNames` lets a zero-call step be recognised as a broken call to any tool this run offers.
        let validated = NativeParsePipeline(
            registeredTools: availableTools,
            modelId: model.modelName,
            iteration: iteration,
            runToolNames: runToolNames
        ).validate(step: raw)

        logLLMOps.info("✅ [Native:\(reqId)] Post-validate: \(validated.toolCalls.count) tool(s), outcome=\(String(describing: validated.parseOutcome))")

        return validated
    }
    // Why: otherwise an empty reply validates as a genuine completion and the run ends with a canned answer
    /// Throws `GenerationError.emptyResponse` for a step with no text and no tool call.
    /// Takes the same bounded-retry path (`LLMRetryStrategy`) as every other generator's empty reply.
    static func refuseEmptyReply(_ step: ModernCognitiveStep, model: String, reqId: String) throws {
        guard step.toolCalls.isEmpty,
              step.reasoning.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        let thoughtChars = step.thought?.count ?? 0
        logLLMOps.error("❌ [Native:\(reqId)] Empty reply from '\(model)' — no text and no tool call\(thoughtChars > 0 ? " (\(thoughtChars) chars of reasoning: it likely spent the whole output-token limit)" : ""). CONSEQUENCE: retried as an empty response, not accepted as a finished answer.")
        throw GenerationError.emptyResponse(generator: "Native")
    }
}
