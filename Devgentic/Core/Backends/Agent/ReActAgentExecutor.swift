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
                    
                    // Trace Context from Input
                    // This is the "Execution" span created by AgentConnect
                    let executionTrace = input.traceContext
                    
                    // Convert AgentTools to Native Tools for the Session
                    let nativeTools = input.tools.map { ReActNativeToolWrapper(agentTool: $0) }
                    
                    // Deduplicate History
                    var historyForTranscript = input.chatHistory
                    if let lastMsg = historyForTranscript.last,
                       lastMsg.sender == .user,
                       let lastContent = lastMsg.content.textContent?.trimmingCharacters(in: .whitespacesAndNewlines),
                       let inputContent = input.userInput.trimmingCharacters(in: .whitespacesAndNewlines) as String?,
                       (lastContent == inputContent || lastContent.contains(inputContent)) {
                        historyForTranscript = Array(historyForTranscript.dropLast())
                    }
                    
                    // 2. Enter the Cognitive Loop
                    cognitiveLoop: while currentIteration < self.maxIterations {
                        currentIteration += 1
                        
                        // Create a specific span for this iteration step (Child of Execution Span)
                        let iterationSpan = executionTrace.newSpan()
                        var iterationMetadata: [String: String] = ["iteration": "\(currentIteration)"]
                        
                        let systemPrompt = self.constructSystemPrompt(input: input, scratchpad: scratchpad)
                        let transcript = self.buildTranscript(systemPrompt: systemPrompt, chatHistory: historyForTranscript)
                        let session = LanguageModelSession(model: model, tools: nativeTools, transcript: transcript)
                        
                        // 3. Structured Generation
                        let step: CognitiveStep
                        do {
                            let promptText = (currentIteration == 1)
                                ? self.contextualizeUserInput(input: input)
                                : "Review the previous observation and decide the next step."
                                
                            let response = try await session.respond(to: promptText, generating: CognitiveStep.self)
                            step = response.content
                            
                        } catch {
                            logger.error("Cognitive Generation Failed: \(error.localizedDescription) (traceID: \(iterationSpan.traceID))")
                            scratchpad.append("System Error: Your last response failed validation. You MUST return a valid JSON object matching the `CognitiveStep` schema.")
                            
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
                        logger.debug("Internal Monologue (trace: \(iterationSpan.traceID)): \(step.internalMonologue)")
                        
                        // 5. Logic Branching
                        
                        // A. Final Answer
                        if let finalAnswer = step.finalAnswer {
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
                        
                        // B. Tool Action
                        if let action = step.action {
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
                            
                            // METRICS: Start Timer
                            let toolStart = Date()
                            
                            let observation = await self.executeTool(action: action, tools: input.tools)
                            
                            // METRICS: End Timer & Record
                            let duration = Date().timeIntervalSince(toolStart)
                            let isError = observation.hasPrefix("Error:")
                            
                            Task { @MainActor in
                                if isError && observation.contains("not found") {
                                     MetricsManager.shared.recordHallucination(toolName: action.toolName, context: iterationSpan)
                                } else {
                                     MetricsManager.shared.recordToolReliability(
                                         toolName: action.toolName,
                                         isSuccess: !isError,
                                         errorType: isError ? observation : nil,
                                         context: iterationSpan
                                     )
                                }
                                MetricsManager.shared.record(duration: duration, for: "tool_latency", context: iterationSpan)
                            }
                            
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
                            continue cognitiveLoop
                        }
                        
                        // C. Pure Reasoning
                        scratchpad.append("Observation (Step \(currentIteration)): You thought: \"\(step.internalMonologue)\". Proceed to the next step.")
                        continue cognitiveLoop
                        
                    } // End While
                    
                    // --- SMART EXIT STRATEGY (MAX ITERATIONS REACHED) ---
                    // Instead of a generic error, we ask the Agent to summarize what it accomplished.
                    
                    onTraceUpdate(AgentTraceLog(
                        traceID: executionTrace.traceID,
                        spanID: executionTrace.spanID,
                        parentSpanID: executionTrace.parentSpanID,
                        stepNumber: currentIteration,
                        state: .finalizing,
                        content: "Generating partial summary..."
                    ))
                    
                    let summaryPrompt = """
                    ## SYSTEM NOTIFICATION
                    You reached the maximum iteration limit (\(self.maxIterations)) before declaring "Final Answer".
                    
                    ## TASK
                    Analyze the "SYSTEM STATUS LOG" (scratchpad) below.
                    1. Summarize what steps were **successfully completed** (e.g. files created, folders set up).
                    2. Identify what was **left unfinished**.
                    3. Provide a helpful response to the user explaining the partial success.
                    
                    ## STATUS LOG
                    \(scratchpad.joined(separator: "\n\n"))
                    """
                    
                    // Create a one-off session for the summary
                    let summarySession = LanguageModelSession(model: model, tools: [], instructions: "You are a helpful assistant providing a status report.")
                    
                    do {
                        let summaryResponse = try await summarySession.respond(to: summaryPrompt)
                        let summary = summaryResponse.content
                        continuation.yield("⚠️ **Task Limit Reached**\n\n" + summary)
                    } catch {
                        continuation.yield("I reached the maximum number of steps (\(self.maxIterations)) and could not generate a summary. Please check the logs.")
                    }
                    
                    continuation.finish()
                    
                } catch {
                    logger.error("ReAct Fatal Error: \(error.localizedDescription)")
                    continuation.finish(throwing: error)
                }
            }
        }
    }
    
    // MARK: - Tool Execution
    
    nonisolated private func executeTool(action: ToolAction, tools: [AgentTool]) async -> String {
        var sanitizedName = action.toolName
        if !tools.contains(where: { $0.name == sanitizedName }) {
            if let clean = sanitizedName.components(separatedBy: CharacterSet(charactersIn: "<| ")).first, !clean.isEmpty {
                sanitizedName = clean
            }
        }
        
        guard let tool = tools.first(where: { $0.name == sanitizedName }) else {
            return "Error: Tool '\(action.toolName)' not found. Available tools: \(tools.map { $0.name }.joined(separator: ", "))"
        }
        
        // Convert JSON string parameters to Data
        guard let paramData = action.parameters.data(using: .utf8) else {
            return "Error: Could not encode parameters to UTF-8 data."
        }
        
        do {
            // Validate JSON validity before running
            if (try? JSONSerialization.jsonObject(with: paramData)) == nil {
                 return "Error: Parameters string is not valid JSON: \(action.parameters)"
            }
            let result = try await tool.run(paramData)
            return result
        } catch {
            return "Error executing tool '\(sanitizedName)': \(error.localizedDescription)"
        }
    }
    
    // MARK: - Contextual Intelligence
    
    nonisolated private func contextualizeUserInput(input: AgentInput) -> String {
        let text = input.userInput.trimmingCharacters(in: .whitespacesAndNewlines)
        let lowerText = text.lowercased()
        let confirmationPrefixes = ["yes", "yeah", "yep", "sure", "ok", "okay", "go ahead", "proceed"]
        let isShortConfirmation = text.count < 100 && confirmationPrefixes.contains { lowerText.hasPrefix($0) }
        
        if isShortConfirmation {
            if let lastAssistantMsg = input.chatHistory.last(where: { $0.sender != .user }) {
                let contextContent = lastAssistantMsg.content.textContent ?? ""
                let suffix = contextContent.suffix(500)
                return """
                User Input: "\(text)"
                [SYSTEM NOTE: The user is confirming your previous suggestion: "...\(suffix)"]
                [INSTRUCTION: Proceed with the action implied by your previous suggestion.]
                """
            }
        }
        return text
    }
    
    // MARK: - Prompt Engineering (Structured)
    
    nonisolated private func constructSystemPrompt(input: AgentInput, scratchpad: [String]) -> String {
        var promptParts: [String] = []
        
        // --- LAYER 1: IDENTITY ---
        if let plan = input.approvedPlan {
            promptParts.append("""
            You are the **Executor Agent**. A Senior Planner has created a safety-approved plan for you.
            
            ## PRIME DIRECTIVE
            Execute the plan step-by-step.
            1. **DO NOT** deviate from the plan unless a tool error forces a retry.
            2. **DO NOT** ask the user for clarification; the Planner has already done that.
            3. **FOCUS** on the current step.
            
            ## RELEVANT CONTEXT (FROM ARCHITECT)
            \(plan.contextBrief)
            
            ## APPROVED PLAN
            \(plan.steps.map { "\($0.id). \($0.goal)" }.joined(separator: "\n"))
            """)
        } else {
            promptParts.append("""
            You are Devgentic, a highly capable macOS System Agent.
            Your goal is to change the system state to match the user's request.
            """)
        }
        
        // --- LAYER 2: OUTPUT FORMAT ---
        promptParts.append("""
        ## OUTPUT FORMAT (STRICT JSON)
        You are running in **Structured Mode**.
        For every step, you must output a valid JSON object matching the `CognitiveStep` schema.
        
        1. **internalMonologue**: Your private reasoning. Be detailed. Analyze failures here.
        2. **displayHeadline**: A short status update for the user (e.g. "Scanning database...", "Running script...").
        3. **action**: Define this ONLY if you need to run a tool.
        4. **finalAnswer**: Define this ONLY if the task is done.
        
        DO NOT output markdown, 'Thought:', or raw text. Output ONLY the JSON.
        """)
        
        // --- LAYER 3: TOOLS ---
        var toolsPrompt = "## AVAILABLE TOOLS"
        for tool in input.tools {
            toolsPrompt += "\n- Name: \(tool.name)\n"
            toolsPrompt += "  Description: \(tool.description)\n"
            toolsPrompt += "  Parameters:\n```json\n\(formatJSONSchema(tool.parameters))\n```\n"
        }
        promptParts.append(toolsPrompt)
        
        // --- LAYER 4: MEMORY ---
        if !scratchpad.isEmpty {
            promptParts.append("""
            ## SYSTEM STATUS LOG (PREVIOUS STEPS)
            \(scratchpad.joined(separator: "\n\n"))
            """)
        }
        
        // --- LAYER 5: MEMORY PROTOCOL ---
        promptParts.append("""
        ## MEMORY CHECK
        - If the user asks to "summarize" or "recall" a past event, and it is NOT in the Context Brief or Status Log above, you **MUST** use the `search_knowledge_base` tool.
        - Do not guess about past events.
        """)
        
        return promptParts.joined(separator: "\n\n")
    }
    
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
}
