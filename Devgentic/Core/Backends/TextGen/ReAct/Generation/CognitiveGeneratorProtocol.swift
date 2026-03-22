//
//  CognitiveGeneratorProtocol.swift
//  Devgentic
//
//  Created by Raj Singh on 26/02/26.
//


import Foundation

/// Defines a strategy for generating structured cognitive steps from an LLM.
/// Strategies operate on the SemanticContext payload and compile provider-specific message arrays.
protocol CognitiveGenerator: Sendable {
    /// The adapter responsible for formatting tools for this specific generator.
    var toolAdapter: ToolSchemaAdapter { get }
    
    /// Compiles the raw execution state into a provider-specific message array.
    func compileMessages(from context: SemanticContext) -> [[String: String]]
    
    /// Executes the cognitive step and returns a structured response.
    func generateCognitiveStep(
        model: any LLMProvider,
        context: SemanticContext,
        iteration: Int
    ) async throws -> ModernCognitiveStep

    /// Multimodal message compilation. Default wraps legacy compileMessages().
    func compileProviderMessages(from context: SemanticContext) -> [ProviderMessage]
}

extension CognitiveGenerator {
    func compileProviderMessages(from context: SemanticContext) -> [ProviderMessage] {
        compileMessages(from: context).map { ProviderMessage(legacy: $0) }
    }
}

// MARK: - Default Builder Extension

extension CognitiveGenerator {
    
    /// Constructs the standard "Sandwich" prompt with injected data from the SemanticContext.
    func buildStandardMessages(
        context: SemanticContext,
        dialectRules: String? = nil,
        isNativeFlow: Bool = false
    ) -> [[String: String]] {
        
        // Tier 1: System Rules & Static RAG
        var systemContent = """
        <system_instructions>
        \(context.instructions ?? "You are a helpful AI assistant.")
        </system_instructions>
        
        <semantic_context>
        \(context.longTermMemory.getStaticGrounding())
        - OS: \(context.environmentFacts.osVersion)
        - Shell: \(context.environmentFacts.shellType)
        - User: \(context.environmentFacts.userName)
        - Date: \(context.environmentFacts.currentDate)
        </semantic_context>
        """
        
        // Inject the specific Dialect Rules (Execution Contract) if not native
        if !isNativeFlow, let rules = dialectRules {
            let toolsMarkdown = context.availableTools.map { $0.toMarkdownDefinition() }.joined(separator: "\n\n")
            systemContent += """
            \n
            <execution_contract>
            \(rules)
            </execution_contract>
            
            <available_tools>
            \(toolsMarkdown)
            </available_tools>
            """
        } else if isNativeFlow {
            // Native models still need a strict capability fence
            systemContent += "\n<capability_fence>\nYou have \(context.availableTools.count) native tools. Do not hallucinate capabilities outside this list.</capability_fence>"
        }
        
        // Append Dynamic Guardrails
        if !context.negativeConstraints.isEmpty {
            systemContent += "\n<negative_constraints>\nFAILED PATHS:\n" + context.negativeConstraints.map { "- \($0)" }.joined(separator: "\n") + "\n</negative_constraints>"
        }
        if !context.hallucinatedTools.isEmpty {
            systemContent += "\n<hallucinated_tools>\nDO NOT USE:\n" + context.hallucinatedTools.map { "- \($0)" }.joined(separator: "\n") + "\n</hallucinated_tools>"
        }
        
        var messages: [[String: String]] = [["role": "system", "content": systemContent]]
        
        // Tier 2: Episodic Memory (XML with executable tool recipes)
        if let history = context.recentHistory, !history.isEmpty {
            messages.append(["role": "user", "content": history])
        }
        
        // Tier 3: Active Scratchpad & Objective
        var activeContext = """
        <current_objective>
        ### User
        \(context.originalQuery)
        """
        
        if let clarification = context.latestClarification {
            activeContext += "\n### Clarification\n\(clarification)"
        }
        
        activeContext += """
        
        </current_objective>
        
        <working_memory>
        \(context.compiledScratchpad)
        </working_memory>
        """
        
        messages.append(["role": "user", "content": activeContext])
        return messages
    }
}
