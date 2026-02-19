//
//  ReActAgentExecutor.swift
//  Devgentic
//
//  Created by Raj Singh on 28/01/26.
//
// Pure Split-State (Zero-History Context) with Rate Limiting & Context Pruning
// + Phase 3: Header-Aware Adaptation (The Safety Net) - Fixed APIError Type
// + Phase 4: Graceful Cancellation & Memory State Persistence
// + Phase 5: [HITL] Tool Gating & Suspension
// + Refactored: Prompt Generation Layer decoupled from Persona Identity
// + Hotfix: Explicit Task Completion instructions to prevent "Tool Not Found" loop

import Foundation
import OSLog

private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "com.devgentic.app", category: "ReActExecutor")

// MARK: - Executor Implementation

/// A robust implementation of the ReAct (Reasoning + Acting) paradigm.
/// Features a Split-State architecture (RAM vs. Disk) and structured cognitive steps.
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
        model: any LLMProvider,
        input: AgentInput,
        onTraceUpdate: @escaping @Sendable (AgentTraceLog) -> Void
    ) -> AsyncThrowingStream<AgentStreamEvent, Error> {
        
        return AsyncThrowingStream { continuation in
            let task = Task {
                // [CRITICAL FIX] Capture state outside the 'do' block so it's accessible in 'catch'
                var lastKnownState: MutableActiveState?
                
                do {
                    // 1. Initialize Context
                    logger.info("🚀 ReAct Execution Initiated. Model Instance: \(String(describing: model))")
                    
                    // [DEBUG SPY] Wrap the model to count actual API hits
                    let spyModel = APISpyModel(inner: model, logger: logger)
                    
                    var currentIteration = 0
                    var consecutiveRetries = 0
                    var consecutiveParseFailures = 0
                    let maxConsecutiveParseFailures = 3
                    var scratchpad: [String] = []
                    
                    // Load the Active State (RAM) or create a default one if missing.
                    var currentState = input.activeState ?? MutableActiveState(
                        sessionID: input.conversationID.uuidString,
                        primaryGoal: input.userInput,
                        subTasks: [],
                        negativeConstraints: [],
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
                    
                    // Sync outer variable
                    lastKnownState = currentState
                    
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
                        try Task.checkCancellation()
                        
                        currentIteration += 1
                        
                        // --- PHASE 2: GLOBAL TOKEN BUCKET CONSUMPTION ---
                        // 1. Check if we need to warn the user about a long wait (Burst exhausted)
                        let projectedWait = await GlobalRateLimiter.shared.timeUntilNextToken(for: input.rateLimitCategory)
                        if projectedWait > 1.5 {
                            let waitMsg = "Throttling for \(Int(projectedWait))s to respect \(input.rateLimitCategory) limits..."
                            continuation.yield(.thought(waitMsg))
                            onTraceUpdate(AgentTraceLog(
                                traceID: executionTrace.traceID,
                                spanID: executionTrace.newSpan().spanID, // Ephemeral span
                                parentSpanID: executionTrace.parentSpanID,
                                stepNumber: currentIteration,
                                state: .thinking,
                                content: waitMsg
                            ))
                        }
                        
                        // 2. Acquire Token (Suspends execution here if bucket is empty)
                        await GlobalRateLimiter.shared.wait(for: input.rateLimitCategory)
                        
                        
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
                        
                        let messages = self.buildMessages(systemPrompt: systemPrompt, chatHistory: historyForExecution)
                        
                        // --- TOKEN LOGGING ---
                        let estimatedTokens = self.estimateTokenCount(systemPrompt: systemPrompt, chatHistory: historyForExecution)
                        if estimatedTokens > 8000 {
                             logger.warning("⚠️ High Token Count detected (\(estimatedTokens)). This may trigger rate limits.")
                        }
                        
                        // [CRITICAL CHECK] Stop before calling LLM
                        try Task.checkCancellation()

                        // 3. Structured Generation
                        let step: CognitiveStep
                        do {
                            logger.info("⚡️ Invoking Strategy.generate (Attempt: \(consecutiveRetries + 1))")
                            
                            step = try await input.generatorStrategy.generate(
                                model: spyModel,
                                messages: messages,
                                iteration: currentIteration
                            )
                            
                            // Success! Reset retries and parse failures.
                            consecutiveRetries = 0
                            consecutiveParseFailures = 0

                        } catch {
                            // --- PHASE 3: HEADER-AWARE ERROR HANDLING ---
                            let errorDesc = error.localizedDescription
                            let isRateLimit = errorDesc.contains("429") ||
                                              errorDesc.localizedCaseInsensitiveContains("rate limit") ||
                                              errorDesc.localizedCaseInsensitiveContains("quota")
                            
                            let isTimeout = (error as? URLError)?.code == .timedOut || errorDesc.contains("timed out")
                            
                            if isRateLimit {
                                consecutiveRetries += 1
                                
                                // 3.1 Extract Server Mandate (The Truth)
                                let retryAfter = self.extractRetryAfter(from: error, consecutiveRetries: consecutiveRetries)
                                
                                logger.warning("🛑 Rate Limit (429). Server requested wait: \(retryAfter)s. Draining bucket.")
                                
                                // 3.2 DRAIN THE BUCKET: Sync local state with server reality
                                // This prevents the limiter from giving us a token immediately after we wake up
                                // if the server is still angry.
                                await GlobalRateLimiter.shared.drainAndPenalize(category: input.rateLimitCategory, penaltySeconds: retryAfter)
                                
                                continuation.yield(.thought("🛑 API Quota Hit. Pausing for \(Int(retryAfter))s..."))
                                onTraceUpdate(AgentTraceLog(
                                    traceID: iterationSpan.traceID,
                                    spanID: iterationSpan.spanID,
                                    parentSpanID: iterationSpan.parentSpanID,
                                    stepNumber: currentIteration,
                                    state: .errorRecovery,
                                    content: "Rate Limit (429). Pausing...",
                                    metadata: ["delay": "\(retryAfter)"]
                                ))
                                
                                // 3.3 Explicit Sleep for this failure
                                try? await Task.sleep(nanoseconds: UInt64(retryAfter * 1_000_000_000))
                                
                                currentIteration -= 1 // Retry the same iteration index
                                continue cognitiveLoop
                            }
                            
                            if isTimeout {
                                logger.warning("⏳ Network Timeout. Retrying...")
                                continuation.yield(.thought("⏳ Network Timeout. Retrying request..."))
                                currentIteration -= 1
                                continue cognitiveLoop
                            }
                            
                            // Cognitive/Parsing Error
                            consecutiveParseFailures += 1
                            logger.error("Cognitive Generation Failed (\(consecutiveParseFailures)/\(maxConsecutiveParseFailures)): \(error.localizedDescription)")

                            if consecutiveParseFailures >= maxConsecutiveParseFailures {
                                logger.error("🛑 Max consecutive parse failures reached. Aborting with graceful message.")
                                continuation.yield(.content("I'm having trouble processing this request right now — the model is returning responses I can't interpret. Please try rephrasing your request or switching to a different model."))
                                continuation.finish()
                                return
                            }

                            scratchpad.append("System Error: Your last output failed JSON validation (attempt \(consecutiveParseFailures)/\(maxConsecutiveParseFailures)). You MUST output a PURE JSON OBJECT with at minimum {\"internalMonologue\": \"...\", \"displayHeadline\": \"...\"}. No prose, no markdown, no schema definitions.")

                            continuation.yield(.thought("⚠️ Error: Invalid JSON output. Retrying (\(consecutiveParseFailures)/\(maxConsecutiveParseFailures))..."))

                            // Enforce rate limit before retrying to prevent rapid retry → 429 cascade
                            await GlobalRateLimiter.shared.wait(for: input.rateLimitCategory)
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
                            
                            // Update our cancellation fallback state
                            lastKnownState = currentState
                            
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
                            // [CRITICAL CHECK] Stop before executing tool
                            try Task.checkCancellation()

                            actionWasExecuted = true
                            iterationMetadata["tool_name"] = action.toolName

                            // [ASK_USER] Intercept clarification requests before normal dispatch
                            if action.toolName == "ask_user" {
                                let question: String
                                if let q = action.parameters["question"],
                                   let encoder = try? JSONEncoder().encode(q),
                                   let str = String(data: encoder, encoding: .utf8) {
                                    question = str.trimmingCharacters(in: CharacterSet(charactersIn: "\""))
                                } else {
                                    question = step.internalMonologue
                                }

                                logger.info("🙋 [ASK_USER] Agent requesting clarification: \(question)")

                                continuation.yield(.requestClarification(question: question))

                                onTraceUpdate(AgentTraceLog(
                                    traceID: iterationSpan.traceID,
                                    spanID: iterationSpan.spanID,
                                    parentSpanID: iterationSpan.parentSpanID,
                                    stepNumber: currentIteration,
                                    state: .requestingPermission,
                                    content: "Waiting for user clarification: \(question)"
                                ))

                                let userResponse = await ExecutionSuspensionService.shared.suspendForClarification(for: input.conversationID)

                                if let response = userResponse, !response.isEmpty {
                                    logger.info("✅ [ASK_USER] User responded: \(response.prefix(100))")
                                    let observation = "User Response: \(response)"
                                    scratchpad.append("Observation (Step \(currentIteration)): \(observation)")
                                    continuation.yield(.toolOutput(ToolOutput(toolName: "ask_user", output: observation, isSuccess: true)))
                                } else {
                                    logger.info("❌ [ASK_USER] User did not respond or cancelled.")
                                    let observation = "System: User did not provide a response. Proceed with your best judgment or provide a finalAnswer."
                                    scratchpad.append("Observation (Step \(currentIteration)): \(observation)")
                                    continuation.yield(.toolOutput(ToolOutput(toolName: "ask_user", output: observation, isSuccess: false)))
                                }

                                continue cognitiveLoop
                            }

                            // [HITL] 1. Resolve the tool definition to check sensitivity
                            let toolDefinition = input.tools.first { $0.name == action.toolName }

                            // [HITL] 2. Check Permission Gate
                            if let tool = toolDefinition, tool.requiresConfirmation {
                                logger.notice("🛑 [HITL] Tool '\(action.toolName)' requires confirmation. Suspending...")
                                
                                // A. Notify UI using new event type
                                continuation.yield(.requestConfirmation(
                                    toolName: action.toolName,
                                    params: self.serializeParams(action.parameters)
                                ))
                                
                                onTraceUpdate(AgentTraceLog(
                                    traceID: iterationSpan.traceID,
                                    spanID: iterationSpan.spanID,
                                    parentSpanID: iterationSpan.parentSpanID,
                                    stepNumber: currentIteration,
                                    state: .requestingPermission,
                                    content: "Waiting for user approval: \(action.toolName)"
                                ))
                                
                                // B. Suspend & Wait
                                let approved = await ExecutionSuspensionService.shared.suspend(for: input.conversationID)
                                
                                if !approved {
                                    logger.info("❌ [HITL] User DENIED permission for \(action.toolName)")
                                    
                                    // C. Handle Denial (Mock Failure)
                                    let denialObservation = "System Security: User explicitly denied permission to execute tool '\(action.toolName)'. Do not retry this exact action."
                                    scratchpad.append("Observation (Step \(currentIteration)): \(denialObservation)")
                                    
                                    continuation.yield(.toolOutput(ToolOutput(toolName: action.toolName, output: denialObservation, isSuccess: false)))
                                    
                                    // Skip actual execution loop
                                    continue cognitiveLoop
                                }
                                
                                logger.info("✅ [HITL] User APPROVED permission for \(action.toolName). Proceeding.")
                            }
                            
                            if let path = self.extractPath(from: action.parameters),
                               currentState.isPathForbidden(path) {
                                
                                let violationMsg = "🚫 GHOST PROTOCOL: Access to '\(path)' is FORBIDDEN by Negative Constraints. Do not retry this path."
                                scratchpad.append("System Alert: \(violationMsg)")
                                continuation.yield(.thought(violationMsg))
                                continue cognitiveLoop
                            }
                            
                            let paramsString = self.serializeParams(action.parameters)
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
                                    
                                    // Update fallback state
                                    lastKnownState = currentState
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
                            // Stop before yielding final answer
                            try Task.checkCancellation()
                            
                            if isMemoryEnabled && !hasUpdatedMemory {
                                logger.warning("Memory Guard Triggered: Agent attempted to exit without saving.")
                                continuation.yield(.thought("⚠️ Memory Guard Triggered: Enforcing save..."))
                                scratchpad.append("⚠️ SYSTEM INTERVENTION: Task appears complete, but session memory is not updated. \n\n1. DO NOT retry the task. \n2. You MUST fill the `memoryUpdate` OBJECT in your next response. \n3. Then provide the `finalAnswer` again.")
                                continue cognitiveLoop
                            }
                            
                            if let update = step.memoryUpdate, update.goalStatus.caseInsensitiveCompare("ACTIVE") == .orderedSame {
                                logger.warning("Agent finalized with ACTIVE status. Forcing COMPLETED.")
                                
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
                    
                    // [HITL] Clean up suspension if any
                    await ExecutionSuspensionService.shared.cancel(for: input.conversationID)
                    
                    // Persist the CANCELLED status so memory isn't stuck on ACTIVE
                    if var state = lastKnownState {
                        var wm = state.workingMemory
                        wm["last_status"] = "CANCELLED"
                        
                        let cancelledState = MutableActiveState(
                            sessionID: state.sessionID,
                            primaryGoal: state.primaryGoal,
                            subTasks: state.subTasks,
                            negativeConstraints: state.negativeConstraints,
                            workingMemory: wm
                        )
                        
                        ContextMemoryManager.shared.updateActiveState(
                            conversationID: input.conversationID,
                            state: cancelledState
                        )
                        
                        // Add an explicit log entry to history
                        ContextMemoryManager.shared.appendToHistory(
                            conversationID: input.conversationID,
                            content: "### 🛑 INTERRUPTED\n**Status:** CANCELLED\nUser manually stopped the execution."
                        )
                    }
                    
                    continuation.finish()
                } catch {
                    logger.error("ReAct Fatal Error: \(error.localizedDescription)")
                    
                    // [HITL] Clean up suspension
                    await ExecutionSuspensionService.shared.cancel(for: input.conversationID)
                    
                    continuation.finish(throwing: error)
                }
            }
            
            // Ensure stream termination kills the inner task
            continuation.onTermination = { @Sendable _ in
                task.cancel()
            }
        }
    }
    
    // MARK: - Error Helper (Phase 3)
    
    /// Robustly extracts the Retry-After time from various error formats.
    nonisolated private func extractRetryAfter(from error: Error, consecutiveRetries: Int) -> TimeInterval {
        // Default Exponential Backoff (Fallback)
        let fallback = pow(2.0, Double(min(consecutiveRetries, 6)))
        
        // Use NSError to check common userInfo keys for headers (Generic approach)
        let nsError = error as NSError
        
        // Check for common header keys used by Alamofire, URLSession, etc.
        let possibleKeys = ["headers", "HTTPHeaders", "com.alamofire.serialization.response.error.response.headers"]
        
        for key in possibleKeys {
            if let headers = nsError.userInfo[key] as? [AnyHashable: Any] {
                // Check both capitalization variants
                if let retryVal = headers["Retry-After"] as? String ?? headers["retry-after"] as? String {
                     if let val = parseRetryHeader(retryVal) { return val }
                }
            }
        }
        
        return fallback
    }
    
    nonisolated private func parseRetryHeader(_ value: String) -> TimeInterval? {
        // A. Try parsing as seconds
        if let seconds = TimeInterval(value) {
            return seconds
        }
        
        // B. Try parsing as HTTP Date (rare for 429, but possible)
        let formatter = DateFormatter()
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
        if let date = formatter.date(from: value) {
            return date.timeIntervalSinceNow
        }
        
        return nil
    }
    
    // MARK: - Optimization Helpers
    
    nonisolated private func pruneScratchpad(_ scratchpad: [String]) -> [String] {
        guard scratchpad.count > 4 else { return scratchpad }
        var pruned = [String]()
        if let first = scratchpad.first { pruned.append(first) }
        pruned.append("... [Intermediate steps summarized to save context] ...")
        let recent = scratchpad.suffix(3)
        pruned.append(contentsOf: recent)
        return pruned
    }
    
    // MARK: - Prompt Engineering (The Sandwich)
    
    nonisolated private func constructSandwichPrompt(
        input: AgentInput,
        scratchpad: [String],
        state: MutableActiveState,
        constraints: Set<String>,
        isFreshStart: Bool
    ) -> String {
        let layers = [
            buildPersonaLayer(input),
            buildEnvironmentLayer(),
            buildMemoryLayer(state, input.recentHistory, isFreshStart),
            buildReActStrategyLayer(constraints),
            buildContextLayer(input, scratchpad)
        ]
        return layers.filter { !$0.isEmpty }.joined(separator: "\n\n")
    }
    
    nonisolated private func buildEnvironmentLayer() -> String {
        let osVersion = ProcessInfo.processInfo.operatingSystemVersionString
        let userName = NSUserName()
        let date = Date().formatted(date: .numeric, time: .shortened)
        
        return """
        # ENVIRONMENT FACTS
        - OS: macOS \(osVersion)
        - Shell: Zsh (Non-Interactive Mode)
        - User: \(userName)
        - Date: \(date)
        """
    }
    
    nonisolated private func buildMemoryLayer(_ state: MutableActiveState, _ recentHistory: String?, _ isFreshStart: Bool) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let jsonState = (try? String(data: encoder.encode(state), encoding: .utf8)) ?? "{}"
        
        let history = recentHistory ?? "(No recent history)"
        let historyHeader = isFreshStart ? "## 📚 ARCHIVED LOGS (READ ONLY)" : "## 📜 RECENT ACTIVITY (Disk Tail)"
        let historyWarning = isFreshStart ? "(NOTE: These actions are from a previous turn. Do not resume them. Focus on Active Memory.)" : ""
        
        return """
        # TWIN-STORE MEMORY
        
        ## 🧠 ACTIVE MEMORY (RAM)
        This is your CURRENT brain state. Trust this over history.
        ```json
        \(jsonState)
        ```
        
        \(historyHeader)
        \(historyWarning)
        \(history)
        """
    }
    
    nonisolated private func buildReActStrategyLayer(_ constraints: Set<String>) -> String {
        var constraintBlock = ""
        if !constraints.isEmpty {
            constraintBlock = """
            ## 🚫 NEGATIVE CONSTRAINTS (GHOST PROTOCOL)
            FAILED PATHS:
            \(constraints.map { "- \($0)" }.joined(separator: "\n"))
            """
        }
        
        return """
        # COGNITIVE STRATEGY & MECHANICS
        ## PROTOCOL
        1. You operate in a Think -> Act -> Observe loop.
        2. You MUST output valid JSON conforming to the CognitiveStep schema.
        3. Analyze Active Memory before deciding your next move.
        4. If a path failed previously (Ghost Protocol), do NOT retry it.
        5. If a tool fails, **STOP** and reflect on the error before proceeding.
        6. **TASK COMPLETION**: If the goal is met or you need to reply to the user, you MUST set `action` to `null` and provide your response in the `finalAnswer` field. Do NOT hallucinate tools like 'none' or 'inform'.
        7. **CLARIFICATION**: If you need information from the user to proceed, use the `ask_user` tool: `{"toolName": "ask_user", "parameters": {"question": "Your question here"}}`. Do NOT invent tools like 'inform' or 'respond'. The ONLY way to talk to the user is via `finalAnswer` or `ask_user`.
        \(constraintBlock)
        """
    }
    
    nonisolated private func buildPersonaLayer(_ input: AgentInput) -> String {
        guard let instructions = input.instructions, !instructions.isEmpty else { return "" }
        return "# SYSTEM INSTRUCTIONS\n\(instructions)"
    }
    
    nonisolated private func buildContextLayer(_ input: AgentInput, _ scratchpad: [String]) -> String {
        var context = "# EXECUTION CONTEXT\n"
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
        totalCharacters += systemPrompt.count
        for msg in chatHistory {
            guard let text = msg.content.textContent else { continue }
            totalCharacters += text.count
        }
        return totalCharacters / 4
    }
    
    nonisolated private func extractPath(from params: [String: AnyCodable]) -> String? {
        if let val = params["path"] {
            let encoder = JSONEncoder()
            if let data = try? encoder.encode(val),
               let str = String(data: data, encoding: .utf8) {
                return str.trimmingCharacters(in: CharacterSet(charactersIn: "\""))
            }
        }
        return nil
    }
    
    nonisolated private func serializeParams(_ params: [String: AnyCodable]) -> String {
        let encoder = JSONEncoder()
        if let data = try? encoder.encode(params), let str = String(data: data, encoding: .utf8) {
            return str
        }
        return "{}"
    }
    
    nonisolated private func persistToVectorStore(log: String, conversationID: UUID) async {
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
    
    nonisolated private func buildMessages(systemPrompt: String, chatHistory: [ChatMessage]) -> [[String: String]] {
        var messages: [[String: String]] = []

        messages.append(["role": "system", "content": systemPrompt])

        for msg in chatHistory {
            guard let text = msg.content.textContent else { continue }
            if msg.sender == .user {
                messages.append(["role": "user", "content": "[USER]: \(text)"])
            } else {
                messages.append(["role": "assistant", "content": text])
            }
        }
        return messages
    }

    nonisolated private func formatJSONSchema(_ schema: ToolParameters) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        if let data = try? encoder.encode(schema), let str = String(data: data, encoding: .utf8) { return str }
        return "{}"
    }

    nonisolated private func handleMaxIterationsReached(
        model: any LLMProvider,
        scratchpad: [String],
        traceContext: TraceContext,
        continuation: AsyncThrowingStream<AgentStreamEvent, Error>.Continuation
    ) {
        continuation.yield(.content("⚠️ **Task Limit Reached**\n\nI've done my best, but hit the step limit."))
        continuation.finish()
    }
}

// MARK: - Debug Spy Model

private struct APISpyModel: LLMProvider {
    let inner: any LLMProvider
    let logger: Logger

    func generate(messages: [[String: String]], responseSchema: [String: Any]?) async throws -> String {
        return try await inner.generate(messages: messages, responseSchema: responseSchema)
    }

    func stream(messages: [[String: String]]) -> AsyncThrowingStream<String, Error> {
        return inner.stream(messages: messages)
    }
}
