//
//  MockCognitiveGenerator.swift
//  DevgenticTests
//
//  Pass-through cognitive generator for integration tests.
//  Skips prompt compilation and delegates directly to the LLMProvider,
//  which returns scripted ModernCognitiveStep responses.
//

import Foundation
@testable import devgentic

/// A generator that bypasses prompt compilation and passes through
/// to the mock provider's scripted responses.
struct MockCognitiveGenerator: CognitiveGenerator {

    let toolAdapter: ToolSchemaAdapter = NativeJSONSchemaAdapter()

    func compileMessages(from context: SemanticContext) -> [[String: String]] {
        // Include the scratchpad so integration tests can verify memory seeding
        // by inspecting the messages received by the mock provider.
        var content = context.originalQuery
        if context.compiledScratchpad != "No actions taken yet." {
            content += "\n\n<working_memory>\n\(context.compiledScratchpad)\n</working_memory>"
        }
        return [["role": "user", "content": content]]
    }

    func generateCognitiveStep(
        model: any LLMProvider,
        context: SemanticContext,
        iteration: Int
    ) async throws -> ModernCognitiveStep {
        // Pass through to the mock provider's scripted sequence.
        let messages = compileMessages(from: context)
        return try await model.generateCognitiveStep(messages: messages, tools: nil)
    }
}
