//
//  NativeStructuredGenerator.swift
//  Devgentic
//
//  Extracted during Phase 2 Modularization
//  Updated: Native API Integration (Loosened Prompts + Smart Plain Text Fallback)
//

import Foundation
import OSLog

private let logLLMOps = Logger(subsystem: Bundle.main.bundleIdentifier ?? "com.devgentic.app", category: "LLMOps")

// MARK: - Strategy A: Native Tool Calling Strategy (Cloud / Modern)

/// A cognitive strategy that utilizes the provider's native tool array mapping.
/// Relies on the LLMProvider's native interception bridge to format responses into LeanCognitiveStep.
struct NativeStructuredStrategy: CognitiveGenerator {
    let toolAdapter: ToolSchemaAdapter
    let dialectRules: String?
    
    init(toolAdapter: ToolSchemaAdapter = NativeJSONSchemaAdapter(), dialectRules: String? = nil) {
        self.toolAdapter = toolAdapter
        self.dialectRules = dialectRules
    }
    
    func compileMessages(from context: SemanticContext) -> [[String: String]] {
        return buildStandardMessages(context: context, dialectRules: dialectRules, isNativeFlow: true)
    }
    
    func generateCognitiveStep(model: any LLMProvider, context: SemanticContext, iteration: Int) async throws -> ModernCognitiveStep {
        let reqId = UUID().uuidString.prefix(8)
        logLLMOps.info("⚡️ [Native:\(reqId)] Start Generation - Iteration: \(iteration)")

        var executionMessages = compileMessages(from: context)
        
        // --- NATURAL PROMPT TRIGGER ---
        // We no longer force the model to output strict JSON markdown.
        // We let it act naturally and rely on the LLMProvider to intercept native tool_calls.
        // However, for local models (like Llama 3 Groq) to reliably trigger native tool outputs,
        // we append a stronger call-to-action to use the provided tool schema.
        let promptTrigger = (iteration == 1)
            ? "Begin ReAct loop. Analyze Active Memory. Decide your next step. If you need to take an action, you MUST use one of the provided tools using its exact function calling format."
            : "Review OBSERVATION. Update State. Decide your next step. If you need to take an action, you MUST use one of the provided tools using its exact function calling format."

        executionMessages.append(["role": "user", "content": promptTrigger])

        logLLMOps.debug("📤 [Native:\(reqId)] Sending request to model with native tool execution...")
        let startTime = Date()

        let nativeTools = toolAdapter.formatForNativeAPI(context.availableTools)
        
        // --- NATIVE PROVIDER PATH ---
        // Instead of asking for string text that might be JSON, we ask the provider to give us the step directly.
        let step = try await model.generateCognitiveStep(
            messages: executionMessages,
            tools: nativeTools
        )

        let duration = Date().timeIntervalSince(startTime)
        logLLMOps.info("✅ [Native:\(reqId)] Response received in \(String(format: "%.4f", duration))s")
        logLLMOps.debug("📄 [Native:\(reqId)] Step Resolved. \(step.toolCalls.count) tools requested.")

        return step
    }
}
