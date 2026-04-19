//
//  NativeStructuredGenerator.swift
//  Devgentic
//
//  Extracted during Phase 2 Modularization
//  Updated: Native API Integration (Loosened Prompts + Smart Plain Text Fallback)
//

import Foundation
import OSLog

private let logLLMOps = DGLogger(category: "LLMOps")

// MARK: - Strategy A: Native Tool Calling Generator (Cloud / Modern)

/// A cognitive strategy that utilizes the provider's native tool array mapping.
/// Relies on the LLMProvider's native interception bridge to format responses into LeanCognitiveStep.
struct NativeStructuredGenerator: CognitiveGenerator {
    let toolAdapter: ToolSchemaAdapter
    let dialectRules: String?
    
    init(toolAdapter: ToolSchemaAdapter = NativeJSONSchemaAdapter(), dialectRules: String? = nil) {
        self.toolAdapter = toolAdapter
        self.dialectRules = dialectRules
    }

    func compileMessages(from context: SemanticContext) -> [[String: String]] {
        return buildStandardMessages(context: context, dialectRules: dialectRules, isNativeFlow: true, layerConfig: context.promptLayerConfig)
    }

    func promptTrigger(for iteration: Int) -> String {
        let base = iteration == 1
            ? "Analyze the task and working memory, then decide your next action."
            : "New observations have been recorded in working memory. Decide your next action."
        return base + " If you need to take an action, use one of the provided tools."
    }
    
    func generateCognitiveStep(model: any LLMProvider, context: SemanticContext, iteration: Int) async throws -> ModernCognitiveStep {
        let reqId = UUID().uuidString.prefix(8)
        logLLMOps.info("⚡️ [Native:\(reqId)] Start Generation - Iteration: \(iteration)")

        var executionMessages = compileMessages(from: context)
        
        executionMessages.append(["role": "user", "content": promptTrigger(for: iteration)])

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
