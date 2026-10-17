// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
//
//  MarkdownStructuredGenerator.swift
//  Devgentic
//
//  Step 2.2: Dialect-specific generator for the .reactMarkdown dialect.
//  Injects the classic Thought / Action / Action Input ReAct template.
//  Calls model.generate() (text mode) and delegates to ReActMarkdownParser.
//
//  Target: Models fine-tuned with ReAct-style prompting (e.g., Llama variants
//  with [available_tools] injection in their Go template).
//
//  Created by Raj Singh on 06/03/26.
//

import Foundation
import OSLog

private let logLLMOps = DGLogger(category: "LLMOps")

// MARK: - Strategy: Markdown Structured Generator

/// A cognitive strategy for models that follow the classic ReAct markdown format:
///   Thought: <reasoning>
///   Action: <tool_name>
///   Action Input: <json_args>
struct MarkdownStructuredGenerator: CognitiveGenerator {

    /// The one value this generator both declares and parses with.
    private static let dialect: ModelDialect = .reactMarkdown
    var expectedDialect: ModelDialect? { Self.dialect }
    let toolAdapter: ToolSchemaAdapter

    let dialectRules: String? = """
    RESPONSE FORMAT:
    You MUST respond using the following structured format EXACTLY:

    Thought: [Your reasoning about what to do next]
    Action: [The exact tool name from the TOOLS list]
    Action Input: [A valid JSON object with the tool's arguments]

    TERMINATION:
    To end the task, call the `final_answer` tool:
    Thought: [Your final reasoning]
    Action: final_answer
    Action Input: {"answer": "Your complete response to the user as markdown"}

    This is the ONLY way to terminate. Do NOT use "Action: None", "Final Answer:" on its
    own, or plain prose as a termination signal.

    RULES:
    1. "Action" MUST be a tool name from the TOOLS list (use `final_answer` to end).
    2. "Action Input" MUST be a valid JSON object.
    3. Do NOT use markdown code fences (```json). Output plain text only.
    4. NEVER invent tool names. Use only tools listed in TOOLS; use `final_answer` to end.
    5. One action per response only.
    """

    var promptWrapping: PromptWrapping { .markdown }

    init(toolAdapter: ToolSchemaAdapter = LegacyPromptAdapter()) {
        self.toolAdapter = toolAdapter
    }

    func compileMessages(from context: SemanticContext) -> [[String: String]] {
        return buildStandardMessages(context: context, dialectRules: dialectRules, layerConfig: context.promptLayerConfig, wrapping: .markdown)
    }

    func generateCognitiveStep(
        model: any LLMProvider,
        context: SemanticContext,
        iteration: Int
    ) async throws -> ModernCognitiveStep {
        let reqId = UUID().uuidString.prefix(8)
        logLLMOps.info("⚡️ [ReActMD:\(reqId)] Start Generation - Iteration: \(iteration)")

        logLLMOps.debug("📤 [ReActMD:\(reqId)] Sending request...")
        let startTime = Date()

        // Multimodal when the turn carries images (current-turn or prior-turn history),
        // byte-identical text path otherwise. Markdown renders tools as prompt text
        // (tools: nil), so the vision path loses no tool-calling.
        let responseText = try await generatePromptedResponse(model: model, context: context, iteration: iteration, responseSchema: nil, label: "ReActMD:\(reqId)")

        let duration = Date().timeIntervalSince(startTime)
        logLLMOps.info("✅ [ReActMD:\(reqId)] Response received in \(String(format: "%.4f", duration))s")
        logLLMOps.debug("📄 [ReActMD:\(reqId)] Raw:\n\(responseText)")

        guard !responseText.isEmpty else {
            logLLMOps.error("❌ [ReActMD:\(reqId)] Empty response from model.")
            throw GenerationError.emptyResponse(generator: "ReActMD")
        }

        let pipeline = CognitiveParsePipeline(
            expectedDialect: Self.dialect,
            modelId: model.modelName,
            iteration: iteration,
            knownToolNames: Set(context.availableTools.map(\.name)).union(context.runToolNames),
            registeredTools: context.availableTools
        )
        return pipeline.parse(raw: responseText)
    }
}
