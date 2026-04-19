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
    let toolAdapter: ToolSchemaAdapter

    let dialectRules: String? = """
    RESPONSE FORMAT:
    You MUST respond using the following structured format EXACTLY:

    Thought: [Your reasoning about what to do next]
    Action: [The exact tool name from the TOOLS list, or "None" if done]
    Action Input: [A valid JSON object with the tool's arguments]

    TERMINATION:
    If the task is complete or you need to reply to the user, use:
    Thought: [Your final reasoning]
    Action: None
    Final Answer: [Your response to the user]

    RULES:
    1. "Action" MUST be a tool name from the TOOLS list, or "None"/"Null".
    2. "Action Input" MUST be a valid JSON object.
    3. Do NOT use markdown code fences (```json). Output plain text only.
    4. NEVER invent tool names. If a tool is not in the TOOLS list, use Action: None.
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

        var executionMessages = compileMessages(from: context)

        executionMessages.append(["role": "user", "content": promptTrigger(for: iteration)])

        logLLMOps.debug("📤 [ReActMD:\(reqId)] Sending request...")
        let startTime = Date()

        let responseText = try await model.generate(messages: executionMessages, tools: nil, responseSchema: nil)

        let duration = Date().timeIntervalSince(startTime)
        logLLMOps.info("✅ [ReActMD:\(reqId)] Response received in \(String(format: "%.4f", duration))s")
        logLLMOps.debug("📄 [ReActMD:\(reqId)] Raw:\n\(responseText)")

        guard !responseText.isEmpty else {
            logLLMOps.error("❌ [ReActMD:\(reqId)] Empty response from model.")
            throw NSError(domain: "MarkdownStructuredGenerator", code: 422,
                          userInfo: [NSLocalizedDescriptionKey: "Empty response from model."])
        }

        let pipeline = CognitiveParsePipeline(
            expectedDialect: .reactMarkdown,
            modelId: model.modelName,
            iteration: iteration
        )
        return pipeline.parse(raw: responseText)
    }
}
