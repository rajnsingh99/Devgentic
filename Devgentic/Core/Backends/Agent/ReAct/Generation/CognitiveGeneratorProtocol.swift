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
}

// MARK: - Default Builder Extension

extension CognitiveGenerator {
    
    /// Constructs the standard "Sandwich" prompt with injected data from the SemanticContext.
    func buildStandardMessages(
        context: SemanticContext,
        dialectRules: String? = nil,
        isNativeFlow: Bool = false
    ) -> [[String: String]] {
        
        var systemBlocks: [String] = []
        
        // --- 1. System Persona ---
        if let instructions = context.instructions, !instructions.isEmpty {
            systemBlocks.append("# SYSTEM INSTRUCTIONS\n\(instructions)")
        }
        
        // --- 2. Environment Facts ---
        systemBlocks.append("# ENVIRONMENT FACTS\n- OS: \(context.environmentFacts.osVersion)\n- Shell: \(context.environmentFacts.shellType)\n- User: \(context.environmentFacts.userName)\n- Date: \(context.environmentFacts.currentDate)")
        
        // --- 3. Active & Recent Memory ---
        systemBlocks.append("""
        # TWIN-STORE MEMORY
        ## 🧠 ACTIVE MEMORY (RAM)
        This is your CURRENT brain state. Trust this over history. Review past COMPLETED episodes and their `finalOutcome` to understand what you have already achieved for the user.
        ```json
        \(context.compressedStateGraph)
        ```
        ## 📜 RECENT ACTIVITY (Disk Tail)
        \(context.recentHistory ?? "(No recent history)")
        """)
        
        // --- 4. Infrastructure Protocol ---
        var strategyBlock = """
        # INFRASTRUCTURE PROTOCOL
        ## LIFECYCLE
        1. **RE-ACT LOOP**: You operate in a `Think -> Act -> Observe` sequence. 
        2. **MEMORY**: Review # ACTIVE MEMORY frequently to distinguish what has been done from what is remaining.
        
        ## EXECUTION RULES
        1. **TASK COMPLETION**: To finalize the request or respond to the user, \(isNativeFlow ? "simply provide your final answer in plain text without any tool calls." : "you MUST return `{\"tool_name\": null}`.")
        2. **COMMUNICATION**: To request information from the user, use the `ask_user` tool.
        3. **FENCE**: Operate strictly within # ENVIRONMENT and # TOOLS. Do not assume or hallucinate external capabilities.
        """
        
        if !context.negativeConstraints.isEmpty {
            strategyBlock += "\n## 🚫 NEGATIVE CONSTRAINTS (GHOST PROTOCOL)\nFAILED PATHS:\n" + context.negativeConstraints.map { "- \($0)" }.joined(separator: "\n")
        }
        
        if !context.hallucinatedTools.isEmpty {
            strategyBlock += "\n## ⛔ HALLUCINATED TOOLS (DO NOT USE)\nYou previously attempted these tools which DO NOT EXIST:\n" + context.hallucinatedTools.sorted().map { "- `\($0)`" }.joined(separator: "\n")
        }
        
        systemBlocks.append(strategyBlock)
        
        // --- 5. Context & Capabilities ---
        var executionContext = "# EXECUTION CONTEXT\n## ORIGINAL USER REQUEST\n\"\(context.originalQuery)\"\n\n"
        
        if let clarification = context.latestClarification {
            executionContext += "## 💡 LATEST USER CLARIFICATION\nThe context of the last interaction:\n\(clarification)\nUse this to guide your next action.\n\n"
        }
        
        let toolString = toolAdapter.formatForSystemPrompt(context.availableTools)
        let toolNames = context.availableTools.map(\.name).joined(separator: ", ")
        
        executionContext += "## TOOLS (\(context.availableTools.count) available)\n\(toolString)\n\n"
        executionContext += "## ⚠️ CAPABILITY FENCE\nYou have EXACTLY \(context.availableTools.count) tools: \(toolNames).\nThese are the ONLY tools that exist. Do NOT invent, guess, or hallucinate tool names.\nIf the user's request requires a capability not covered by these tools, \(isNativeFlow ? "explain to the user what is missing." : "return tool_name: null explaining what is missing.") Do NOT ask the user to run commands themselves."
        
        systemBlocks.append(executionContext)
        
        // --- 6. Dialect & Syntax Rules ---
        if let rules = dialectRules {
            systemBlocks.append("# SYNTAX RULES\n\(rules)")
        }
        
        let systemPrompt = systemBlocks.joined(separator: "\n\n")
        
        var messages: [[String: String]] = [
            ["role": "system", "content": systemPrompt],
            ["role": "user", "content": context.originalQuery]
        ]
        
        // --- 7. Multi-Turn History (Observations) ---
        // Instead of shoving historical tool outputs into the system prompt, we explicitly recreate
        // the past multi-turn sequence (assistant -> tool result) so the LLM doesn't forget past actions.
        if !context.activeObservations.isEmpty {
            let maxContextCharacters = 40_000
            var currentLength = systemPrompt.count + context.originalQuery.count
            var hasTruncated = false
            
            for obs in context.activeObservations {
                // Determine parameter string safely (fallback if AnyCodable unpacking fails based on specific wrapper library used)
                let dict = obs.metadata?.compactMapValues { String(describing: $0) } ?? [:]
                let params = dict["tool_params"] ?? "{}"
                
                // Simulate the LLM invoking the tool
                messages.append([
                    "role": "assistant",
                    "content": "I executed the tool `\(obs.toolName)` with parameters: \(params)"
                ])
                
                // Simulate the observation returned to the LLM
                var resultText = ""
                
                if obs.isRequired {
                    if let heavy = obs.heavyContent {
                        if !hasTruncated && (currentLength + heavy.count > maxContextCharacters) {
                            hasTruncated = true
                            resultText = "\(obs.shortObservation)\n\n[SYSTEM ALERT: Maximum context window reached. Remaining hydrated data was truncated.]"
                        } else if !hasTruncated {
                            resultText = "\(obs.shortObservation)\n\(heavy)"
                        } else {
                            resultText = obs.shortObservation
                        }
                    } else {
                        resultText = obs.shortObservation
                    }
                } else {
                    resultText = obs.shortObservation
                }
                
                let toolMsg = "OBSERVATION from `\(obs.toolName)`:\n\(resultText)"
                messages.append([
                    "role": "user",
                    "content": toolMsg
                ])
                
                currentLength += toolMsg.count
            }
        }
        
        return messages
    }
}
