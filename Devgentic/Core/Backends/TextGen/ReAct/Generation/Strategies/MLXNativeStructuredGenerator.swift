//
//  MLXNativeStructuredGenerator.swift
//  Devgentic
//
//  Created by Raj Singh on 04/03/26.
//

import Foundation
import OSLog

private let logLLMOps = DGLogger(category: "LLMOps")

/// A specialized cognitive strategy specifically built for local MLX models that support native tools 
/// (like Llama-3-Groq-Tool-Use). 
/// This version enforces a modern JSON schema via prompting and uses the heuristic parser
/// to handle parallel tool calls reliably.
struct MLXNativeStructuredGenerator: CognitiveGenerator {
    let toolAdapter: ToolSchemaAdapter

    let dialectRules: String? = """
    RESPONSE FORMAT:
    You MUST respond using the following structured JSON format:
    {
      "content": "Your reasoning about what to do next",
      "tool_calls": [
        { "name": "tool_name", "arguments": { "key": "value" } }
      ]
    }

    RULES:
    1. 'content' is REQUIRED and should contain your logical "Thought".
    2. 'tool_calls' is an array. You can call multiple tools if they are independent.
    3. To end a task, call the `final_answer` tool with your complete response in the
       `answer` argument. This is the ONLY way to terminate — do NOT return an empty
       `tool_calls` array or conversational prose as a termination signal.
    4. Ensure STRICT JSON syntax. No markdown fences.
    5. Use exact tool names from the TOOLS list.
    """
    
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
        return base + " Respond as a JSON object with your reasoning in 'content' and any tool calls in 'tool_calls'."
    }
    
    func generateCognitiveStep(model: any LLMProvider, context: SemanticContext, iteration: Int) async throws -> ModernCognitiveStep {
        let reqId = UUID().uuidString.prefix(8)
        logLLMOps.info("⚡️ [MLXModern:\(reqId)] Start Generation - Iteration: \(iteration)")

        var executionMessages = compileMessages(from: context)
        
        executionMessages.append(["role": "user", "content": promptTrigger(for: iteration)])

        logLLMOps.debug("📤 [MLXModern:\(reqId)] Sending request...")
        let startTime = Date()

        let responseText = try await model.generate(
            messages: executionMessages,
            tools: nil,
            responseSchema: "json"
        )

        let duration = Date().timeIntervalSince(startTime)
        logLLMOps.info("✅ [MLXModern:\(reqId)] Response received in \(String(format: "%.4f", duration))s")
        logLLMOps.debug("📄 [MLXModern:\(reqId)] Raw LLM Response:\n\(responseText)")

        guard !responseText.isEmpty else {
            logLLMOps.error("❌ [MLXModern:\(reqId)] Empty response from model.")
            throw NSError(domain: "MLXModern", code: 422, userInfo: [NSLocalizedDescriptionKey: "Empty response from model."])
        }

        let pipeline = CognitiveParsePipeline(
            expectedDialect: .heuristicJson,
            modelId: model.modelName,
            iteration: iteration,
            knownToolNames: Set(context.availableTools.map(\.name)),
            registeredTools: context.availableTools
        )
        return pipeline.parse(raw: responseText)
    }
}
