//  JsonStructuredGenerator.swift
//  Devgentic
//
//  Created by Raj Singh on 26/02/26.
//

import Foundation
import OSLog

private let logLLMOps = DGLogger(category: "LLMOps")


// MARK: - Strategy C: JSON Structured (Ollama / Local / MLX)

/// A cognitive strategy tailored for local models using standard JSON mode or prompt-enforced text mode.
struct JsonStructuredGenerator: CognitiveGenerator {
    let toolAdapter: ToolSchemaAdapter
    let dialect: ModelDialect

    let dialectRules: String? = """
    CRITICAL TERMINATION RULE:
    When you have fully answered the user's request OR cannot proceed further, you MUST
    call the `final_answer` tool with your complete response in the `answer` field:
    {
      "content": "Composing the final response.",
      "tool_name": "final_answer",
      "arguments": { "answer": "Your complete response to the user as markdown." }
    }
    This is the ONLY way to end a task. Do NOT output conversational text outside the JSON,
    and do NOT use null `tool_name` or an empty response as a termination signal.

    CRITICAL RULES:
    1. 'content' is a REQUIRED field. Do not omit it.
    2. Ensure STRICT JSON SYNTAX. Do not return conversational text outside the JSON object.
    3. Do NOT wrap the JSON in markdown fences. Output the raw {} object only.
    4. Always use double quotes for strings and keys.
    """

    var promptWrapping: PromptWrapping { .markdown }

    init(toolAdapter: ToolSchemaAdapter = PromptedMarkdownAdapter(), dialect: ModelDialect = .heuristicJson) {
        self.toolAdapter = toolAdapter
        self.dialect = dialect
    }

    func compileMessages(from context: SemanticContext) -> [[String: String]] {
        return buildStandardMessages(context: context, dialectRules: dialectRules, layerConfig: context.promptLayerConfig, wrapping: .markdown)
    }

    func promptTrigger(for iteration: Int) -> String {
        let base = iteration == 1
            ? "Analyze the task and working memory, then decide your next action."
            : "New observations have been recorded in working memory. Decide your next action."

        return base + """


        IMPORTANT: You MUST respond with ONLY a valid JSON object. No markdown fences, no conversational text outside the JSON structure.

        Mandatory JSON Structure:
        {
          "content": "Thinking about the next step...",
          "tool_name": "ls",
          "arguments": { "path": "/" }
        }
        """
    }

    func generateCognitiveStep(model: any LLMProvider, context: SemanticContext, iteration: Int) async throws -> ModernCognitiveStep {
        let reqId = UUID().uuidString.prefix(8)
        logLLMOps.info("⚡️ [JsonMode:\(reqId)] Start Generation - Iteration: \(iteration)")

        var executionMessages = compileMessages(from: context)

        executionMessages.append(["role": "user", "content": promptTrigger(for: iteration)])

        logLLMOps.debug("📤 [JsonMode:\(reqId)] Sending request...")
        let startTime = Date()

        let responseText = try await model.generate(messages: executionMessages, tools: nil, responseSchema: "json")

        let duration = Date().timeIntervalSince(startTime)
        logLLMOps.info("✅ [JsonMode:\(reqId)] Response received in \(String(format: "%.4f", duration))s")
        logLLMOps.debug("📄 [JsonMode:\(reqId)] Raw LLM Response:\n\(responseText)")

        guard !responseText.isEmpty else {
            logLLMOps.error("❌ [JsonMode:\(reqId)] Empty response from model.")
            throw NSError(domain: "JsonMode", code: 422, userInfo: [NSLocalizedDescriptionKey: "Empty response from model."])
        }

        let pipeline = CognitiveParsePipeline(
            expectedDialect: dialect,
            modelId: model.modelName,
            iteration: iteration
        )
        return pipeline.parse(raw: responseText)
    }
}
