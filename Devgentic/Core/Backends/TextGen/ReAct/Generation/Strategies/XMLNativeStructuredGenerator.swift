// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2026 Raj Singh
//
//  XMLNativeStructuredGenerator.swift
//  Devgentic
//
//  Parallel-capable cognitive strategy for Mistral-family models on MLX.
//  These models are fine-tuned to output tool calls in XML boundaries
//  (<tool_call>...</tool_call>) and struggle when forced into JSON prompting.
//  Unlike Ollama (whose API abstracts the format), MLX generates raw text
//  with no intermediary — so we must speak the model's native XML dialect.
//
//  Created by Raj Singh on 15/04/26.
//

import Foundation
import OSLog

private let logLLMOps = DGLogger(category: "LLMOps")

/// A parallel-capable cognitive strategy for Mistral-family MLX models that
/// produce tool calls in pseudo-XML format (`<tool_call>...</tool_call>`).
///
/// Mirrors `MLXNativeStructuredGenerator` in structure but uses XML dialect rules
/// and routes parsing through the `MistralXMLParser` (via `.mistralXML` pipeline).
struct XMLNativeStructuredGenerator: CognitiveGenerator {

    /// The one value this generator both declares and parses with.
    private static let dialect: ModelDialect = .mistralXML
    var expectedDialect: ModelDialect? { Self.dialect }
    let toolAdapter: ToolSchemaAdapter

    let dialectRules: String? = """
    RESPONSE FORMAT:
    You MUST respond using XML tool_call blocks.
    <tool_call>
      <content>Your reasoning about what to do next</content>
      <tool_name>exact_tool_name</tool_name>
      <arguments>{"key": "value"}</arguments>
    </tool_call>

    RULES:
    1. <content> is REQUIRED inside each block and should contain your logical reasoning.
    2. You can output MULTIPLE <tool_call> blocks if the tools are independent.
    3. The JSON inside <arguments> must be valid and strictly use double quotes.
    4. To end the task, emit a single <tool_call> with <tool_name>final_answer</tool_name>
       and <arguments>{"answer": "your complete response"}</arguments>. This is the ONLY
       way to terminate — do NOT output plain text outside a <tool_call> block as a
       termination signal.
    5. NEVER invent tool names. Use only tools from the TOOLS list.
    """

    /// Markdown wrapping avoids conflicts between XML prompt sections and XML tool output.
    var promptWrapping: PromptWrapping { .markdown }

    init(toolAdapter: ToolSchemaAdapter = PromptedMarkdownAdapter()) {
        self.toolAdapter = toolAdapter
    }

    func compileMessages(from context: SemanticContext) -> [[String: String]] {
        return buildStandardMessages(context: context, dialectRules: dialectRules, isNativeFlow: false, layerConfig: context.promptLayerConfig, wrapping: .markdown)
    }

    func promptTrigger(for iteration: Int) -> String {
        let base = iteration == 1
            ? "Analyze the task and working memory, then decide your next action."
            : "New observations have been recorded in working memory. Decide your next action."
        return base + " Respond with <tool_call> blocks for any tools needed."
    }

    func generateCognitiveStep(
        model: any LLMProvider,
        context: SemanticContext,
        iteration: Int
    ) async throws -> ModernCognitiveStep {
        let reqId = UUID().uuidString.prefix(8)
        logLLMOps.info("⚡️ [XMLNative:\(reqId)] Start Generation - Iteration: \(iteration)")

        logLLMOps.debug("📤 [XMLNative:\(reqId)] Sending request...")
        let startTime = Date()

        // Multimodal when the turn carries images; byte-identical text path otherwise.
        let responseText = try await generatePromptedResponse(model: model, context: context, iteration: iteration, responseSchema: nil, label: "XMLNative:\(reqId)")

        let duration = Date().timeIntervalSince(startTime)
        logLLMOps.info("✅ [XMLNative:\(reqId)] Response received in \(String(format: "%.4f", duration))s")
        logLLMOps.debug("📄 [XMLNative:\(reqId)] Raw:\n\(responseText)")

        guard !responseText.isEmpty else {
            logLLMOps.error("❌ [XMLNative:\(reqId)] Empty response from model.")
            throw GenerationError.emptyResponse(generator: "XMLNative")
        }

        let pipeline = CognitiveParsePipeline(
            expectedDialect: Self.dialect,
            modelId: model.modelName,
            iteration: iteration,
            knownToolNames: Set(context.availableTools.map(\.name)),
            registeredTools: context.availableTools
        )
        return pipeline.parse(raw: responseText)
    }
}
