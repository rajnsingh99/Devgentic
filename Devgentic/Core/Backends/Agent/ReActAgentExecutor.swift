//
//  ReActAgentExecutor.swift
//  Devgentic
//
//  Created by Raj Singh on 28/01/26.
//
// Pure Split-State (Zero-History Context) with Rate Limiting & Context Pruning
// + Phase 2 Refactor: Decoupled Cognitive Strategies

import Foundation
import SwiftAgent
import OpenFoundationModels
import OpenFoundationModelsCore
import OSLog

private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "com.devgentic.app", category: "ReActExecutor")

// MARK: - Executor Implementation

/// A robust implementation of the ReAct (Reasoning + Acting) paradigm.
/// Features a Split-State architecture (RAM vs. Disk) and structured cognitive steps.
actor ReActAgentExecutor: AgentExecutor {
    
    // MARK: - Properties
    
    nonisolated let architecture: AgentArchitecture = .reAct
    nonisolated private let maxIterations: Int
    
    // Rate Limiting Configuration
    // Gemini Flash Free Tier is ~15 RPM. We aim for 1 request every 4 seconds to be safe (15 RPM).
    // Paid Tier is higher, but this safety net prevents "burst" bans.
    private let minRequestInterval: TimeInterval = 4.0
    private var lastRequestTime: Date = .distantPast
    
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
            let task = Task {
                do {
                    // 1. Initialize Context
                    // Log the exact model instance to confirm profile configuration
                    logger.info("🚀 ReAct Execution Initiated. Model Instance: \(String(describing: model))")
                    
                    // 0. PRE-FLIGHT COOL-DOWN (CRITICAL FIX FOR 429s)
                    await self.updateLastRequestTime()
                    
                    // [DEBUG SPY] Wrap the model to count actual API hits
                    let spyModel = APISpyModel(inner: model, logger: logger)
                    
                    var currentIteration = 0
                    var consecutiveRetries = 0 // Track infrastructure retries separately
                    var scratchpad: [String] = [] // Stores tool outputs for the transcript
                    
                    // Load the Active State (RAM) or create a default one if missing.
                    var currentState = input.activeState ?? MutableActiveState(
                        sessionID: input.conversationID.uuidString,
                        primaryGoal: input.userInput,
                        subTasks: [],
                        negativeConstraints: [], // Loaded from previous sessions if persisted
                        workingMemory: [:]
                    )
                    
                    // Handle State Inertia:
                    if input.isNewRequest {
                        logger.info("New Request Detected: Overwriting stale goal in RAM.")
                        
                        currentState = MutableActiveState(
                            sessionID: currentState.sessionID,
                            primaryGoal: input.userInput,
                            subTasks: [],
                            negativeConstraints: currentState.negativeConstraints,
                            workingMemory: currentState.workingMemory
                        )
                        
                        var cleanMemory = currentState.workingMemory
                        cleanMemory.removeValue(forKey: "current_focus")
                        cleanMemory.removeValue(forKey: "last_status")
                        
                        currentState = MutableActiveState(
                            sessionID: currentState.sessionID,
                            primaryGoal: currentState.primaryGoal,
                            subTasks: currentState.subTasks,
                            negativeConstraints: currentState.negativeConstraints,
                            workingMemory: cleanMemory
                        )
                        
                        ContextMemoryManager.shared.updateActiveState(conversationID: input.conversationID, state: currentState)
                    }
                    
                    var currentConstraints = Set(currentState.negativeConstraints)
                    let isMemoryEnabled = true
                    var hasUpdatedMemory = false
                    let executionTrace = input.traceContext
                    
                    // Context Window Hygiene:
                    var historyForExecution = input.chatHistory
                    if input.isNewRequest {
                        logger.info("Split-State Hygiene: Dropping linear transcript.")
                        historyForExecution = []
                    }
                    
                    // 2. Enter the Cognitive Loop
                    cognitiveLoop: while currentIteration < self.maxIterations {
                        // [CRITICAL FIX] Check for cancellation at the start of every loop iteration
                        try Task.checkCancellation()
                        
                        currentIteration += 1
                        
                        // --- RATE LIMIT ENFORCEMENT ---
                        await self.enforceRateLimit(iteration: currentIteration, continuation: continuation)
                        
                        let iterationSpan = executionTrace.newSpan()
                        var iterationMetadata: [String: String] = ["iteration": "\(currentIteration)"]
                        
                        // --- CONTEXT PRUNING ---
                        let prunedScratchpad = self.pruneScratchpad(scratchpad)
                        
                        let systemPrompt = self.constructSandwichPrompt(
                            input: input,
                            scratchpad: prunedScratchpad,
                            state: currentState,
                            constraints: currentConstraints,
                            isFreshStart: input.isNewRequest
                        )
                        
                        let transcript = self.buildTranscript(systemPrompt: systemPrompt, chatHistory: historyForExecution)
                        
                        // --- TOKEN LOGGING ---
                        let estimatedTokens = self.estimateTokenCount(systemPrompt: systemPrompt, chatHistory: historyForExecution)
                        logger.info("📊 [Iteration \(currentIteration)] Estimated Input: ~\(estimatedTokens) tokens")
                        if estimatedTokens > 8000 {
                             logger.warning("⚠️ High Token Count detected! This may trigger rate limits on lower tiers.")
                        }

                        // [CRITICAL FIX] DISABLE NATIVE TOOLS IN SESSION
                        // We pass spyModel here instead of model. Tools are empty because ReActExecutor handles them manually via JSON.
                        let session = LanguageModelSession(model: spyModel, tools: [], transcript: transcript)
                        
                        // 3. Structured Generation
                        let step: CognitiveStep
                        do {
                            // [ARCHITECTURAL REFACTOR: STRATEGY PATTERN]
                            // The executor delegates the "How" of generation to the injected strategy.
                            // This supports OpenAI (Native), Gemini (Shadow Schema), and Ollama (JSON Mode) uniformly.
                            step = try await input.generatorStrategy.generate(
                                session: session,
                                iteration: currentIteration
                            )
                            
                            // Success! Update timestamp and reset retries
                            await self.updateLastRequestTime()
                            consecutiveRetries = 0
                            
                        } catch {
                            // [ARCHITECTURAL UPGRADE: RESILIENCY LAYER]
                            // Distinguish between Infrastructure Failures and Cognitive Failures.
                            
                            await self.updateLastRequestTime()
                            
                            let errorDesc = error.localizedDescription
                            let isRateLimit = errorDesc.contains("429") ||
                                              errorDesc.localizedCaseInsensitiveContains("rate limit") ||
                                              errorDesc.localizedCaseInsensitiveContains("quota") ||
                                              errorDesc.localizedCaseInsensitiveContains("resource exhausted")

                            let isTimeout = (error as? URLError)?.code == .timedOut || errorDesc.contains("timed out")
                            
                            if isRateLimit {
                                consecutiveRetries += 1
                                let backoff = pow(2.0, Double(min(consecutiveRetries, 6)))
                                logger.warning("🛑 Rate Limit Hit. Backing off for \(backoff)s")
                                
                                continuation.yield(.thought("🛑 Rate Limit Hit. Pausing for \(Int(backoff))s to cool down..."))
                                onTraceUpdate(AgentTraceLog(
                                    traceID: iterationSpan.traceID,
                                    spanID: iterationSpan.spanID,
                                    parentSpanID: iterationSpan.parentSpanID,
                                    stepNumber: currentIteration,
                                    state: .errorRecovery,
                                    content: "Rate Limit (429). Pausing...",
                                    metadata: ["delay": "\(backoff)"]
                                ))
                                try? await Task.sleep(nanoseconds: UInt64(backoff * 1_000_000_000))
                                currentIteration -= 1
                                continue cognitiveLoop
                            }
                            
                            if isTimeout {
                                logger.warning("⏳ Network Timeout. Retrying...")
                                continuation.yield(.thought("⏳ Network Timeout. Retrying request..."))
                                onTraceUpdate(AgentTraceLog(
                                    traceID: iterationSpan.traceID,
                                    spanID: iterationSpan.spanID,
                                    parentSpanID: iterationSpan.parentSpanID,
                                    stepNumber: currentIteration,
                                    state: .errorRecovery,
                                    content: "Network Timeout. Retrying...",
                                    metadata: ["reason": "timeout"]
                                ))
                                currentIteration -= 1
                                continue cognitiveLoop
                            }
                            
                            // Cognitive/Parsing Error
                            logger.error("Cognitive Generation Failed: \(error.localizedDescription)")
                            scratchpad.append("System Error: Your last output failed JSON validation. Ensure you are outputting a valid JSON INSTANCE (values) and NOT the schema definition. Check 'parameters' is a valid JSON Object.")
                            
                            continuation.yield(.thought("⚠️ Error: Invalid JSON output from model. Retrying..."))
                            
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
                        continuation.yield(.thought(step.internalMonologue))
                        
                        // Synchronize State:
                        if let update = step.memoryUpdate {
                            hasUpdatedMemory = true
                            
                            ContextMemoryManager.shared.appendToHistory(
                                conversationID: input.conversationID,
                                content: "**Goal:** \(update.goalSummary) | **Status:** \(update.goalStatus)\n\(update.logEntry)"
                            )
                            
                            var newWorkingMemory = currentState.workingMemory
                            newWorkingMemory["last_status"] = update.goalStatus
                            newWorkingMemory["current_focus"] = update.goalSummary
                            
                            currentState = MutableActiveState(
                                sessionID: currentState.sessionID,
                                primaryGoal: currentState.primaryGoal,
                                subTasks: currentState.subTasks,
                                negativeConstraints: Array(currentConstraints),
                                workingMemory: newWorkingMemory
                            )
                            ContextMemoryManager.shared.updateActiveState(conversationID: input.conversationID, state: currentState)
                            
                            logger.info("Memory Synced: \(update.goalStatus)")
                            continuation.yield(.thought("💾 State Synced: \(update.goalStatus)"))
                            
                            Task {
                                await self.persistToVectorStore(
                                    log: update.logEntry,
                                    conversationID: input.conversationID
                                )
                            }
                            
                            onTraceUpdate(AgentTraceLog(
                                traceID: iterationSpan.traceID,
                                spanID: iterationSpan.spanID,
                                parentSpanID: iterationSpan.parentSpanID,
                                stepNumber: currentIteration,
                                state: .acting,
                                content: "💾 Memory Update: \(update.goalStatus)",
                                metadata: ["type": "memory_update", "status": update.goalStatus]
                            ))
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
                        
                        // 5. Logic Branching
                        var actionWasExecuted = false
                        
                        // A. Tool Action
                        if let action = step.action {
                            actionWasExecuted = true
                            iterationMetadata["tool_name"] = action.toolName
                            
                            if let path = self.extractPath(from: action.parameters),
                               currentState.isPathForbidden(path) {
                                
                                let violationMsg = "🚫 GHOST PROTOCOL: Access to '\(path)' is FORBIDDEN by Negative Constraints. Do not retry this path."
                                scratchpad.append("System Alert: \(violationMsg)")
                                continuation.yield(.thought(violationMsg))
                                continue cognitiveLoop
                            }
                            
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
                            
                            let (observation, isSuccess) = await self.executeTool(
                                action: action,
                                tools: input.tools,
                                parentContext: iterationSpan
                            )
                            
                            if !isSuccess {
                                if let path = self.extractPath(from: action.parameters) {
                                    logger.info("Ghost Protocol: Adding \(path) to negative constraints.")
                                    currentConstraints.insert(path)
                                    
                                    currentState = MutableActiveState(
                                        sessionID: currentState.sessionID,
                                        primaryGoal: currentState.primaryGoal,
                                        subTasks: currentState.subTasks,
                                        negativeConstraints: Array(currentConstraints),
                                        workingMemory: currentState.workingMemory
                                    )
                                    ContextMemoryManager.shared.updateActiveState(conversationID: input.conversationID, state: currentState)
                                }
                            }
                            
                            continuation.yield(.toolOutput(ToolOutput(toolName: action.toolName, output: observation, isSuccess: isSuccess)))
                            
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
                                scratchpad.append("⚠️ SYSTEM INTERVENTION: Task appears complete, but session memory is not updated. \n\n1. DO NOT retry the task. \n2. You MUST fill the `memoryUpdate` OBJECT in your next response. \n3. Then provide the `finalAnswer` again.")
                                continue cognitiveLoop
                            }
                            
                            if let update = step.memoryUpdate, update.goalStatus.caseInsensitiveCompare("ACTIVE") == .orderedSame {
                                logger.warning("Agent finalized with ACTIVE status. Forcing COMPLETED to prevent ghost loop.")
                                
                                var finalState = currentState
                                var wm = finalState.workingMemory
                                wm["last_status"] = "COMPLETED"
                                finalState = MutableActiveState(
                                    sessionID: finalState.sessionID,
                                    primaryGoal: finalState.primaryGoal,
                                    subTasks: finalState.subTasks,
                                    negativeConstraints: finalState.negativeConstraints,
                                    workingMemory: wm
                                )
                                ContextMemoryManager.shared.updateActiveState(conversationID: input.conversationID, state: finalState)
                                continuation.yield(.thought("✅ Auto-Correcting Memory Status: COMPLETED"))
                            }
                            
                            onTraceUpdate(AgentTraceLog(
                                traceID: iterationSpan.traceID,
                                spanID: iterationSpan.spanID,
                                parentSpanID: iterationSpan.parentSpanID,
                                stepNumber: currentIteration,
                                state: .finalizing,
                                content: finalAnswer,
                                metadata: iterationMetadata
                            ))
                            
                            continuation.yield(.content(finalAnswer))
                            continuation.finish()
                            return
                        }
                        
                        if actionWasExecuted { continue cognitiveLoop }
                        
                        scratchpad.append("Observation (Step \(currentIteration)): Reasoning: \"\(step.internalMonologue)\". Proceed.")
                        continue cognitiveLoop
                        
                    } // End While Loop
                    
                    self.handleMaxIterationsReached(model: model, scratchpad: scratchpad, traceContext: executionTrace, continuation: continuation)
                    
                } catch is CancellationError {
                    logger.notice("🚫 Execution Task Cancelled cleanly.")
                    continuation.finish()
                } catch {
                    logger.error("ReAct Fatal Error: \(error.localizedDescription)")
                    continuation.finish(throwing: error)
                }
            }
            
            // Forward cancellation to the Task
            continuation.onTermination = { @Sendable _ in
                task.cancel()
            }
        }
    }
    
    // MARK: - Rate Limiting & Optimization
    
    /// Prunes the scratchpad to keep only the most recent context.
    /// This prevents token explosion in long-running loops.
    nonisolated private func pruneScratchpad(_ scratchpad: [String]) -> [String] {
        // Keep the first entry (original context) and the last 3 entries (recent actions).
        // This simulates a "Rolling Context Window".
        guard scratchpad.count > 4 else { return scratchpad }
        
        var pruned = [String]()
        if let first = scratchpad.first {
            pruned.append(first)
        }
        
        pruned.append("... [Intermediate steps summarized to save context] ...")
        
        let recent = scratchpad.suffix(3)
        pruned.append(contentsOf: recent)
        
        return pruned
    }
    
    /// Enforces a minimum delay between requests to respect RPM limits.
    private func enforceRateLimit(iteration: Int, continuation: AsyncThrowingStream<AgentStreamEvent, Error>.Continuation) async {
        let now = Date()
        let timeSinceLast = now.timeIntervalSince(lastRequestTime)
        
        if timeSinceLast < minRequestInterval {
            let waitTime = minRequestInterval - timeSinceLast
            // Only notify user if wait is substantial (> 1s)
            if waitTime > 1.0 {
                logger.debug("Rate Limit Throttling: Sleeping for \(waitTime)s")
            }
            try? await Task.sleep(nanoseconds: UInt64(waitTime * 1_000_000_000))
        }
    }
    
    private func updateLastRequestTime() {
        self.lastRequestTime = Date()
    }
    
    // MARK: - Prompt Engineering (The Sandwich)
    
    nonisolated private func constructSandwichPrompt(
        input: AgentInput,
        scratchpad: [String],
        state: MutableActiveState,
        constraints: Set<String>,
        isFreshStart: Bool
    ) -> String {
        return [
            buildKernelLayer(),                                          // Layer 1: Immutable Physics
            buildMemoryLayer(state, input.recentHistory, isFreshStart), // Layer 1.5: Twin-Store Memory
            buildReActStrategyLayer(constraints),                       // Layer 2: Thinking + Constraints
            buildPersonaLayer(input),                                   // Layer 3: User Customization
            buildContextLayer(input, scratchpad)                        // Layer 4: Execution Context
        ].joined(separator: "\n\n")
    }
    
    /// Constructs the immutable system facts (Kernel Layer).
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
        1. **NON-INTERACTIVE ONLY**: You cannot run commands that require user input (e.g., `nano`, `vim`, `sudo` without -n).
        2. **DESTRUCTIVE ACTIONS**: Do not use `rm -rf` on system directories. Verify paths exist before operating on them.
        """
    }
    
    /// Constructs the memory layer, including RAM state and read-only history.
    nonisolated private func buildMemoryLayer(_ state: MutableActiveState, _ recentHistory: String?, _ isFreshStart: Bool) -> String {
        // Pretty print the JSON State
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let jsonState = (try? String(data: encoder.encode(state), encoding: .utf8)) ?? "{}"
        
        let history = recentHistory ?? "(No recent history)"
        
        // Distinguish between "Ongoing Task" history and "Archived" history based on request type.
        let historyHeader = isFreshStart ? "## 📚 ARCHIVED LOGS (READ ONLY)" : "## 📜 RECENT ACTIVITY (Disk Tail)"
        let historyWarning = isFreshStart ? "(NOTE: These actions are from a previous turn. Do not resume them. Focus on Active Memory.)" : ""
        
        return """
        # LAYER 1.5: TWIN-STORE MEMORY
        
        ## 🧠 ACTIVE MEMORY (RAM)
        This is your CURRENT brain state. Trust this over history.
        ```json
        \(jsonState)
        ```
        
        \(historyHeader)
        \(historyWarning)
        \(history)
        
        (Use 'search_action_logs' to see older history.)
        """
    }
    
    /// Constructs the strategy layer, including negative constraints (Ghost Protocol).
    nonisolated private func buildReActStrategyLayer(_ constraints: Set<String>) -> String {
        var constraintBlock = ""
        if !constraints.isEmpty {
            constraintBlock = """
            ## 🚫 NEGATIVE CONSTRAINTS (GHOST PROTOCOL)
            The following paths have FAILED previously. DO NOT ACCESS THEM:
            \(constraints.map { "- \($0)" }.joined(separator: "\n"))
            """
        }
        
        return """
        # LAYER 2: COGNITIVE STRATEGY
        
        ## THE LOOP
        1. **Analyze**: Check Active Memory & Recent Activity.
        2. **Reflect**: Why did the last step fail?
        3. **Plan**: If a path failed, add it to 'negativeConstraints'.
        
        \(constraintBlock)
        
        ## PROTOCOL
        - If a tool fails, **STOP**. Do not retry the exact same arguments.
        - Update `memoryUpdate` in your response to sync the state.
        """
    }
    
    /// Constructs the persona layer from user instructions.
    nonisolated private func buildPersonaLayer(_ input: AgentInput) -> String {
        guard let instructions = input.instructions, !instructions.isEmpty else { return "" }
        return "# LAYER 3: INSTRUCTIONS\n\(instructions)"
    }
    
    /// Constructs the execution context layer, including the current user query and tools.
    nonisolated private func buildContextLayer(_ input: AgentInput, _ scratchpad: [String]) -> String {
        var context = "# LAYER 4: EXECUTION CONTEXT\n"
        context += "## USER REQUEST\n\"\(input.userInput)\"\n\n"
        
        context += "## TOOLS\n"
        for tool in input.tools {
            context += "- **\(tool.name)**: \(tool.description)\n"
            context += "  Schema: \(formatJSONSchema(tool.parameters))\n"
        }
        
        if !scratchpad.isEmpty {
            context += "\n## SCRATCHPAD\n\(scratchpad.joined(separator: "\n\n"))"
        }
        
        return context
    }
    
    // MARK: - Helpers
    
    nonisolated private func estimateTokenCount(systemPrompt: String, chatHistory: [ChatMessage]) -> Int {
        var totalCharacters = 0
        
        // System Prompt
        totalCharacters += systemPrompt.count
        
        // Chat History
        for msg in chatHistory {
            guard let text = msg.content.textContent else { continue }
            if msg.sender == .user {
                totalCharacters += ("[USER]: \(text)").count
            } else {
                totalCharacters += text.count
            }
        }
        
        // Rough estimation: ~4 characters per token for English text + JSON overhead
        return totalCharacters / 4
    }
    
    nonisolated private func extractPath(from params: [String: AnyCodable]) -> String? {
        // Try to find a "path" argument in the dictionary
        // We handle AnyCodable encoding/decoding here to safely extract strings
        if let val = params["path"] {
            let encoder = JSONEncoder()
            if let data = try? encoder.encode(val),
               let str = String(data: data, encoding: .utf8) {
                // Clean up quotes that JSON encoding might add to a simple string
                return str.trimmingCharacters(in: CharacterSet(charactersIn: "\""))
            }
        }
        return nil
    }
    
    nonisolated private func persistToVectorStore(log: String, conversationID: UUID) async {
        // Relies on shared singletons assumed to be in the project
        guard let embedding = await EmbeddingService.shared.generateEmbedding(for: log) else { return }
        
        await VectorStoreService.shared.addDocument(
            content: log,
            embedding: embedding,
            metadata: ["type": "action_log", "conversation_id": conversationID.uuidString]
        )
    }
    
    // MARK: - Tool Execution
    
    nonisolated private func executeTool(
        action: ToolAction,
        tools: [AgentTool],
        parentContext: TraceContext
    ) async -> (output: String, isSuccess: Bool) {
        var toolSpan = parentContext.newSpan()
        toolSpan.addMetadata("tool_name", value: action.toolName)
        
        let startTime = Date()
        var isSuccess = true
        var errorDescription: String? = nil
        
        // Sanitize tool name (remove generic prefixes if necessary)
        var sanitizedName = action.toolName
        if !tools.contains(where: { $0.name == sanitizedName }) {
            if let clean = sanitizedName.components(separatedBy: CharacterSet(charactersIn: "<| ")).first {
                sanitizedName = clean
            }
        }
        
        var output: String
        
        if let tool = tools.first(where: { $0.name == sanitizedName }) {
            do {
                let encoder = JSONEncoder()
                encoder.outputFormatting = [.sortedKeys]
                let paramData = try encoder.encode(action.parameters)
                output = try await tool.run(paramData)
                // Heuristic for success: check if output starts with "error" (case insensitive)
                if output.trimmingCharacters(in: .whitespacesAndNewlines).lowercased().hasPrefix("error") {
                    isSuccess = false
                    errorDescription = output
                }
            } catch {
                isSuccess = false
                errorDescription = error.localizedDescription
                output = "Error executing tool: \(error.localizedDescription)"
            }
        } else {
            isSuccess = false
            errorDescription = "Tool not found"
            output = "Tool not found"
            Task { @MainActor in
                MetricsManager.shared.recordHallucination(toolName: action.toolName, context: toolSpan)
            }
        }
        
        let duration = Date().timeIntervalSince(startTime)
        Task { @MainActor in
            MetricsManager.shared.recordToolReliability(
                toolName: sanitizedName,
                isSuccess: isSuccess,
                errorType: errorDescription,
                context: toolSpan
            )
            MetricsManager.shared.record(
                duration: duration,
                for: "tool_latency",
                context: toolSpan
            )
        }
        
        return (output, isSuccess)
    }
    
    nonisolated private func buildTranscript(systemPrompt: String, chatHistory: [ChatMessage]) -> OpenFoundationModels.Transcript {
        var entries: [OpenFoundationModels.Transcript.Entry] = []
        
        // System Prompt
        entries.append(.instructions(OpenFoundationModels.Transcript.Instructions(
            segments: [.text(OpenFoundationModels.Transcript.TextSegment(content: systemPrompt))],
            toolDefinitions: []
        )))
        
        // Chat History
        for msg in chatHistory {
            guard let text = msg.content.textContent else { continue }
            if msg.sender == .user {
                entries.append(.prompt(OpenFoundationModels.Transcript.Prompt(segments: [.text(OpenFoundationModels.Transcript.TextSegment(content: "[USER]: \(text)"))])))
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

// MARK: - Debug Spy Model

/// A debugging wrapper to count actual API calls.
/// Use this to verify if the library is looping internally.
private struct APISpyModel: OpenFoundationModels.LanguageModel {
    let inner: any OpenFoundationModels.LanguageModel
    let logger: Logger
    
    var isAvailable: Bool { inner.isAvailable }
    
    func supports(locale: Locale) -> Bool {
        return inner.supports(locale: locale)
    }
    
    func generate(transcript: OpenFoundationModels.Transcript, options: OpenFoundationModels.GenerationOptions?) async throws -> OpenFoundationModels.Transcript.Entry {
        logger.fault("🚨 ACTUAL API CALL TRIGGERED (Generate) - Count this!")
        return try await inner.generate(transcript: transcript, options: options)
    }
    
    func stream(transcript: OpenFoundationModels.Transcript, options: OpenFoundationModels.GenerationOptions?) -> AsyncThrowingStream<OpenFoundationModels.Transcript.Entry, Error> {
        logger.fault("🚨 ACTUAL API CALL TRIGGERED (Stream) - Count this!")
        return inner.stream(transcript: transcript, options: options)
    }
}
