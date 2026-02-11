//
//  ReActAgentExecutor.swift
//  Devgentic
//
//  Created by Raj Singh on 28/01/26.
//  PATCHED: Added Observation Interpretation Strategy
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
    ) -> AsyncThrowingStream<AgentStreamEvent, Error> {
        
        return AsyncThrowingStream { continuation in
            Task {
                do {
                    // 1. Initialize Context
                    var currentIteration = 0
                    var scratchpad: [String] = [] // Stores tool outputs for the transcript
                    var failedPaths: Set<String> = [] // Tracks paths that triggered errors
                    
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
                        let systemPrompt = self.constructSandwichPrompt(input: input, scratchpad: scratchpad, failedPaths: failedPaths)
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
                            
                            // Emit error thought
                            continuation.yield(.thought("Error: Invalid JSON output from model. Retrying..."))
                            
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
                        
                        // --- EMIT THOUGHT EVENT ---
                        // This allows the UI to show the "Thinking..." accordion
                        continuation.yield(.thought(step.internalMonologue))
                        
                        // --- NEW: INTRINSIC MEMORY UPDATE (OPTIMIZATION) ---
                        // We check for memory updates natively before actions or final answers.
                        if let updateContent = step.memoryUpdate, !updateContent.isEmpty {
                            // We execute this immediately, bypassing the tool system
                            ContextMemoryManager.shared.updateSession(conversationID: input.conversationID, content: updateContent)
                            hasUpdatedMemory = true
                            
                            logger.info("Intrinsic Memory Update processed.")
                            
                            continuation.yield(.thought("💾 Consolidating session memory..."))
                            
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
                        
                        // 4. UI Feedback (Trace)
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
                            
                            // --- EMIT TOOL CALL EVENT ---
                            let paramsJSON = try? JSONEncoder().encode(action.parameters)
                            let paramsString = paramsJSON.flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
                            continuation.yield(.toolCall(name: action.toolName, params: paramsString))
                            
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
                            
                            // --- ERROR TRACKING LOGIC ---
                            if !isSuccess {
                                // Extract any "path" argument from the parameters to block it in future turns
                                if let anyValue = action.parameters["path"] {
                                    // Try to decode AnyCodable to String (simplified logic)
                                    // Assuming AnyCodable stores the value internally, we rely on the fact that
                                    // string values usually encode to straightforward JSON strings.
                                    let encoder = JSONEncoder()
                                    if let data = try? encoder.encode(anyValue),
                                       let str = String(data: data, encoding: .utf8)?.replacingOccurrences(of: "\"", with: "") {
                                        failedPaths.insert(str)
                                    }
                                }
                            }
                            // ----------------------------
                            
                            // --- EMIT TOOL OUTPUT EVENT (Artifact) ---
                            let outputEvent = ToolOutput(
                                toolName: action.toolName,
                                output: observation,
                                isSuccess: isSuccess
                            )
                            continuation.yield(.toolOutput(outputEvent))
                            
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
                                
                                continuation.yield(.thought("⚠️ Memory Guard Triggered: Enforcing save..."))
                                
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
                            
                            // --- EMIT CONTENT EVENT (The Chat Bubble) ---
                            continuation.yield(.content(finalAnswer))
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
    
    nonisolated private func constructSandwichPrompt(input: AgentInput, scratchpad: [String], failedPaths: Set<String>) -> String {
        return [
            buildKernelLayer(),           // Layer 1: Immutable Physics
            buildMemoryLayer(input),      // Layer 1.5: Persistent Memory
            buildReActStrategyLayer(),    // Layer 2: Thinking Process
            buildPersonaLayer(input),     // Layer 3: User Customization
            buildContextLayer(input, scratchpad, failedPaths) // Layer 4: Context
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
        # LAYER 2: COGNITIVE STRATEGY (ReAct + Reflexion)
        
        ## THE LOOP
        1. **Analyze**: Look at the last OBSERVATION. Did it fail?
        2. **Reflect**: If it failed, WHY? (Wrong path? Missing tool? Permission error?)
        3. **Plan**: Decide a NEW approach. DO NOT RETRY the exact same parameters.
        4. **Act**: Execute the tool.
        
        ## OBSERVATION INTERPRETATION
        - **Trust your ACTION parameters**: If you executed `list_directory(path="/A/B")` and the tool returned a list of files without error, assume those ARE the files in `/A/B`.
        - **Ignore conflicting "Current Directory" footers**: Shell PWD footers only indicate where the shell session is sitting, NOT what folder you just listed.
        
        ## 🛡️ ERROR HANDLING PROTOCOL (STRICT)
        - If a tool returns "Error" or "doesn't exist":
          - You MUST acknowledge this in your `internalMonologue` and mark `previousStepOutcome` as "Failure".
          - You MUST NOT call the same tool with the same path again.
          - You MUST try a completely different strategy (e.g., use `fs_smart_search` to find the real path).
          
        ## FEW-SHOT EXAMPLES (Follow this reasoning style)
        
        [EXAMPLE 1: Handling a Missing File]
        User: "List files in /Projects/Beta"
        Action: list_directory(path="/Projects/Beta")
        Observation: Error: Directory not found.
        (CORRECT RESPONSE):
        {
          "previousStepOutcome": "Failure",
          "internalMonologue": "The path /Projects/Beta does not exist. I should not retry it. I need to find where 'Beta' actually is. I will use Spotlight to find it.",
          "displayHeadline": "Locating Beta folder...",
          "action": { "toolName": "fs_smart_search", "parameters": { "search_term": "Beta" } }
        }
        
        [EXAMPLE 2: Hallucination Check]
        User: "Read config.json"
        Action: read_file(path="/tmp/config.json")
        Observation: Error: File does not exist.
        (INCORRECT RESPONSE - DO NOT DO THIS):
        "I have read the file and it contains..." -> ❌ WRONG. DO NOT HALLUCINATE SUCCESS.
        
        ## DATA PRESENTATION PROTOCOL (CRITICAL)
        If the user asks to "List", "Show", "Read", or "Get" data (e.g., files, stats, logs):
        1. **DO NOT** summarize by saying "The files are listed" or "I have read the file".
        2. **YOU MUST** include the ACTUAL CONTENT of the Observation in your `finalAnswer`.
        3. Format the data nicely (e.g., use Markdown lists or code blocks).
        
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
    
    nonisolated private func buildContextLayer(_ input: AgentInput, _ scratchpad: [String], _ failedPaths: Set<String>) -> String {
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
        
        if !failedPaths.isEmpty {
            context += """
            
            ## 🛑 PREVIOUSLY FAILED PATHS
            The following paths have already been checked and DO NOT EXIST. Do not try them again:
            \(failedPaths.map { "- \($0)" }.joined(separator: "\n"))
            
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
          "previousStepOutcome": "Success",
          "action": {
            "toolName": "write_file",
            "parameters": { "path": "/tmp/test.txt", "content": "Hello" }
          }
        }
        
        {
          "previousStepOutcome": "Success" OR "Failure",
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
        continuation: AsyncThrowingStream<AgentStreamEvent, Error>.Continuation
    ) {
         continuation.yield(.content("⚠️ **Task Limit Reached**\n\nI've done my best, but hit the step limit."))
         continuation.finish()
    }
}
