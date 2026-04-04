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
                var sessionState: SessionGraph = input.activeState ?? SessionGraphStore.shared.getActiveState(for: input.conversationID)
                let currentConstraints = Set(sessionState.negativeConstraints)
                
                do {
                    logger.info("🚀 ReAct Execution Initiated. Model Instance: \(String(describing: model))")
                    
                    let spyModel = APISpyModel(inner: model)
                    
                    var currentIteration = 0
                    var latestClarification: String? = nil
                    var executionSummary = ExecutionSummary(originalGoal: input.userInput)
                    let executionTrace = input.traceContext
                    
                    var memoryStrategy = input.workingMemory
                    var circuitBreaker = CognitiveCircuitBreaker(
                        maxConsecutiveToolFailures: input.retryPolicy.maxRetries,
                        maxRepetitiveActions: input.retryPolicy.maxRetries
                    )
                    var retryStrategy = LLMRetryStrategy(
                        maxConsecutiveParseFailures: input.retryPolicy.maxRetries,
                        backoffStrategy: input.retryPolicy.backoffStrategy
                    )
                    let toolMediator = ToolExecutionMediator()
                    let terminationEvaluator = EpisodeTerminationEvaluator()
                    
                    // --- Start Episode ---
                    logState.info("New Top-Level Request Detected: Appending new MemoryEpisode.")
                    sessionState.episodes.append(MemoryEpisode(primaryGoal: input.userInput, status: "ACTIVE"))
                    sessionState.workingMemory.removeValue(forKey: "current_focus")
                    sessionState.workingMemory.removeValue(forKey: "last_status")
                    SessionGraphStore.shared.updateActiveState(conversationID: input.conversationID, state: sessionState)
                    
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
                                spanID: executionTrace.spanID,
                                parentSpanID: executionTrace.parentSpanID,
                                stepNumber: currentIteration,
                                state: .thinking(.reasoning),
                                content: waitMsg
                            ))
                        }
                        
                        await GlobalRateLimiter.shared.wait(for: input.rateLimitCategory)
                        
                        let iterationSpan = executionTrace.newSpan()
                        var iterationMetadata: [String: String] = ["iteration": "\(currentIteration)"]
                        
                        await TraceRecorder.shared.beginSpan(context: iterationSpan, name: "iteration_\(currentIteration)", kind: .iteration)
                        
                        defer {
                            Task { await TraceRecorder.shared.endSpan(spanID: iterationSpan.spanID, status: .completed) }
                        }
                        
                        // --- Build Context ---
                        let envFacts = EnvironmentFacts(
                            osVersion: ProcessInfo.processInfo.operatingSystemVersionString,
                            shellType: "Zsh (Non-Interactive Mode)",
                            userName: NSUserName(),
                            currentDate: Date().formatted(date: .numeric, time: .shortened)
                        )
                        
                        // Read User Personal profile for prompt injection (first iteration only to save tokens)
                        let userProfile: String? = currentIteration == 1
                            ? await MainActor.run {
                                guard UserDefaults.standard.bool(forKey: AppSettings.ciFeatureUserPersonalKey) else { return nil }
                                return UserPersonalService.shared.getProfileForInjection()
                            }
                            : nil

                        let context = SemanticContext(
                            instructions: input.instructions,
                            environmentFacts: envFacts,
                            longTermMemory: input.longTermMemory,
                            recentHistory: input.recentHistory,
                            originalQuery: input.userInput,
                            currentIteration: currentIteration,
                            compiledScratchpad: memoryStrategy.compileForPrompt(),
                            latestClarification: latestClarification,
                            negativeConstraints: currentConstraints,
                            hallucinatedTools: circuitBreaker.hallucinatedTools,
                            availableTools: input.tools,
                            userProfile: userProfile
                        )
                        
                        try Task.checkCancellation()

                        // --- Structured Generation ---
                        let step: ModernCognitiveStep
                        do {
                            logger.info("⚡️ Invoking Strategy.generate (Attempt: \(retryStrategy.consecutiveRetries + 1))")
                            
                            // --- ENHANCED VISIBILITY LOGGING ---
                            logger.notice("--- COGNITIVE STEP [ITERATION \(currentIteration)] ---")
                            logger.info("🤖 Active Model: \(model.modelName)")
                            logger.info("🧠 Generator Strategy: \(String(describing: type(of: input.generatorStrategy)))")
                            
                            logger.info("🧠 Generator Strategy: \(String(describing: type(of: input.generatorStrategy)))")
                            
                            logger.info("📝 Compiled Scratchpad Length: \(memoryStrategy.compileForPrompt().count) chars.")
                            
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
                                memoryStrategy.recordSystemAlert(msg: systemAlert)
                                continuation.yield(.thought("⚠️ Error: Invalid JSON output. Retrying (\(attemptCount)/\(maxAttempts))..."))
                                await GlobalRateLimiter.shared.wait(for: input.rateLimitCategory)
                                continue cognitiveLoop

                            case .modelReload(let message):
                                continuation.yield(.thought(message))
                                let reloaded = await MLXService.shared.reloadCurrentModel()
                                if !reloaded {
                                    continuation.yield(.content("The model was unloaded and could not be reloaded automatically. Please try again."))
                                    continuation.finish()
                                    return
                                }
                                currentIteration -= 1 // Don't count reload as an iteration
                                continue cognitiveLoop

                            case .abort(let reason):
                                sessionState.closeActiveEpisode(status: "FAILED", outcome: reason)
                                SessionGraphStore.shared.updateActiveState(conversationID: input.conversationID, state: sessionState)
                                logState.info("💾 Auto-Patched Active Episode to: FAILED")
                                continuation.yield(.content(reason))
                                continuation.finish()
                                return
                            }
                        }
                        
                        // --- Pre-Execution Setup ---
                        // [Memory Refactor] Flags are now handled by the strategy logic if needed.
                        
                        // Yield the internal thought trace if the provider extracted one (e.g., Native Thinking)
                        if let thought = step.thought, !thought.isEmpty {
                            continuation.yield(.thought("Step \(currentIteration) — \(thought)"))
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
                            memoryStrategy.recordSystemAlert(msg: alert)
                            continuation.yield(.thought("⚠️ Format correction: model described tool intent without structured output. Retrying..."))
                            logger.warning("🔄 Suspected format failure. Injecting corrective alert and retrying iteration \(currentIteration).")
                            continue cognitiveLoop
                        case .proceed:
                            break
                        }

                        if step.toolCalls.isEmpty { break cognitiveLoop }

                        // 3. ACTING & OBSERVING PHASE (Shared Parallel Execution)
                        let observations = try await executeToolCalls(
                            toolCalls: step.toolCalls,
                            availableTools: input.tools,
                            conversationID: input.conversationID,
                            currentIteration: currentIteration,
                            iterationSpan: iterationSpan,
                            toolMediator: toolMediator,
                            continuation: continuation,
                            onTraceUpdate: onTraceUpdate
                        )
                        
                        // Commit observations to memory strategy
                        for obs in observations {
                            memoryStrategy.recordObservation(stepId: obs.stepId, toolCallId: obs.toolCallId, toolName: obs.toolName, result: obs.result, artifacts: obs.artifacts)
                        }

                        var shouldAbort = false
                        var abortReason = ""

                        for obs in observations {
                            let isSuccess = obs.isSuccess
                            executionSummary.record(toolCallId: obs.toolCallId, toolName: obs.toolName, params: obs.params, output: obs.output, isSuccess: isSuccess)
                            
                            let resultAction = circuitBreaker.recordToolResult(isSuccess: isSuccess)
                            if case .abort(let reason) = resultAction {
                                shouldAbort = true
                                abortReason = reason
                            }
                            
                            if !isSuccess {
                                circuitBreaker.recordHallucination(obs.toolName)
                            }
                        }
                        
                        // --- Repetitive Action Loop Detection ---
                        // Check if this iteration's observations are identical to previous ones.
                        // Catches "successful but useless" loops (e.g., same tool with empty args returning same result).
                        let repetitiveAction = circuitBreaker.evaluateRepetitiveActions(observations)
                        if case .abort(let reason) = repetitiveAction {
                            shouldAbort = true
                            abortReason = reason
                        }

                        if shouldAbort {
                            executionSummary.markComplete(failureReason: abortReason)
                            continuation.yield(.thought("⚠️ Circuit breaker triggered — recovering…"))
                            let response = await ResponseSynthesizer.synthesize(summary: executionSummary, model: model, personaInstructions: input.instructions, originalQuery: input.userInput)
                            sessionState.closeActiveEpisode(status: "FAILED", outcome: response)
                            SessionGraphStore.shared.updateActiveState(conversationID: input.conversationID, state: sessionState)
                            logState.info("💾 Auto-Patched Active Episode to: FAILED")
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

                    // --- UI Progress: Synthesis ---
                    continuation.yield(.thought("Composing final response…"))

                    let response = await ResponseSynthesizer.synthesize(
                        summary: executionSummary,
                        model: model,
                        personaInstructions: input.instructions,
                        originalQuery: input.userInput,
                        isNativeFlow: input.generatorStrategy is NativeStructuredGenerator
                    )

                    sessionState.closeActiveEpisode(status: exitStatus, outcome: response)
                    SessionGraphStore.shared.updateActiveState(conversationID: input.conversationID, state: sessionState)
                    logState.info("💾 Auto-Patched Active Episode to: \(exitStatus)")
                    
                    onTraceUpdate(AgentTraceLog(
                        traceID: input.traceContext.traceID,
                        spanID: input.traceContext.spanID,
                        parentSpanID: input.traceContext.parentSpanID,
                        stepNumber: currentIteration,
                        state: .thinking(.finalizing),
                        content: exitStatus == "COMPLETED" ? "Task completed successfully." : "Task failed or reached max iterations."
                    ))
                    
                    logger.info("--- 🏁 REACT EXECUTION COMPLETE 🏁 ---")
                    logger.info("Model: \(model.modelName)")
                    logger.info("Final Synthesized Response: \(response)")
                    logger.info("--------------------------------------")

                    continuation.yield(.content(response))
                    continuation.finish()
                    
                } catch is CancellationError {
                    logger.notice("🚫 Execution Task Cancelled cleanly.")
                    await ExecutionSuspensionService.shared.cancel(for: input.conversationID)
                    sessionState.cancelActiveEpisode()
                    SessionGraphStore.shared.updateActiveState(conversationID: input.conversationID, state: sessionState)
                    continuation.yield(.thought("Cancelled by user."))
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
    
}

