//
//  MLXNativeStructuredGenerator.swift
//  Devgentic
//
//  Created by Raj Singh on 04/03/26.
//

import Foundation
import OSLog

private let logLLMOps = Logger(subsystem: Bundle.main.bundleIdentifier ?? "com.devgentic.app", category: "LLMOps")

/// A specialized cognitive strategy specifically built for local MLX models that support native tools 
/// (like Llama-3-Groq-Tool-Use). 
/// Unlike `NativeStructuredGenerator`, this does NOT inject heavy ReAct system prompts or 
/// force a JSON response. It relies entirely on the model's native `applyChatTemplate` handling.
struct MLXNativeStructuredGenerator: CognitiveGenerator {
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
        logLLMOps.info("⚡️ [MLXNative:\(reqId)] Start Generation - Iteration: \(iteration)")

        let executionMessages = compileMessages(from: context)
        
        // --- ZERO PROMPT INJECTION ---
        // We DO NOT append arbitrary instructions like "Begin ReAct loop" or "Respond in JSON".
        // Fine-tuned local models (e.g. Llama 3 Groq) behave extremely strictly based on their
        // chat templates. We just provide the history, observation context, and tools.

        logLLMOps.debug("📤 [MLXNative:\(reqId)] Sending request to MLX model with native tool execution...")
        let startTime = Date()

        let nativeTools = toolAdapter.formatForNativeAPI(context.availableTools)
        
        let step = try await model.generateCognitiveStep(
            messages: executionMessages,
            tools: nativeTools
        )

        let duration = Date().timeIntervalSince(startTime)
        logLLMOps.info("✅ [MLXNative:\(reqId)] Response received in \(String(format: "%.4f", duration))s")
        logLLMOps.debug("📄 [MLXNative:\(reqId)] Mapped Tool Calls: \(step.toolCalls.count)")

        return step
    }
}
