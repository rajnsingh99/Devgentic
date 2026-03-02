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
    func generate(
        model: any LLMProvider,
        context: SemanticContext,
        iteration: Int
    ) async throws -> LeanCognitiveStep
}

// MARK: - Default Builder Extension

extension CognitiveGenerator {
    
    /// Constructs the standard "Sandwich" prompt with injected data from the SemanticContext.
    func buildStandardMessages(
        context: SemanticContext,
        dialectRules: String? = nil
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
        
        // --- 4. Cognitive Mechanics & Guardrails ---
        var strategyBlock = """
        # COGNITIVE STRATEGY & MECHANICS
        ## PROTOCOL
        1. You operate in a Think -> Act -> Observe loop.
        2. Analyze Active Memory before deciding your next move.
        3. If a path failed previously (Ghost Protocol), do NOT retry it.
        4. If a tool fails, **STOP** and reflect on the error before proceeding.
        5. **TASK COMPLETION**: If the goal is met or you need to reply to the user, you MUST output `"tool_name": null`. Do NOT hallucinate tools like 'none' or 'inform'.
        6. **CLARIFICATION**: If you need information from the user, use the `ask_user` tool: `{"tool_name": "ask_user", "arguments": {"question": "Your question here"}}`. Do NOT invent tools like 'inform' or 'respond'.
        7. **GRACEFUL DEGRADATION**: If the user's request requires a tool that is not available, do NOT loop. Immediately return tool_name: null explaining which capability is missing.
        8. **UNSUPPORTED FORMATS**: If a tool fails due to an unsupported format (e.g., trying to read a binary `.docx` file), do NOT ask the user for workarounds. Output `tool_name: null` immediately explaining the limitation.
        9. **ANTI-HALLUCINATION (ARCHIVED MEMORY)**: Do NOT guess, assume, or hallucinate the details of past events. If the user refers to an older conversation turn found in the [ARCHIVED MEMORY POINTERS], you MUST use the `conversation_history_tool` to retrieve the exact text before generating your final answer.
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
        executionContext += "## ⚠️ CAPABILITY FENCE\nYou have EXACTLY \(context.availableTools.count) tools: \(toolNames).\nThese are the ONLY tools that exist. Do NOT invent, guess, or hallucinate tool names.\nIf the user's request requires a capability not covered by these tools, return tool_name: null explaining what is missing. Do NOT ask the user to run commands themselves."
        
        if !context.activeObservations.isEmpty {
            executionContext += "\n\n## SCRATCHPAD\n"
            let maxContextCharacters = 40_000
            var currentLength = executionContext.count
            var hasTruncated = false
            
            for obs in context.activeObservations {
                if obs.isRequired {
                    if let heavy = obs.heavyContent {
                        if !hasTruncated && (currentLength + heavy.count > maxContextCharacters) {
                            hasTruncated = true
                            let warning = "\(obs.shortObservation)\n\n[SYSTEM ALERT: Maximum context window reached. Remaining hydrated data was truncated.]\n\n"
                            executionContext += warning
                            currentLength += warning.count
                        } else if !hasTruncated {
                            let block = "\(obs.shortObservation)\n\(heavy)\n\n"
                            executionContext += block
                            currentLength += block.count
                        } else {
                            let block = "\(obs.shortObservation)\n\n"
                            executionContext += block
                            currentLength += block.count
                        }
                    } else {
                        let block = "\(obs.shortObservation)\n\n"
                        executionContext += block
                        currentLength += block.count
                    }
                } else {
                    let block = "\(obs.shortObservation)\n\n"
                    executionContext += block
                    currentLength += block.count
                }
            }
        }
        
        systemBlocks.append(executionContext)
        
        // --- 6. Dialect & Syntax Rules ---
        if let rules = dialectRules {
            systemBlocks.append("# SYNTAX RULES\n\(rules)")
        }
        
        let systemPrompt = systemBlocks.joined(separator: "\n\n")
        
        return [
            ["role": "system", "content": systemPrompt],
            ["role": "user", "content": context.originalQuery]
        ]
    }
}
