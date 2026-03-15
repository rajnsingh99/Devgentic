//
//  MistralXMLGenerator.swift
//  Devgentic
//
//  Step 2.2: Dialect-specific generator for the .mistralXML dialect.
//  Injects <tool_call> wrapping instructions with hybrid tags (<content>, <tool_name>, <arguments>).
//
//  Created by Raj Singh on 06/03/26.
//

import Foundation
import OSLog

private let logLLMOps = Logger(subsystem: Bundle.main.bundleIdentifier ?? "com.devgentic.app", category: "LLMOps")

// MARK: - Strategy: Mistral XML Generator

/// A cognitive strategy for Mistral-family models that wrap tool calls in
/// pseudo-XML boundaries (<tool_call>...</tool_call>).
struct MistralXMLGenerator: CognitiveGenerator {
    let toolAdapter: ToolSchemaAdapter

    private let dialectRules = """
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
    4. If the task is complete or you need to respond to the user, output your response in plain text WITHOUT any <tool_call> block.
    5. NEVER invent tool names. Use only tools from the TOOLS list.
    """

    init(toolAdapter: ToolSchemaAdapter = LegacyPromptAdapter()) {
        self.toolAdapter = toolAdapter
    }

    func compileMessages(from context: SemanticContext) -> [[String: String]] {
        return buildStandardMessages(context: context, dialectRules: dialectRules)
    }

    func generateCognitiveStep(
        model: any LLMProvider,
        context: SemanticContext,
        iteration: Int
    ) async throws -> ModernCognitiveStep {
        let reqId = UUID().uuidString.prefix(8)
        logLLMOps.info("⚡️ [MistralXML:\(reqId)] Start Generation - Iteration: \(iteration)")

        var executionMessages = compileMessages(from: context)

        let promptTrigger = (iteration == 1)
            ? "Begin ReAct loop. Analyze Active Memory. Use the <tool_call> XML format if you need to invoke a tool."
            : "Review OBSERVATION. Decide next step. Use the <tool_call> XML format if you need to invoke a tool."

        executionMessages.append(["role": "user", "content": promptTrigger])

        logLLMOps.debug("📤 [MistralXML:\(reqId)] Sending request...")
        let startTime = Date()

        let responseText = try await model.generate(messages: executionMessages, tools: nil, responseSchema: nil)

        let duration = Date().timeIntervalSince(startTime)
        logLLMOps.info("✅ [MistralXML:\(reqId)] Response received in \(String(format: "%.4f", duration))s")
        logLLMOps.debug("📄 [MistralXML:\(reqId)] Raw:\n\(responseText)")

        guard !responseText.isEmpty else {
            logLLMOps.error("❌ [MistralXML:\(reqId)] Empty response from model.")
            throw NSError(domain: "MistralXMLGenerator", code: 422,
                          userInfo: [NSLocalizedDescriptionKey: "Empty response from model."])
        }

        let pipeline = CognitiveParsePipeline(
            expectedDialect: .mistralXML,
            modelId: model.modelName,
            iteration: iteration
        )
        return pipeline.parse(raw: responseText)
    }
}
