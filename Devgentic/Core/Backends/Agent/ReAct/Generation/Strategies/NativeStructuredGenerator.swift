//
//  NativeStructuredGenerator.swift
//  Devgentic
//
//  Extracted during Phase 2 Modularization
//  Updated: Native API Integration (Loosened Prompts)
//

import Foundation
import OSLog

private let logLLMOps = Logger(subsystem: Bundle.main.bundleIdentifier ?? "com.devgentic.app", category: "LLMOps")

// MARK: - Strategy A: Native Tool Calling Strategy (Cloud / Modern)

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
        return buildStandardMessages(context: context, dialectRules: dialectRules)
    }
    
    func generate(model: any LLMProvider, context: SemanticContext, iteration: Int) async throws -> LeanCognitiveStep {
        let reqId = UUID().uuidString.prefix(8)
        logLLMOps.info("⚡️ [Native:\(reqId)] Start Generation - Iteration: \(iteration)")

        var executionMessages = compileMessages(from: context)
        
        // --- NATURAL PROMPT TRIGGER ---
        // We no longer force the model to output strict JSON markdown.
        // We let it act naturally and rely on the LLMProvider to intercept native tool_calls.
        let promptTrigger = (iteration == 1)
            ? "Begin ReAct loop. Analyze Active Memory. Decide your next step. If you need to take an action, use the provided tools."
            : "Review OBSERVATION. Update State. Decide your next step. If you need to take an action, use the provided tools."

        executionMessages.append(["role": "user", "content": promptTrigger])

        logLLMOps.debug("📤 [Native:\(reqId)] Sending request to model with native tool execution...")
        let startTime = Date()

        let nativeTools = toolAdapter.formatForNativeAPI(context.availableTools)
        
        // --- UNSHACKLED SCHEMA ---
        // Pass responseSchema as nil so the LLM freely uses its native tool_calls array
        // instead of trying to cram a JSON string into its content block.
        let responseText = try await model.generate(
            messages: executionMessages,
            tools: nativeTools,
            responseSchema: nil
        )

        let duration = Date().timeIntervalSince(startTime)
        logLLMOps.info("✅ [Native:\(reqId)] Response received in \(String(format: "%.4f", duration))s")
        logLLMOps.debug("📄 [Native:\(reqId)] Raw LLM Response (or Intercepted Bridge Payload):\n\(responseText)")

        guard let data = responseText.data(using: .utf8) else {
            logLLMOps.error("❌ [Native:\(reqId)] Failed to convert response text to data.")
            throw NSError(domain: "CognitiveStrategy", code: 422, userInfo: [NSLocalizedDescriptionKey: "Failed to convert response text to data."])
        }

        do {
            // The JSONDecoder will seamlessly parse the synthetic JSON string created by LLMProviders.swift
            let step = try JSONDecoder().decode(LeanCognitiveStep.self, from: data)
            logLLMOps.info("🎉 [Native:\(reqId)] Successfully decoded LeanCognitiveStep. Action: \(step.toolName ?? "None (Termination)")")
            return step
        } catch {
            logLLMOps.warning("⚠️ [Native:\(reqId)] Direct decode failed, trying shadow parser: \(error.localizedDescription)")
            // Falls back to the shared robust parser defined in PromptedJsonModeGenerator
            return try GeminiShadowSchema.parse(responseText)
        }
    }
}

