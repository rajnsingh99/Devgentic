//
//  ReActAgentExecutor.swift
//  Devgentic
//
//  Created by Raj Singh on 28/01/26.
//  Updated: Phase 5 - Modular Orchestrator Refactoring & Memory Pointers
//

import Foundation
import OSLog

private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "com.devgentic.app", category: "ReActExecutor")
private let logState = Logger(subsystem: Bundle.main.bundleIdentifier ?? "com.devgentic.app", category: "State")
private let logToolExecution = Logger(subsystem: Bundle.main.bundleIdentifier ?? "com.devgentic.app", category: "ToolExecution")

// MARK: - Executor Implementation

/// A robust implementation of the ReAct (Reasoning + Acting) paradigm.
/// Features a Split-State architecture (RAM vs. Disk) and structured cognitive steps.
/// This acts as a pure Orchestrator, delegating state, safety, and execution to pluggable components.
actor ReActAgentExecutor: Executor {
    
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
        
        return AsyncThrowingStream(AgentStreamEvent.self) { continuation in
            let task = Task {
                
                // --- Phase 2: State Component ---
                // Initialized here so it is accessible in the cancellation/catch blocks
                var stateMutator = EpisodeStateMutator(conversationID: input.conversationID, initialState: input.activeState)
                
                do {
                    logger.info("🚀 ReAct Execution Initiated. Model Instance: \(String(describing: model))")
                    
                    let spyModel = APISpyModel(inner: model, logger: logger)
                    
                    var currentIteration = 0
                    var latestClarification: String? = nil
                    var executionSummary = ExecutionSummary(originalGoal: input.userInput)
                    let executionTrace = input.traceContext
                    
                    // --- Load Pluggable Components (Phases 2-4) ---
                    var memoryStore = ObservationMemoryStore()
                    var circuitBreaker = CognitiveCircuitBreaker()
                    var retryStrategy = LLMRetryStrategy()
                    let toolMediator = ToolExecutionMediator()
                    let terminationEvaluator = EpisodeTerminationEvaluator()
                    
                    // --- Start Episode ---
                    stateMutator.startNewEpisode(goal: input.userInput)
                    
                    // MARK: - Cognitive Loop
                    cognitiveLoop: while currentIteration < self.maxIterations {
                        try Task.checkCancellation()
                        currentIteration += 1
                        
                        // --- Rate Limit Check ---
                        let projectedWait = await GlobalRateLimiter.shared.timeUntilNextToken(for: input.rateLimitCategory)
                        if projectedWait > 1.5 {
                            logger.warning("Rate limit approaching. Throttling for \(Int(projectedWait))s.")
                            let waitMsg = "Throttling for \(Int(projectedWait))s to respect \(input.rateLimitCategory) limits..."
                            continuation.yield(.thought(waitMsg))
                            let traceHandler: (AgentTraceLog) -> Void = { log in
                        logger.info("[AGENT-TRACE] Step \(log.stepNumber) (\(log.state.headline)): \(log.content) (span: \(log.spanID))")
                            }
                            onTraceUpdate(AgentTraceLog(
                                traceID: executionTrace.traceID,
                                spanID: executionTrace.newSpan().spanID,
                                parentSpanID: executionTrace.parentSpanID,
                                stepNumber: currentIteration,
                                state: .thinking(.reasoning),
                                content: waitMsg
                            ))
                        }
                        
                        await GlobalRateLimiter.shared.wait(for: input.rateLimitCategory)
                        
                        let iterationSpan = executionTrace.newSpan()
                        var iterationMetadata: [String: String] = ["iteration": "\(currentIteration)"]
                        
                        // --- Build Context ---
                        let envFacts = EnvironmentFacts(
                            osVersion: ProcessInfo.processInfo.operatingSystemVersionString,
                            shellType: "Zsh (Non-Interactive Mode)",
                            userName: NSUserName(),
                            currentDate: Date().formatted(date: .numeric, time: .shortened)
                        )
                        
                        let context = SemanticContext(
                            instructions: input.instructions,
                            environmentFacts: envFacts,
                            compressedStateGraph: stateMutator.currentState.compressWithPointers(windowSize: 5),
                            recentHistory: input.recentHistory,
                            originalQuery: input.userInput,
                            currentIteration: currentIteration,
                            activeObservations: memoryStore.activeObservations,
                            latestClarification: latestClarification,
                            negativeConstraints: stateMutator.currentConstraints,
                            hallucinatedTools: circuitBreaker.hallucinatedTools,
                            availableTools: input.tools
                        )
                        
                        logState.debug("SemanticContext Assembled. Compressed Graph Length: \(context.compressedStateGraph.count) chars.")
                        
                        try Task.checkCancellation()

                        // --- Structured Generation ---
                        let step: ModernCognitiveStep
                        do {
                            logger.info("⚡️ Invoking Strategy.generate (Attempt: \(retryStrategy.consecutiveRetries + 1))")
                            
                            // --- ENHANCED VISIBILITY LOGGING ---
                            logger.notice("--- COGNITIVE STEP [ITERATION \(currentIteration)] ---")
                            logger.info("🤖 Active Model: \(model.modelName)")
                            logger.info("🧠 Generator Strategy: \(String(describing: type(of: input.generatorStrategy)))")
                            
                            if context.activeObservations.isEmpty {
                                logger.info("📝 Scratchpad: (Empty)")
                            } else {
                                logger.info("📝 Scratchpad (\(context.activeObservations.count) items):")
                                for obs in context.activeObservations {
                                    let status = obs.isRequired ? "REQUIRED" : "HYDRATED"
                                    logger.info("   - [\(obs.toolName)] (\(status)): \(obs.shortObservation)")
                                }
                            }
                            
                            step = try await input.generatorStrategy.generateCognitiveStep(
                                model: spyModel,
                                context: context,
                                iteration: currentIteration
                            )
                            
                            logger.info("📄 Model Reasoning: \(step.reasoning)")
                            if step.toolCalls.isEmpty {
                                logger.info("🛑 No tool calls produced.")
                            } else {
                                logger.info("🛠️ Produced \(step.toolCalls.count) Tool Calls: \(step.toolCalls.map { $0.name }.joined(separator: ", "))")
                            }
                            
                            retryStrategy.resetParseFailures()
                            
                        } catch {
                            // --- Error Retry Handling ---
                            let action = retryStrategy.handleError(error)
                            switch action {
                            case .throttle(let seconds, let message):
                                await GlobalRateLimiter.shared.drainAndPenalize(category: input.rateLimitCategory, penaltySeconds: seconds)
                                continuation.yield(.thought(message))
                                try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
                                currentIteration -= 1
                                continue cognitiveLoop
                                
                            case .networkRetry(let message):
                                continuation.yield(.thought(message))
                                currentIteration -= 1
                                continue cognitiveLoop
                                
                            case .parseRetry(let systemAlert, let attemptCount, let maxAttempts):
                                memoryStore.addSystemAlert(systemAlert, currentIteration: currentIteration)
                                continuation.yield(.thought("⚠️ Error: Invalid JSON output. Retrying (\(attemptCount)/\(maxAttempts))..."))
                                await GlobalRateLimiter.shared.wait(for: input.rateLimitCategory)
                                continue cognitiveLoop
                                
                            case .abort(let reason):
                                stateMutator.forceCloseActiveEpisode(status: "FAILED", outcome: reason)
                                continuation.yield(.content(reason))
                                continuation.finish()
                                return
                            }
                        }
                        
                        // --- Pre-Execution Setup ---
                        memoryStore.resetObservationFlags()
                        
                        // Yield the internal thought trace if the provider extracted one (e.g., Native Thinking)
                        if let thought = step.thought, !thought.isEmpty {
                            continuation.yield(.thought(thought))
                        }
                        
                        // Yield the assistant monologue/reasoning text
                        // (Avoid yielding redundant text if thought and reasoning are identical)
                        if !step.reasoning.isEmpty && step.reasoning != step.thought {
                            continuation.yield(.thought(step.reasoning))
                        }
                        
                        // --- Termination Evaluation (Phase 4 Component) ---
                        let termStatus = terminationEvaluator.evaluate(step: step, currentIteration: currentIteration, maxIterations: self.maxIterations)
                        switch termStatus {
                        case .maxIterationsReached:
                            break
                        case .completed(let finalThought):
                            executionSummary.finalAgentThought = finalThought
                            break cognitiveLoop
                        case .suspectedFormatFailure:
                            // The LLM described tool usage in prose but didn't produce structured tool calls.
                            // Inject a corrective system alert and retry the generation.
                            let alert = "CRITICAL: Your last response described tool usage in plain text but did not include a structured tool call. You MUST respond with a valid JSON object containing a `tool_calls` array. Do NOT describe tool calls in prose — actually invoke them."
                            memoryStore.addSystemAlert(alert, currentIteration: currentIteration)
                            continuation.yield(.thought("⚠️ Format correction: model described tool intent without structured output. Retrying..."))
                            logger.warning("🔄 Suspected format failure. Injecting corrective alert and retrying iteration \(currentIteration).")
                            continue cognitiveLoop
                        case .proceed:
                            break
                        }

                        if step.toolCalls.isEmpty { break cognitiveLoop }

                        // --- PREVENT DUPLICATE TOOL CALLS ---
                        var uniqueToolCalls: [PendingToolCall] = []
                        var seenSignatures = Set<String>()
                        
                        for tool in step.toolCalls {
                            let signature = "\(tool.name)|\(self.serializeParams(tool.arguments))"
                            if !seenSignatures.contains(signature) {
                                seenSignatures.insert(signature)
                                uniqueToolCalls.append(tool)
                            } else {
                                logger.warning("⚠️ Dropped duplicate parallel tool call: \(tool.name) with args: \(signature)")
                                logToolExecution.warning("Duplicate tool blocked: \(tool.name)")
                            }
                        }
                        
                        logToolExecution.info("Agent requested \(step.toolCalls.count) total tools. Deduped to \(uniqueToolCalls.count) unique tools.")

                        onTraceUpdate(AgentTraceLog(
                            traceID: iterationSpan.traceID,
                            spanID: iterationSpan.spanID,
                            parentSpanID: iterationSpan.parentSpanID,
                            stepNumber: currentIteration,
                            state: .thinking(.reasoning),
                            content: "Analyzing \((uniqueToolCalls.count)) tools...",
                            metadata: iterationMetadata
                        ))
                        
                        // 3. ACTING & OBSERVING PHASE (Parallel Execution)
                        var observations: [CognitiveObservation] = []
                        
                        // Use a TaskGroup to execute multiple tools simultaneously
                        try await withThrowingTaskGroup(of: CognitiveObservation.self) { group in
                            for tool in uniqueToolCalls {
                                group.addTask {
                                    let toolName = tool.name
                                    let arguments = tool.arguments
                                    let paramsString = self.serializeParams(arguments)
                                    
                                    // Emit UI Event for this specific tool
                                    continuation.yield(.toolCall(name: toolName, params: paramsString))
                                    
                                    // Emit Trace Event for Monitoring/Analytics
                                    onTraceUpdate(AgentTraceLog(
                                        traceID: iterationSpan.traceID,
                                        spanID: iterationSpan.spanID,
                                        parentSpanID: iterationSpan.parentSpanID,
                                        stepNumber: currentIteration,
                                        state: .acting(.tool(name: toolName)),
                                        content: "Executing '\(toolName)'...",
                                        metadata: ["tool_name": toolName]
                                    ))
                                    
                                    // PATCH: Explicitly intercept "ask_user" before it hits normal dispatch
                                    if toolName == "ask_user" {
                                        let question = (arguments["question"]?.value as? String) ?? "Please provide clarification to proceed."
                                        
                                        // Yield the stream event so ActiveStreamManager can show the UI Input Card
                                        continuation.yield(.requestClarification(question: question))
                                        
                                        // Suspend the execution loop and wait for the user's STRING response
                                        // Note: Adjust 'suspendForClarification' if your service uses a different method name
                                        let userResponse = await ExecutionSuspensionService.shared.suspendForClarification(for: input.conversationID)
                                        
                                        let answerText = userResponse ?? "System: The user did not respond or the request timed out."
                                        
                                        return CognitiveObservation(
                                            stepId: currentIteration,
                                            toolName: toolName,
                                            shortObservation: "User Response: \(answerText)",
                                            heavyContent: nil,
                                            isRequired: false,
                                            metadata: nil
                                        )
                                    }
                                    
                                    // Dispatch and Execute the Tool (handles HITL safely within the task)
                                    let dispatchOutcome = toolMediator.prepareDispatch(
                                        toolName: toolName,
                                        arguments: arguments,
                                        availableTools: input.tools
                                    )
                                    
                                    switch dispatchOutcome {
                                    case .requiresConfirmation(let ps):
                                        continuation.yield(.requestConfirmation(toolName: toolName, params: ps))
                                        let approved = await ExecutionSuspensionService.shared.suspend(for: input.conversationID)
                                        if !approved {
                                            let denialResult = ToolExecutionResult.userDenied(toolName: toolName)
                                            continuation.yield(.toolOutput(ToolOutput(toolName: toolName, output: denialResult.llmObservation, isSuccess: false)))
                                            return CognitiveObservation(
                                                stepId: currentIteration,
                                                toolName: toolName,
                                                shortObservation: denialResult.llmObservation,
                                                heavyContent: nil,
                                                isRequired: false,
                                                metadata: nil
                                            )
                                        }
                                    case .executed, .userDenied:
                                        break
                                    }
                                    
                                    let result = await toolMediator.executePreparedTool(
                                        toolName: toolName,
                                        arguments: arguments,
                                        availableTools: input.tools,
                                        parentContext: iterationSpan
                                    )
                                    
                                    // Emit UI Output for this specific tool
                                    continuation.yield(.toolOutput(ToolOutput(toolName: toolName, output: result.llmObservation, isSuccess: result.isSuccess)))
                                    
                                    // Emit Trace Observation for EvaluationLogger
                                    onTraceUpdate(AgentTraceLog(
                                        traceID: iterationSpan.traceID,
                                        spanID: iterationSpan.spanID,
                                        parentSpanID: iterationSpan.parentSpanID,
                                        stepNumber: currentIteration,
                                        state: .thinking(.reflecting),
                                        content: result.isSuccess ? "Tool '\(toolName)' succeeded." : "Tool '\(toolName)' failed.",
                                        metadata: [
                                            "tool_name": toolName,
                                            "is_success": "\(result.isSuccess)",
                                            "tool_params": paramsString,
                                            "tool_output": result.llmObservation
                                        ]
                                    ))
                                    
                                    return CognitiveObservation(
                                        stepId: currentIteration,
                                        toolName: toolName,
                                        shortObservation: result.isSuccess ? "Tool '\(toolName)' executed successfully." : "Tool '\(toolName)' failed: \(result.llmObservation)",
                                        heavyContent: result.isSuccess ? nil : result.llmObservation,
                                        isRequired: !result.isSuccess,
                                        metadata: [
                                            "tool_name": AnyCodable(toolName),
                                            "tool_success": AnyCodable(String(result.isSuccess)),
                                            "tool_params": AnyCodable(paramsString),
                                            "tool_output": AnyCodable(result.llmObservation)
                                        ]
                                    )
                                }
                            }
                            
                            // Collect all parallel observations
                            for try await observation in group {
                                observations.append(observation)
                            }
                        }
                        
                        let outcomesOverview = observations.map { "[\($0.toolName): \($0.shortObservation)]" }.joined(separator: ", ")
                        logToolExecution.debug("Agent evaluated \(observations.count) parallel outcomes: \(outcomesOverview)")
                        
                        // Commit observations to memory and handle side-effects sequentially
                        memoryStore.addObservations(observations)
                        
                        var shouldAbort = false
                        var abortReason = ""
                        
                        for obs in observations {
                            let isSuccess = !obs.isRequired
                            let params = obs.metadata?["tool_params"] as? String ?? "n/a"
                            let output = obs.metadata?["tool_output"] as? String ?? obs.shortObservation
                            executionSummary.record(toolName: obs.toolName, params: params, output: output, isSuccess: isSuccess)
                            
                            let resultAction = circuitBreaker.recordToolResult(isSuccess: isSuccess)
                            if case .abort(let reason) = resultAction {
                                shouldAbort = true
                                abortReason = reason
                            }
                            
                            if !isSuccess {
                                circuitBreaker.recordHallucination(obs.toolName)
                            }
                        }
                        
                        if shouldAbort {
                            executionSummary.markComplete(failureReason: abortReason)
                            let response = await ResponseSynthesizer.synthesize(summary: executionSummary, model: model, personaInstructions: input.instructions, originalQuery: input.userInput)
                            stateMutator.forceCloseActiveEpisode(status: "FAILED", outcome: response)
                            continuation.yield(.content(response))
                            continuation.finish()
                            return
                        }
                        
                        circuitBreaker.resetCountersOnSuccess()
                        
                        onTraceUpdate(AgentTraceLog(
                            traceID: iterationSpan.traceID,
                            spanID: iterationSpan.spanID,
                            parentSpanID: iterationSpan.parentSpanID,
                            stepNumber: currentIteration,
                            state: .thinking(.reflecting),
                            content: "Observed \(observations.count) tools natively executed.",
                            metadata: iterationMetadata
                        ))
                        
                    } // End While Loop
                    
                    // --- Post-Loop Handoff ---
                    let exitStatus = (currentIteration >= self.maxIterations) ? "FAILED" : "COMPLETED"
                    
                    if exitStatus == "FAILED" {
                        executionSummary.markComplete(failureReason: "Reached maximum allowed steps (\(maxIterations)) without completion.")
                    } else {
                        executionSummary.markComplete()
                    }

                    let response = await ResponseSynthesizer.synthesize(
                        summary: executionSummary,
                        model: model,
                        personaInstructions: input.instructions,
                        originalQuery: input.userInput,
                        isNativeFlow: input.generatorStrategy is NativeStructuredStrategy
                    )
                    
                    stateMutator.forceCloseActiveEpisode(status: exitStatus, outcome: response)
                    
                    let finalSpan = input.traceContext.newSpan()
                    onTraceUpdate(AgentTraceLog(
                        traceID: finalSpan.traceID,
                        spanID: finalSpan.spanID,
                        parentSpanID: finalSpan.parentSpanID,
                        stepNumber: currentIteration,
                        state: .thinking(.finalizing),
                        content: exitStatus == "COMPLETED" ? "Task completed successfully." : "Task failed or reached max iterations."
                    ))
                    
                    continuation.yield(.content(response))
                    continuation.finish()
                    
                } catch is CancellationError {
                    logger.notice("🚫 Execution Task Cancelled cleanly.")
                    await ExecutionSuspensionService.shared.cancel(for: input.conversationID)
                    stateMutator.markAsCancelled()
                    continuation.finish()
                } catch {
                    logger.error("ReAct Fatal Error: \(error.localizedDescription)")
                    await ExecutionSuspensionService.shared.cancel(for: input.conversationID)
                    continuation.finish(throwing: error)
                }
            }
            
            continuation.onTermination = { @Sendable _ in task.cancel() }
        }
    }
    
    // MARK: - Local Helpers
    
    nonisolated private func serializeParams(_ params: [String: AnyCodable]) -> String {
        if let data = try? JSONEncoder().encode(params), let str = String(data: data, encoding: .utf8) { return str }
        return "{}"
    }
    
    nonisolated private func extractPath(from params: [String: AnyCodable]) -> String? {
        if let val = params["path"],
           let data = try? JSONEncoder().encode(val),
           let str = String(data: data, encoding: .utf8) {
            return str.trimmingCharacters(in: CharacterSet(charactersIn: "\""))
        }
        return nil
    }
}

// MARK: - Internal Models

private struct APISpyModel: LLMProvider {
    let inner: any LLMProvider
    let logger: Logger
    
    var modelName: String { inner.modelName }

    func generate(messages: [[String: String]], tools: [[String: Any]]?, responseSchema: Any?) async throws -> String {
        return try await inner.generate(messages: messages, tools: tools, responseSchema: responseSchema)
    }

    func stream(messages: [[String: String]], tools: [[String: Any]]?) -> AsyncThrowingStream<String, Error> {
        return inner.stream(messages: messages, tools: tools)
    }

    func generateCognitiveStep(messages: [[String: String]], tools: [[String: Any]]?) async throws -> ModernCognitiveStep {
        return try await inner.generateCognitiveStep(messages: messages, tools: tools)
    }
}
