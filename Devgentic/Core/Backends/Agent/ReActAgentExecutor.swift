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
/// Features the Devgentic Master Kernel (v3) with Structured Cognitive Steps.
actor ReActAgentExecutor: AgentExecutor {
    
    // MARK: - Properties
    
    nonisolated let architecture: AgentArchitecture = .reAct
    nonisolated private let maxIterations: Int
    
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
                    var scratchpad: [String] = [] // Stores tool outputs for the transcript
                    
                    // State Tracking for Memory Guard
                    // We treat memory as enabled if the Manager exists (implicit) or if we are in Agent mode.
                    let isMemoryEnabled = true
                    var hasUpdatedMemory = false
                    
                    // Trace Context from Input
                    let executionTrace = input.traceContext
                    
                    // Convert AgentTools to Native Tools for the Session
                    let nativeTools = input.tools.map { ReActNativeToolWrapper(agentTool: $0) }
                    
                    // Deduplicate History for Transcript
                    var historyForTranscript = input.chatHistory
                    if let lastMsg = historyForTranscript.last,
                       let lastContent = lastMsg.content.textContent?.trimmingCharacters(in: .whitespacesAndNewlines),
                       let inputContent = input.userInput.trimmingCharacters(in: .whitespacesAndNewlines) as String?,
                       (lastContent == inputContent || lastContent.contains(inputContent)) {
                        historyForTranscript = Array(historyForTranscript.dropLast())
                    }
                    
                    // 2. Enter the Cognitive Loop
                    cognitiveLoop: while currentIteration < self.maxIterations {
                        currentIteration += 1
                        
                        // Create a specific span for this iteration step
                        let iterationSpan = executionTrace.newSpan()
                        var iterationMetadata: [String: String] = ["iteration": "\(currentIteration)"]
                        
                        // --- PROMPT CONSTRUCTION (THE SANDWICH) ---
                        let systemPrompt = self.constructSandwichPrompt(input: input, scratchpad: scratchpad)
                        let transcript = self.buildTranscript(systemPrompt: systemPrompt, chatHistory: historyForTranscript)
                        let session = LanguageModelSession(model: model, tools: nativeTools, transcript: transcript)
                        
                        // 3. Structured Generation
                        let step: CognitiveStep
                        do {
                            let promptTrigger = (currentIteration == 1)
                                ? "Begin ReAct loop."
                                : "Review OBSERVATION. Verify if the goal is met. Decide next step."
                                
                            let response = try await session.respond(to: promptTrigger, generating: CognitiveStep.self)
                            step = response.content
                            
                        } catch {
                            logger.error("Cognitive Generation Failed: \(error.localizedDescription)")
                            scratchpad.append("System Error: Your last output failed JSON validation. Ensure 'parameters' is a valid JSON Object (not a string).")
                            
                            onTraceUpdate(AgentTraceLog(
                                traceID: iterationSpan.traceID,
                                spanID: iterationSpan.spanID,
                                parentSpanID: iterationSpan.parentSpanID,
                                stepNumber: currentIteration,
                                state: .errorRecovery,
                                content: "Invalid JSON Schema. Retrying...",
                                metadata: iterationMetadata
                            ))
                            continue cognitiveLoop
                        }
                        
                        // --- NEW: INTRINSIC MEMORY UPDATE (OPTIMIZATION) ---
                        // We check for memory updates natively before actions or final answers.
                        if let updateContent = step.memoryUpdate, !updateContent.isEmpty {
                            // We execute this immediately, bypassing the tool system
                            ContextMemoryManager.shared.updateSession(conversationID: input.conversationID, content: updateContent)
                            hasUpdatedMemory = true
                            
                            logger.info("Intrinsic Memory Update processed.")
                            
                            onTraceUpdate(AgentTraceLog(
                                traceID: iterationSpan.traceID,
                                spanID: iterationSpan.spanID,
                                parentSpanID: iterationSpan.parentSpanID,
                                stepNumber: currentIteration,
                                state: .acting, // It's an internal action
                                content: "💾 Saved Session Context (Intrinsic)",
                                metadata: ["type": "memory_update"]
                            ))
                        }
                        // ---------------------------------------------------
                        
                        // 4. UI Feedback
                        onTraceUpdate(AgentTraceLog(
                            traceID: iterationSpan.traceID,
                            spanID: iterationSpan.spanID,
                            parentSpanID: iterationSpan.parentSpanID,
                            stepNumber: currentIteration,
                            state: .thinking,
                            content: step.displayHeadline,
                            metadata: iterationMetadata
                        ))
                        logger.debug("Internal Monologue: \(step.internalMonologue)")
                        
                        // 5. Logic Branching
                        
                        var actionWasExecuted = false
                        
                        // A. Tool Action
                        if let action = step.action {
                            actionWasExecuted = true
                            iterationMetadata["tool_name"] = action.toolName
                            
                            onTraceUpdate(AgentTraceLog(
                                traceID: iterationSpan.traceID,
                                spanID: iterationSpan.spanID,
                                parentSpanID: iterationSpan.parentSpanID,
                                stepNumber: currentIteration,
                                state: .acting,
                                content: "Executing \(action.toolName)...",
                                metadata: iterationMetadata
                            ))
                            
                            // Metrics & Execution (UPDATED: Now passes parent context and returns success status)
                            let (observation, isSuccess) = await self.executeTool(
                                action: action,
                                tools: input.tools,
                                parentContext: iterationSpan
                            )
                            
                            // Inject success status into metadata for EvaluationLogger
                            iterationMetadata["tool_success"] = String(isSuccess)
                            
                            onTraceUpdate(AgentTraceLog(
                                traceID: iterationSpan.traceID,
                                spanID: iterationSpan.spanID,
                                parentSpanID: iterationSpan.parentSpanID,
                                stepNumber: currentIteration,
                                state: .observing,
                                content: observation,
                                metadata: iterationMetadata
                            ))
                            
                            scratchpad.append("Observation (Step \(currentIteration)): Tool '\(action.toolName)' returned: \(observation)")
                        }
                        
                        // B. Final Answer
                        if let finalAnswer = step.finalAnswer {
                            
                            // --- MEMORY GUARD ---
                            // Prevents the Agent from finishing without saving state.
                            if isMemoryEnabled && !hasUpdatedMemory {
                                logger.warning("Memory Guard Triggered: Agent attempted to exit without saving.")
                                
                                onTraceUpdate(AgentTraceLog(
                                    traceID: iterationSpan.traceID,
                                    spanID: iterationSpan.spanID,
                                    parentSpanID: iterationSpan.parentSpanID,
                                    stepNumber: currentIteration,
                                    state: .errorRecovery,
                                    content: "Enforcing Memory Update...",
                                    metadata: ["reason": "unsaved_context"]
                                ))
                                
                                // Improved Warning
                                scratchpad.append("⚠️ SYSTEM INTERVENTION: Task appears complete, but session memory is not updated. \n\n1. DO NOT retry the task. \n2. You MUST fill the `memoryUpdate` field in your next response with the task outcome. \n3. Then provide the `finalAnswer` again.")
                                continue cognitiveLoop
                            }
                            // --------------------
                            
                            onTraceUpdate(AgentTraceLog(
                                traceID: iterationSpan.traceID,
                                spanID: iterationSpan.spanID,
                                parentSpanID: iterationSpan.parentSpanID,
                                stepNumber: currentIteration,
                                state: .finalizing,
                                content: finalAnswer,
                                metadata: iterationMetadata
                            ))
                            continuation.yield(finalAnswer)
                            continuation.finish()
                            return
                        }
                        
                        // C. Continue if we acted but didn't finish
                        if actionWasExecuted {
                            continue cognitiveLoop
                        }
                        
                        // D. Pure Reasoning (No Action, No Final Answer)
                        scratchpad.append("Observation (Step \(currentIteration)): You thought: \"\(step.internalMonologue)\". Proceed to the next step.")
                        continue cognitiveLoop
                        
                    } // End While
                    
                    // --- SMART EXIT STRATEGY ---
                    self.handleMaxIterationsReached(model: model, scratchpad: scratchpad, traceContext: executionTrace, continuation: continuation)
                    
                } catch {
                    logger.error("ReAct Fatal Error: \(error.localizedDescription)")
                    continuation.finish(throwing: error)
                }
            }
        }
    }
    
    // MARK: - Prompt Engineering (The Sandwich Architecture)
    
    nonisolated private func constructSandwichPrompt(input: AgentInput, scratchpad: [String]) -> String {
        return [
            buildKernelLayer(),           // Layer 1: Immutable Physics
            buildMemoryLayer(input),      // Layer 1.5: Persistent Memory
            buildReActStrategyLayer(),    // Layer 2: Thinking Process
            buildPersonaLayer(input),     // Layer 3: User Customization
            buildContextLayer(input, scratchpad) // Layer 4: Context
        ].joined(separator: "\n\n")
    }
    
    nonisolated private func buildKernelLayer() -> String {
        let osVersion = ProcessInfo.processInfo.operatingSystemVersionString
        let userName = NSUserName()
        let date = Date().formatted(date: .numeric, time: .shortened)
        
        return """
        # LAYER 1: KERNEL CONTEXT
        You are Devgentic, a specialized macOS System Agent.
        
        ## SYSTEM FACTS
        - OS: macOS \(osVersion)
        - Shell: Zsh (Non-Interactive Mode)
        - User: \(userName)
        - Date: \(date)
        
        ## SAFETY PROTOCOLS (NON-NEGOTIABLE)
        1. **NON-INTERACTIVE ONLY**: You cannot run commands that require user input (e.g., `nano`, `vim`, `sudo` without -n, `top`). Use `cat`, `grep`, `sed`, `awk` instead.
        2. **DESTRUCTIVE ACTIONS**: Do not use `rm -rf` on system directories. Verify paths exist before operating on them.
        3. **PRIVACY**: Do not upload user data to external servers unless explicitly instructed.
        """
    }
    
    nonisolated private func buildMemoryLayer(_ input: AgentInput) -> String {
        guard let memory = input.persistentMemory, !memory.isEmpty else { return "" }
        return """
        # LAYER 1.5: PERSISTENT MEMORY
        \(memory)
        
        ## 🕵️‍♂️ AUDIT LOGS (EVIDENCE LOCKER)
        You have access to a permanent record of past actions.
        - To find *what* you did previously, use `search_action_logs`.
        - To see *exactly* which files were moved/deleted, use `read_action_log`.
        """
    }
    
    nonisolated private func buildReActStrategyLayer() -> String {
        return """
        # LAYER 2: COGNITIVE STRATEGY (ReAct)
        
        ## THE LOOP
        You must strictly follow the **Reasoning -> Acting -> Observing** loop.
        1. **Thought**: Analyze the situation. What do I know? What is missing?
        2. **Action**: Select the best tool to make progress.
        3. **Observation**: Wait for the tool output.
        
        ## VERIFICATION PROTOCOL (CRITICAL)
        Before deciding to take an action, you MUST verify if the goal is ALREADY met.
        - If you think "I need to move the file", first check "Is the file already there?".
        - If the previous tool call succeeded, assume the state has changed.
        - Do not repeat actions blindly.

        ## MANDATORY MEMORY PROTOCOL (INTRINSIC)
        - **BEFORE** or **WITH** the "Final Answer", you **MUST** populate the `memoryUpdate` field.
        - This field will **APPEND** to the session log. Do not rewrite the whole log.
        - Record the outcome of your task (Success, Failure, or Partial) so you remember it in the future.
        """
    }
    
    nonisolated private func buildPersonaLayer(_ input: AgentInput) -> String {
        guard let instructions = input.instructions, !instructions.isEmpty else { return "" }
        return """
        # LAYER 3: USER DEFINED INSTRUCTIONS
        \"\"\"
        \(instructions)
        \"\"\"
        """
    }
    
    nonisolated private func buildContextLayer(_ input: AgentInput, _ scratchpad: [String]) -> String {
        var context = "# LAYER 4: EXECUTION CONTEXT\n"
        
        if let plan = input.approvedPlan {
            context += """
            ## APPROVED PLAN (FROM MANAGER)
            CONTEXT BRIEF: \(plan.contextBrief)
            STEPS:
            \(plan.steps.map { "\($0.id). \($0.goal)" }.joined(separator: "\n"))
            
            """
        } else {
            context += """
            ## USER REQUEST
            "\(input.userInput)"
            
            """
        }
        
        context += "\n## AVAILABLE TOOLS\n"
        for tool in input.tools {
            context += "- **\(tool.name)**: \(tool.description)\n"
            context += "  Schema: \(formatJSONSchema(tool.parameters))\n"
        }
        
        if !scratchpad.isEmpty {
            context += """
            
            ## SYSTEM STATUS LOG (PAST OBSERVATIONS)
            \(scratchpad.joined(separator: "\n\n"))
            """
        } else {
            context += "\n## SYSTEM STATUS LOG\n(No actions taken yet.)"
        }
        
        // UPDATED: Native JSON Format Instructions
        context += """
        
        ## RESPONSE FORMAT (STRICT JSON)
        Return ONLY a JSON object matching this schema.
        
        **CRITICAL JSON RULES:**
        1. The `parameters` field MUST be a standard JSON Object.
        2. Do NOT use stringified JSON inside `parameters`.
        
        ✅ **CORRECT:**
        {
          "action": {
            "toolName": "write_file",
            "parameters": { "path": "/tmp/test.txt", "content": "Hello" }
          }
        }
        
        {
          "internalMonologue": "Your reasoning here...",
          "displayHeadline": "Short status for UI...",
          "action": { "toolName": "...", "parameters": { ... } } OR null,
          "memoryUpdate": "New entry to APPEND to the session log..." OR null,
          "finalAnswer": "Text..." OR null
        }
        """
        
        return context
    }
    
    // MARK: - Tool Execution
    
    nonisolated private func executeTool(
        action: ToolAction,
        tools: [AgentTool],
        parentContext: TraceContext
    ) async -> (output: String, isSuccess: Bool) {
        // 1. Instrumentation Setup
        var toolSpan = parentContext.newSpan()
        toolSpan.addMetadata("tool_name", value: action.toolName)
        
        let startTime = Date()
        var isSuccess = true
        var errorDescription: String? = nil
        
        // 2. Tool Resolution
        var sanitizedName = action.toolName
        if !tools.contains(where: { $0.name == sanitizedName }) {
            if let clean = sanitizedName.components(separatedBy: CharacterSet(charactersIn: "<| ")).first, !clean.isEmpty {
                sanitizedName = clean
            }
        }
        
        // 3. Execution Block
        var output: String
        
        if let tool = tools.first(where: { $0.name == sanitizedName }) {
            do {
                let encoder = JSONEncoder()
                encoder.outputFormatting = [.sortedKeys]
                
                // This assumes action.parameters is now [String: AnyCodable]
                let paramData = try encoder.encode(action.parameters)
                
                output = try await tool.run(paramData)
                
                // HEURISTIC: Many tools return string errors that start with "Error:"
                // We capture this for metrics even if the swift call didn't throw.
                if output.hasPrefix("Error") {
                    isSuccess = false
                    errorDescription = output
                }
            } catch {
                isSuccess = false
                errorDescription = error.localizedDescription
                output = "Error encoding/executing parameters for tool '\(sanitizedName)': \(error.localizedDescription)"
            }
        } else {
            isSuccess = false
            errorDescription = "Tool not found in registry"
            output = "Error: Tool '\(action.toolName)' not found. Available tools: \(tools.map { $0.name }.joined(separator: ", "))"
            
            // Record hallucination specifically
            Task { @MainActor in
                MetricsManager.shared.recordHallucination(toolName: action.toolName, context: toolSpan)
            }
        }
        
        // 4. Telemetry Recording
        let duration = Date().timeIntervalSince(startTime)
        
        Task { @MainActor in
            // Record Reliability (Success/Fail rate)
            MetricsManager.shared.recordToolReliability(
                toolName: sanitizedName,
                isSuccess: isSuccess,
                errorType: errorDescription,
                context: toolSpan
            )
            
            // Record Latency
            MetricsManager.shared.record(
                duration: duration,
                for: "tool_latency",
                context: toolSpan
            )
        }
        
        return (output, isSuccess)
    }

    // MARK: - Helper: Transcript Builder
    
    nonisolated private func buildTranscript(systemPrompt: String, chatHistory: [ChatMessage]) -> OpenFoundationModels.Transcript {
        var entries: [OpenFoundationModels.Transcript.Entry] = []
        entries.append(.instructions(OpenFoundationModels.Transcript.Instructions(
            segments: [.text(OpenFoundationModels.Transcript.TextSegment(content: systemPrompt))],
            toolDefinitions: []
        )))
        
        for msg in chatHistory {
            guard let text = msg.content.textContent else { continue }
            if msg.sender == .user {
                entries.append(.prompt(OpenFoundationModels.Transcript.Prompt(segments: [.text(OpenFoundationModels.Transcript.TextSegment(content: "[USER_HISTORY]: \(text)"))])))
            } else {
                entries.append(.response(OpenFoundationModels.Transcript.Response(assetIDs: [], segments: [.text(OpenFoundationModels.Transcript.TextSegment(content: text))])))
            }
        }
        return OpenFoundationModels.Transcript(entries: entries)
    }
    
    nonisolated private func formatJSONSchema(_ schema: OpenFoundationModelsCore.GenerationSchema) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        if let data = try? encoder.encode(schema), let str = String(data: data, encoding: .utf8) { return str }
        return "{}"
    }
    
    nonisolated private func handleMaxIterationsReached(
        model: any OpenFoundationModels.LanguageModel,
        scratchpad: [String],
        traceContext: TraceContext,
        continuation: AsyncThrowingStream<String, Error>.Continuation
    ) {
         continuation.yield("⚠️ **Task Limit Reached**\n\nI've done my best, but hit the step limit.")
         continuation.finish()
    }
}
