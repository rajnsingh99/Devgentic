//
//  ReActAgentExecutor.swift
//  Devgentic
//
//  Created by Raj Singh on 28/01/26.
//

import Foundation
import SwiftAgent
import OpenFoundationModels
import OpenFoundationModelsCore
import OSLog

private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "com.devgentic.app", category: "ReActExecutor")

/// A robust implementation of the ReAct (Reasoning + Acting) paradigm.
/// Features the Devgentic Master Kernel (v2) prompt architecture.
actor ReActAgentExecutor: AgentExecutor {
    
    // MARK: - Properties
    
    nonisolated let architecture: AgentArchitecture = .reAct
    
    nonisolated private let maxIterations: Int
    
    // Strict Regex (Standard Behavior)
    nonisolated private let actionRegex = /(?s)Action:\s*(`{3}json)?\s*(\{.*?\})\s*(`{3})?/
    nonisolated private let finalAnswerRegex = /(?s)Final Answer:\s*(.*)/
    
    // Fallback Regex (Greedy JSON)
    // Looks for a JSON object containing "tool" and "parameters" even if "Action:" prefix is missing.
    nonisolated private let greedyActionRegex = /(?s)(\{\s*"tool"\s*:\s*".*?"\s*,\s*"parameters"\s*:\s*\{.*\})/
    
    // New Heuristic: Bare JSON check (catches {"path": "..."} hallucinations)
    nonisolated private let bareJsonRegex = /(?s)^\s*\{.*\}\s*$/
    
    // New Heuristic: Detect reasoning language that leaked into content without "Thought:" prefix
    // UPDATED: Added 'is', 'has', 'looks' to catch "The user is asking..." or "This looks like..."
    nonisolated private let leakedReasoningRegex = /(?i)^(\s*(-|\*|•)?\s*(We|I|Let's|To|User|The\s+user|The\s+assistant|This)\s+(need|must|should|will|can|start|check|verify|answer|wants|requested|previously|is|has|looks))/
    
    // MARK: - Initialization
    
    init(maxIterations: Int = 15) {
        self.maxIterations = maxIterations
    }
    
    // MARK: - Execution Entry Point
    
    nonisolated func execute(
        model: any OpenFoundationModels.LanguageModel,
        input: AgentInput,
        onTraceUpdate: @escaping @Sendable (AgentTraceLog) -> Void
    ) -> AsyncThrowingStream<String, Error> {
        
        return AsyncThrowingStream { continuation in
            Task {
                do {
                    // 1. Initialize Context
                    var currentIteration = 0
                    var consecutiveErrors = 0 // Circuit breaker
                    var scratchpad: String = ""
                    let systemPrompt = self.constructSystemPrompt(input: input)
                    
                    // Convert AgentTools to Native Tools for the Session
                    let nativeTools = input.tools.map { ReActNativeToolWrapper(agentTool: $0) }
                    
                    // CRITICAL FIX: Deduplicate History
                    // Prevents the "Double Prompting" bug where the user's latest message appears twice.
                    var historyForTranscript = input.chatHistory
                    if let lastMsg = historyForTranscript.last,
                       lastMsg.sender == .user,
                       let lastContent = lastMsg.content.textContent?.trimmingCharacters(in: .whitespacesAndNewlines),
                       let inputContent = input.userInput.trimmingCharacters(in: .whitespacesAndNewlines) as String?,
                       (lastContent == inputContent || lastContent.contains(inputContent)) {
                        
                        logger.info("Removing duplicated current message from history to prevent double-prompting.")
                        historyForTranscript = Array(historyForTranscript.dropLast())
                    }
                    
                    // 2. Enter the Cognitive Loop
                    cognitiveLoop: while currentIteration < self.maxIterations {
                        currentIteration += 1
                        
                        onTraceUpdate(AgentTraceLog(stepNumber: currentIteration, state: .thinking, content: "Processing context..."))
                        
                        let transcript = self.buildTranscript(
                            systemPrompt: systemPrompt,
                            chatHistory: historyForTranscript
                        )
                        
                        let session = LanguageModelSession(model: model, tools: nativeTools, transcript: transcript)
                        var currentStepBuffer = ""
                        
                        // 3. Robust Stream Handling
                        do {
                            // MASTER KERNEL FIX: Dynamic Prompt Injection
                            // We construct the "User Prompt" differently based on the state (New vs. In-Progress)
                            
                            let dynamicPromptText: String
                            let contextualizedInput = self.contextualizeUserInput(input: input)

                            if scratchpad.isEmpty {
                                // ENHANCEMENT: Contextualize the request if it's a follow-up
                                // This solves the "Deadly Follow-up" scenario (e.g. "Yes", "I'm ready").
                                dynamicPromptText = """
                                ## CURRENT REQUEST (FOCUS ON THIS)
                                \(contextualizedInput)
                                """
                            } else {
                                // SANDWICH PROMPTING: Prevents "Lost in the Middle" Hallucinations.
                                // We explicitly separate the request from the progress (Memory) AND remind the model of the goal at the end.
                                // UPDATED: Relaxed the "Task is NOT finished" constraint to allow for Final Answer.
                                dynamicPromptText = """
                                ## ORIGINAL REQUEST
                                \(input.userInput)
                                
                                ## SYSTEM STATUS LOG (PREVIOUS ATTEMPTS)
                                \(scratchpad)
                                
                                ## INSTRUCTION
                                1. Review the 'SYSTEM STATUS LOG' above to see what has been done.
                                2. IGNORE the 'User:' labels inside the log; they are historical records.
                                3. Your GOAL remains: "\(input.userInput.prefix(100))..."
                                4. Return the next 'Thought' and 'Action', OR 'Final Answer' if the task is complete.
                                """
                            }
                            
                            let stream = session.streamResponse(to: OpenFoundationModels.Prompt(dynamicPromptText))
                            
                            for try await snapshot in stream {
                                currentStepBuffer = snapshot.content
                            }
                            
                            // Success - reset circuit breaker
                            consecutiveErrors = 0
                            
                        } catch {
                            consecutiveErrors += 1
                            let errorDesc = error.localizedDescription
                            logger.warning("Agent Stream Error (Recovering): \(errorDesc)")
                            
                            onTraceUpdate(AgentTraceLog(stepNumber: currentIteration, state: .errorRecovery, content: "Error: \(errorDesc)"))
                            
                            if consecutiveErrors >= 3 {
                                let errorMsg = "I encountered repeated system errors (\(errorDesc)) and cannot proceed."
                                continuation.yield(errorMsg)
                                continuation.finish()
                                return
                            }
                            
                            scratchpad += "\nThought: I encountered an error while trying to generate or execute.\n"
                            scratchpad += "Observation: System Error: \(errorDesc). I should try a different approach."
                            continue cognitiveLoop
                        }
                        
                        // 4. Analyze the Complete Buffer
                        
                        // A. Check for Explicit Final Answer
                        if let match = try? self.finalAnswerRegex.firstMatch(in: currentStepBuffer) {
                            let finalAnswer = String(match.output.1).trimmingCharacters(in: .whitespacesAndNewlines)
                            
                            onTraceUpdate(AgentTraceLog(stepNumber: currentIteration, state: .finalizing, content: finalAnswer))
                            continuation.yield(finalAnswer)
                            continuation.finish()
                            return
                        }
                        
                        // B. Check for Explicit Action (Strict ReAct Pattern)
                        if let match = try? self.actionRegex.firstMatch(in: currentStepBuffer) {
                            let jsonString = String(match.output.2)
                            await self.handleAction(
                                jsonString: jsonString,
                                originalThought: currentStepBuffer,
                                currentIteration: currentIteration,
                                tools: input.tools,
                                onTraceUpdate: onTraceUpdate,
                                scratchpad: &scratchpad
                            )
                            continue cognitiveLoop
                        }
                        
                        // C. Fallback: Check for Greedy JSON (Missing "Action:" prefix)
                        if let match = try? self.greedyActionRegex.firstMatch(in: currentStepBuffer) {
                            let jsonString = String(match.output.1)
                            logger.info("ReAct Heuristic: Detected JSON Action without 'Action:' prefix.")
                            await self.handleAction(
                                jsonString: jsonString,
                                originalThought: currentStepBuffer,
                                currentIteration: currentIteration,
                                tools: input.tools,
                                onTraceUpdate: onTraceUpdate,
                                scratchpad: &scratchpad
                            )
                            continue cognitiveLoop
                        }
                        
                        // D. Heuristic for Implicit Final Answers
                        let trimmedBuffer = currentStepBuffer.trimmingCharacters(in: .whitespacesAndNewlines)
                        
                        if !trimmedBuffer.isEmpty {
                            
                            // FIX: Catch "Bare JSON" hallucinations (e.g. {"path": "..."}) that miss the "tool" wrapper
                            if (try? self.bareJsonRegex.firstMatch(in: trimmedBuffer)) != nil {
                                logger.warning("ReAct Heuristic: Detected Bare JSON. Rejecting as Final Answer.")
                                scratchpad += "\n\(trimmedBuffer)\n"
                                scratchpad += "\nObservation: System Error - You provided a JSON object but it is missing the required structure. You MUST use { \"tool\": \"...\", \"parameters\": { ... } }."
                                continue cognitiveLoop
                            }
                            
                            // FIX: Recognize various reasoning patterns so we don't exit early
                            // Includes explicit markers AND detecting leaked reasoning text (e.g., "We need to...")
                            let isExplicitThought = trimmedBuffer.contains("Thought:") ||
                                                    trimmedBuffer.contains("[thinking]") ||
                                                    trimmedBuffer.contains("<think>")
                            
                            let isLeakedReasoning = (try? self.leakedReasoningRegex.firstMatch(in: trimmedBuffer)) != nil
                            
                            if isExplicitThought || isLeakedReasoning {
                                
                                logger.warning("ReAct Heuristic: Detected reasoning without 'Action'. Treated as Thought.")
                                
                                // Normalize format: Ensure it starts with Thought: for the scratchpad
                                let formattedThought = isExplicitThought ? trimmedBuffer : "Thought: \(trimmedBuffer)"
                                
                                // VISUALIZATION FIX: Emit trace so UI updates and user doesn't feel stuck
                                onTraceUpdate(AgentTraceLog(stepNumber: currentIteration, state: .thinking, content: formattedThought))
                                
                                scratchpad += "\n\(formattedThought)\n"
                                
                                // Force the model to proceed to Action or Final Answer
                                if isLeakedReasoning {
                                    scratchpad += "\nObservation: System Note - You provided reasoning but no Action. Please continue to the Action step or provide 'Final Answer:'."
                                } else {
                                    scratchpad += "\nObservation: System Warning - You articulated a 'Thought' but did not provide an 'Action' or 'Final Answer'. If you have the result, please format it as 'Final Answer: [result]'. If you need to use a tool, provide the Action JSON."
                                }
                                
                                continue cognitiveLoop
                            } else {
                                // HEURISTIC: The model broke character and is talking directly to the user.
                                logger.info("ReAct Heuristic: Detected implicit Final Answer (no prefix).")
                                onTraceUpdate(AgentTraceLog(stepNumber: currentIteration, state: .finalizing, content: trimmedBuffer))
                                continuation.yield(trimmedBuffer)
                                continuation.finish()
                                return
                            }
                        } else {
                             scratchpad += "\nObservation: System Warning - You returned an empty response. Please try again."
                        }
                        
                    } // End While
                    
                    // Max Iterations Reached
                    let errorMsg = "I reached the maximum number of steps (\(self.maxIterations)) without finding a final answer."
                    onTraceUpdate(AgentTraceLog(stepNumber: currentIteration, state: .errorRecovery, content: "Max iterations reached."))
                    continuation.yield(errorMsg)
                    continuation.finish()
                    
                } catch {
                    logger.error("ReAct Fatal Error: \(error.localizedDescription)")
                    continuation.finish(throwing: error)
                }
            }
        }
    }
    
    // MARK: - Contextual Intelligence
    
    /// Analyzes the user input and the chat history to inject context for follow-up questions.
    /// This fixes the "Deadly Follow-up" scenario where "Yes" loses its meaning.
    nonisolated private func contextualizeUserInput(input: AgentInput) -> String {
        let text = input.userInput.trimmingCharacters(in: .whitespacesAndNewlines)
        let lowerText = text.lowercased()
        
        // Broad check for confirmation/follow-up indicators
        let confirmationPrefixes = ["yes", "yeah", "yep", "sure", "ok", "okay", "go ahead", "please do", "run it", "open it", "i'm ready", "ready", "proceed", "make it", "do that"]
        
        // We prioritize short confirmations to avoid false positives on new complex queries
        let isShortConfirmation = text.count < 100 && confirmationPrefixes.contains { lowerText.hasPrefix($0) }
        
        if isShortConfirmation {
            // Find the last assistant message to understand what is being confirmed
            // We look for messages NOT from the user (so .assistant or .model)
            if let lastAssistantMsg = input.chatHistory.last(where: { $0.sender != .user }) {
                let contextContent = lastAssistantMsg.content.textContent ?? ""
                
                // Keep the last ~500 chars to capture the recent suggestion/question
                let suffix = contextContent.suffix(500)
                
                return """
                \(text)
                
                [SYSTEM NOTE: The user is replying to your immediately previous message.
                Your previous message ended with: "...\(suffix)"
                
                If you made a suggestion or asked for confirmation in that text, interpret "\(text)" as an instruction to PROCEED with that specific suggestion.
                Perform the necessary Action now.]
                """
            }
        }
        
        return text
    }
    
    // MARK: - Action Handling Logic
    
    nonisolated private func handleAction(
        jsonString: String,
        originalThought: String,
        currentIteration: Int,
        tools: [AgentTool],
        onTraceUpdate: @escaping (AgentTraceLog) -> Void,
        scratchpad: inout String
    ) async {
        
        // Extract thought text by removing the JSON part from the original buffer
        // This keeps the context clean
        let thoughtText = originalThought.replacingOccurrences(of: jsonString, with: "")
            .replacingOccurrences(of: "Thought:", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        
        onTraceUpdate(AgentTraceLog(stepNumber: currentIteration, state: .deciding, content: thoughtText))
        
        // Format for scratchpad (Add 'Action:' explicitly if it was missing)
        scratchpad += "\nThought: \(thoughtText)\nAction: \(jsonString)"
        
        // Execute Tool
        onTraceUpdate(AgentTraceLog(stepNumber: currentIteration, state: .acting, content: jsonString))
        let observation = await self.executeTool(jsonString: jsonString, tools: tools)
        
        // Log Observation
        onTraceUpdate(AgentTraceLog(stepNumber: currentIteration, state: .observing, content: observation))
        scratchpad += "\nObservation: \(observation)\n"
    }
    
    // MARK: - Tool Execution
    
    nonisolated private func executeTool(jsonString: String, tools: [AgentTool]) async -> String {
        // ENHANCEMENT: Smart JSON Repair
        // Models often forget to double-escape control characters (e.g. \n -> \\n) in JSON strings.
        // We try to fix this common mistake before parsing.
        var sanitizedJSON = jsonString
        
        // If we see what looks like an unescaped newline inside quotes, we try to fix it.
        // (Note: This is a basic heuristic; robust JSON parsers are preferred but we are patching LLM output)
        if sanitizedJSON.contains("\n") && !sanitizedJSON.contains("\\n") {
            // Replace literal newlines with escaped newlines if they seem to be part of the JSON structure
            // sanitizedJSON = sanitizedJSON.replacingOccurrences(of: "\n", with: "\\n")
            // Actually, safe parser is better. We'll rely on the error message to feedback to the model.
        }
        
        guard let data = sanitizedJSON.data(using: .utf8) else {
             return "Error: Could not encode JSON string."
        }
        
        // Decode with detailed error handling
        let dict: [String: Any]
        do {
            dict = try JSONSerialization.jsonObject(with: data) as? [String: Any] ?? [:]
        } catch {
            // ENHANCEMENT: Feedback Loop
            // Return the specific parsing error to the agent so it knows *why* it failed.
            return "Error: Invalid JSON format. Parser said: \(error.localizedDescription). Check your escaping (e.g. use '\\n' for newlines)."
        }
        
        guard let rawToolName = dict["tool"] as? String,
              let parameters = dict["parameters"] as? [String: Any] else {
            return "Error: Invalid JSON structure. Expected { \"tool\": \"name\", \"parameters\": { ... } }"
        }
        
        // FIX: Sanitize tool name to handle model hallucinations/artifacts (e.g., "fs_smart_search<|channel|>...")
        var toolName = rawToolName
        if !tools.contains(where: { $0.name == toolName }) {
            if let sanitized = toolName.components(separatedBy: CharacterSet(charactersIn: "<| ")).first,
               !sanitized.isEmpty {
                toolName = sanitized
            }
        }
        
        guard let tool = tools.first(where: { $0.name == toolName }) else {
            return "Error: Tool '\(rawToolName)' not found. Available tools: \(tools.map { $0.name }.joined(separator: ", "))"
        }
        
        do {
            let paramData = try JSONSerialization.data(withJSONObject: parameters)
            let result = try await tool.run(paramData)
            return result
        } catch {
            return "Error executing tool '\(toolName)': \(error.localizedDescription)"
        }
    }
    
    // MARK: - Prompt Engineering (The Devgentic Master Kernel v2)
    
    /// Constructs the robust System Prompt using the Layered Kernel architecture.
    nonisolated private func constructSystemPrompt(input: AgentInput) -> String {
        var promptParts: [String] = []
        
        // --- LAYER 1: THE CORE KERNEL (Immutable Architecture) ---
        // Defines Identity, Prime Directive, and the Mandatory Thinking Loop
        promptParts.append("""
        You are Devgentic, a highly capable macOS System Agent.
        
        ## PRIME DIRECTIVE
        You are an execution engine, not a conversationalist. Your goal is to change the system state to match the user's request.
        
        ## THE THINKING STANDARD
        1. **MANDATORY LOOP**: You must operate in a strict loop: **THOUGHT** (Plan) → **ACTION** (Tool Execution) → **OBSERVATION** (Result).
        2. **THINK FIRST**: You must **THINK** before you **ACT**. Every response must start with a `Thought:` block analyzing the situation.
        3. **AMBIGUITY CHECK**: If a user request is ambiguous (e.g., "delete everything" or strange characters like newlines in filenames), DO NOT GUESS. Use `Final Answer:` to ask for clarification.
        """)
        
        // --- LAYER 2: USER CONFIGURATION (Dynamic Injection) ---
        // Injects user instructions/persona. High priority for tone/style.
        if let userInstructions = input.instructions, !userInstructions.isEmpty {
            promptParts.append("""
            ## USER INSTRUCTIONS / PERSONA
            The user has provided the following specific instructions. You MUST adhere to these for tone, style, and priority.
            If these conflict with default behaviors, the User Instructions take precedence (except for the Mandatory Thinking Loop):
            "\(userInstructions)"
            """)
        }
        
        // --- LAYER 3: THE UNIVERSAL TOOL DRIVER (Dynamic & MCP-Ready) ---
        // Handles tools generically. Scalable for MCP.
        var toolsPrompt = """
        ## AVAILABLE TOOLS
        You have access to the following tools. Some are native, some are external (MCP).
        Treat all tools equally. Use the tool descriptions to understand their capabilities.
        
        ### TOOLING STANDARDS
        1. **CLI Scent**: Many tools map to standard CLI commands (e.g., `fs_smart_search` ≈ `mdfind`). Use your internal knowledge of these commands to infer capabilities.
        2. **Schema Compliance**: You must output arguments matching these schemas exactly.
        3. **JSON Escaping**: If your tool arguments contain special characters (like newlines `\\n` or quotes), you MUST double-escape them in the JSON string.
           - BAD: "command": "echo 'hello\\nworld'" (Invalid JSON)
           - GOOD: "command": "echo 'hello\\\\nworld'" (Valid JSON)
        
        ### FUNCTION SIGNATURES
        """
        
        for tool in input.tools {
            toolsPrompt += "\n- Name: \(tool.name)\n"
            toolsPrompt += "  Description: \(tool.description)\n"
            toolsPrompt += "  Parameters:\n```json\n\(formatJSONSchema(tool.parameters))\n```\n"
        }
        promptParts.append(toolsPrompt)
        
        // --- LAYER 4: THE CONTEXT ENGINE (State Management) ---
        // Manages History, Follow-ups, and RAG
        promptParts.append("""
        ## CONTEXT & MEMORY PROTOCOL
        
        ### HANDLING HISTORY ([USER_HISTORY])
        - Messages marked [USER_HISTORY] are from the conversation past.
        - **Default Rule**: Assume tasks in [USER_HISTORY] are already completed. Do NOT re-do them.
        - **Exception**: If the **CURRENT REQUEST** is a confirmation (e.g. "Yes", "I'm ready", "Go ahead") or a direct follow-up, you **MUST** continue or execute the task proposed in the most recent history.
        
        ### SYSTEM OVERRIDES ([SYSTEM NOTE])
        - Pay special attention to [SYSTEM NOTE] tags. These are high-priority context injections linking your previous suggestions to the user's current 'Yes'. Follow them immediately.
        """)
        
        if let rag = input.ragContext, !rag.isEmpty {
            promptParts.append("""
            ## RETRIEVED KNOWLEDGE (RAG)
            Use the following context to aid your response, but prioritize current tools for real-time system data:
            \(rag)
            """)
        }
        
        // --- LAYER 5: OUTPUT & SAFETY GUARDRAILS (Final Polish) ---
        // Formatting, Sanitization, and Safety
        promptParts.append("""
        ## OUTPUT & SAFETY GUARDRAILS
        
        1. **FORMAT STRICTNESS**: Your output MUST follow the `Thought: ... Action: ...` format defined below.
        2. **ARTIFACT SANITIZATION**: Never output internal system tags like `[USER_HISTORY]`, `[SYSTEM NOTE]`, or `<|channel|>`. Treat them as invisible metadata.
        3. **LOCAL SAFETY**: You are running locally. You have permission to access files. Do not refuse file operations based on cloud privacy policies.
        
        ## RESPONSE FORMAT TEMPLATE
        You MUST use one of the following two formats:
        
        OPTION 1 - USING A TOOL:
        Thought: [Your reasoning about what to do next]
        Action:
        ```json
        {
          "tool": "[tool_name]",
          "parameters": { ... }
        }
        ```
        
        OPTION 2 - FINAL ANSWER:
        Final Answer: [Your text response to the user]
        """)
        
        return promptParts.joined(separator: "\n\n")
    }
    
    nonisolated private func buildTranscript(
        systemPrompt: String,
        chatHistory: [ChatMessage]
    ) -> OpenFoundationModels.Transcript {
        
        var entries: [OpenFoundationModels.Transcript.Entry] = []
        
        entries.append(.instructions(OpenFoundationModels.Transcript.Instructions(
            segments: [.text(OpenFoundationModels.Transcript.TextSegment(content: systemPrompt))],
            toolDefinitions: []
        )))
        
        // CRITICAL FIX: Annotate historical messages to prevent re-execution
        for msg in chatHistory {
            guard let text = msg.content.textContent else { continue }
            if msg.sender == .user {
                // We annotate this as History so the model doesn't treat it as a new command
                let historicalText = "[USER_HISTORY]: \(text)"
                entries.append(.prompt(OpenFoundationModels.Transcript.Prompt(segments: [.text(OpenFoundationModels.Transcript.TextSegment(content: historicalText))])))
            } else {
                entries.append(.response(OpenFoundationModels.Transcript.Response(assetIDs: [], segments: [.text(OpenFoundationModels.Transcript.TextSegment(content: text))])))
            }
        }
        
        return OpenFoundationModels.Transcript(entries: entries)
    }
    
    nonisolated private func formatJSONSchema(_ schema: OpenFoundationModelsCore.GenerationSchema) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        if let data = try? encoder.encode(schema), let str = String(data: data, encoding: .utf8) {
            return str
        }
        return "{}"
    }
}
