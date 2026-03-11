//
//  PromptedJsonModeGenerator.swift
//  Devgentic
//
//  Created by Raj Singh on 26/02/26.
//

import Foundation
import OSLog

private let logLLMOps = Logger(subsystem: Bundle.main.bundleIdentifier ?? "com.devgentic.app", category: "LLMOps")


// MARK: - Strategy C: Prompted JSON Mode (Ollama / Local / MLX)

/// A cognitive strategy tailored for local models using standard JSON mode or prompt-enforced text mode.
struct PromptedJsonModeStrategy: CognitiveGenerator {
    let toolAdapter: ToolSchemaAdapter
    
    init(toolAdapter: ToolSchemaAdapter = PromptedMarkdownAdapter()) {
        self.toolAdapter = toolAdapter
    }

    func compileMessages(from context: SemanticContext) -> [[String: String]] {
        let strictRules = """
        CRITICAL TERMINATION RULE:
        If you have fully answered the user's request OR cannot proceed, you MUST output:
        {
          "content": "I have found the information and am ready to respond.",
          "tool_name": null,
          "arguments": null
        }
        Do NOT output tool_name: null if you still need to execute an action.

        CRITICAL RULES:
        1. 'content' is a REQUIRED field. Do not omit it.
        2. Ensure STRICT JSON SYNTAX. Do not return conversational text outside the JSON object.
        3. Do NOT wrap the JSON in markdown fences. Output the raw {} object only.
        4. Always use double quotes for strings and keys.
        """
        
        var messages = buildStandardMessages(context: context, dialectRules: strictRules)
        messages.append(["role": "user", "content": "Reminder: Output ONLY valid JSON."])
        return messages
    }

    func generateCognitiveStep(model: any LLMProvider, context: SemanticContext, iteration: Int) async throws -> ModernCognitiveStep {
        let reqId = UUID().uuidString.prefix(8)
        logLLMOps.info("⚡️ [JsonMode:\(reqId)] Start Generation - Iteration: \(iteration)")

        var executionMessages = compileMessages(from: context)

        let promptTrigger = (iteration == 1)
            ? "Begin ReAct loop. Analyze Active Memory. Respond with a valid JSON object."
            : "Review OBSERVATION. Update State. Decide next step. Respond with a valid JSON object."

        let prompt = promptTrigger + "\n\n" + """
        Mandatory JSON Structure:
        {
          "content": "Thinking about the next step...",
          "tool_name": "ls",
          "arguments": { "path": "/" }
        }
        """

        executionMessages.append(["role": "user", "content": prompt])

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
            expectedDialect: .promptedFlatJSON,
            modelId: model.modelName,
            iteration: iteration
        )
        return pipeline.parse(raw: responseText)
    }
}
