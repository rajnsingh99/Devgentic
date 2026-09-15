// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2026 Raj Singh
//
//  XMLStructuredGenerator.swift
//  Devgentic
//
//  Step 2.2: Dialect-specific generator for the .mistralXML dialect.
//  Injects <tool_call> wrapping instructions with hybrid tags (<content>, <tool_name>, <arguments>).
//
//  Created by Raj Singh on 06/03/26.
//

import Foundation
import OSLog

private let logLLMOps = DGLogger(category: "LLMOps")

// MARK: - Strategy: XML Structured Generator

/// A cognitive strategy for Mistral-family models that wrap tool calls in
/// pseudo-XML boundaries (<tool_call>...</tool_call>).
struct XMLStructuredGenerator: CognitiveGenerator {

    /// The one value this generator both declares and parses with.
    private static let dialect: ModelDialect = .mistralXML
    var expectedDialect: ModelDialect? { Self.dialect }
    let toolAdapter: ToolSchemaAdapter

    let dialectRules: String? = """
    TOOL CALLING FORMAT:
    When you need to call a tool, you MUST use the following XML format EXACTLY:
    <tool_call>
      <content>Your reasoning about what to do next</content>
      <tool_name>exact_tool_name</tool_name>
      <arguments>{"key": "value"}</arguments>
    </tool_call>

    RULES:
    1. Only one <tool_call> block per response unless explicitly running parallel calls.
    2. The JSON inside <arguments> must be valid and strictly use double quotes.
    3. Place your reasoning ONLY inside the <content> tag.
    4. To end the task, emit a single <tool_call> with <tool_name>final_answer</tool_name>
       and <arguments>{"answer": "your complete response"}</arguments>. This is the ONLY
       way to terminate — do NOT output plain text outside a <tool_call> block as a
       termination signal.
    5. NEVER invent tool names. Use only tools from the TOOLS list.
    """

    init(toolAdapter: ToolSchemaAdapter = LegacyPromptAdapter()) {
        self.toolAdapter = toolAdapter
    }

    func compileMessages(from context: SemanticContext) -> [[String: String]] {
        return buildStandardMessages(context: context, dialectRules: dialectRules, layerConfig: context.promptLayerConfig)
    }

    func generateCognitiveStep(
        model: any LLMProvider,
        context: SemanticContext,
        iteration: Int
    ) async throws -> ModernCognitiveStep {
        let reqId = UUID().uuidString.prefix(8)
        logLLMOps.info("⚡️ [MistralXML:\(reqId)] Start Generation - Iteration: \(iteration)")

        logLLMOps.debug("📤 [MistralXML:\(reqId)] Sending request...")
        let startTime = Date()

        // Multimodal when the turn carries images; byte-identical text path otherwise.
        let responseText = try await generatePromptedResponse(model: model, context: context, iteration: iteration, responseSchema: nil, label: "MistralXML:\(reqId)")

        let duration = Date().timeIntervalSince(startTime)
        logLLMOps.info("✅ [MistralXML:\(reqId)] Response received in \(String(format: "%.4f", duration))s")
        logLLMOps.debug("📄 [MistralXML:\(reqId)] Raw:\n\(responseText)")

        guard !responseText.isEmpty else {
            logLLMOps.error("❌ [MistralXML:\(reqId)] Empty response from model.")
            throw GenerationError.emptyResponse(generator: "MistralXML")
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
