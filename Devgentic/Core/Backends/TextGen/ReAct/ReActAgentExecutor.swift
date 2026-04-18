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
    
    nonisolated let executorLabel: String = "ReAct"
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
                var sessionState: SessionGraph
                if let activeState = input.activeState {
                    sessionState = activeState
                } else {
                    sessionState = await SessionGraphStore.shared.getActiveState(for: input.conversationID)
                }
                let currentConstraints = Set(sessionState.negativeConstraints)
                
                do {
                    logger.info("🚀 ReAct Execution Initiated. Model Instance: \(String(describing: model))")
                    
                    let spyModel = APISpyModel(inner: model)
                    
                    var currentIteration = 0
                    var latestClarification: ClarificationContext? = nil
                    var accumulatedTokenUsage = TokenUsage()
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
                    // [G3/G5] When wrapped by a capability (Planning, Reflexion), the wrapper
                    // owns the episode lifecycle. Skip to avoid N+1 duplicate episodes.
                    if !input.suppressEpisodeManagement {
                        logState.info("New Top-Level Request Detected: Appending new MemoryEpisode.")
                        sessionState.episodes.append(MemoryEpisode(primaryGoal: input.userInput, status: "ACTIVE"))
                        sessionState.workingMemory.removeValue(forKey: "current_focus")
                        sessionState.workingMemory.removeValue(forKey: "last_status")
                        await SessionGraphStore.shared.updateActiveState(conversationID: input.conversationID, state: sessionState)
                    }
                    
                    // MARK: - Cognitive Loop
                    cognitiveLoop: while currentIteration < self.maxIterations {
                        try Task.checkCancellation()
                        currentIteration += 1
                        
                        // --- Rate Limit Check ---
                        let projectedWait = await GlobalRateLimiter.shared.timeUntilNextToken(forKey: input.rateLimitKey, category: input.rateLimitCategory)
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
                        
                        await GlobalRateLimiter.shared.wait(forKey: input.rateLimitKey, category: input.rateLimitCategory)
                        
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
                        
                        // Read User Personal profile for prompt injection (first iteration only to save tokens).
                        // Suppressed in workflow mode — workflow nodes operate on task+input, not personal context.
                        let userProfile: String?
                        if input.workflowContext == nil, currentIteration == 1 {
                            userProfile = await MainActor.run {
                                guard UserDefaults.standard.bool(forKey: AppSettings.ciFeatureUserPersonalKey) else { return nil }
                                return UserPersonalService.shared.getProfileForInjection()
                            }
                        } else {
                            userProfile = nil
                        }

                        let context = SemanticContext(
                            instructions: input.instructions,
                            environmentFacts: envFacts,
                            longTermMemory: input.longTermMemory,
                            recentHistory: input.recentHistory,
                            nativeHistoryTurns: input.nativeHistoryTurns,
                            originalQuery: input.userInput,
                            currentIteration: currentIteration,
                            compiledScratchpad: memoryStrategy.compileForPrompt(),
                            latestClarification: latestClarification,
                            negativeConstraints: currentConstraints,
                            hallucinatedTools: circuitBreaker.hallucinatedTools,
                            availableTools: input.tools,
                            userProfile: userProfile,
                            skillManifests: input.skillManifests,
                            taskDescription: input.workflowContext?.taskDescription,
                            promptLayerConfig: input.workflowContext != nil ? .workflow : .agent
                        )
                        
                        try Task.checkCancellation()

                        // --- Memory Pressure Check ---
                        let utilization = memoryStrategy.budgetUtilization
                        if utilization > 0.75 {
                            let pct = Int(utilization * 100)
                            let message = utilization >= 1.0
                                ? "Memory pressure: \(pct)% of scratchpad budget used — older observations are being evicted."
                                : "Memory pressure: \(pct)% of scratchpad budget used."
                            logger.warning("⚠️ \(message)")
                            continuation.yield(.warning(category: .memoryPressure, message: message))

                            // Proactive throttling: when budget is fully exhausted, nudge the
                            // model toward synthesis rather than continued exploration.
                            // This is a soft signal — the agent can still call tools if needed.
                            if utilization >= 1.0 {
                                memoryStrategy.recordSystemAlert(
                                    msg: "Working memory is full. Older observations have been evicted. "
                                       + "Prioritize synthesizing a final answer from available context "
                                       + "rather than calling additional tools."
                                )
                            }
                        }

                        // --- Structured Generation ---
                        let step: ModernCognitiveStep
                        do {
                            logger.info("⚡️ Invoking Strategy.generate (Attempt: \(retryStrategy.consecutiveRetries + 1))")

                            // --- ENHANCED VISIBILITY LOGGING ---
                            logger.notice("--- COGNITIVE STEP [ITERATION \(currentIteration)] ---")
                            logger.info("🤖 Active Model: \(model.modelName)")
                            logger.info("🧠 Generator Strategy: \(String(describing: type(of: input.generatorStrategy)))")

                            logger.info("📝 Compiled Scratchpad Length: \(context.compiledScratchpad.count) chars. Budget utilization: \(String(format: "%.0f", utilization * 100))%.")
                            
                            step = try await input.generatorStrategy.generateCognitiveStep(
                                model: spyModel,
                                context: context,
                                iteration: currentIteration
                            )
                            
                            // Accumulate token usage from this cognitive step
                            if let usage = step.tokenUsage {
                                accumulatedTokenUsage.accumulate(usage)
                            }

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
                                await GlobalRateLimiter.shared.drainAndPenalize(key: input.rateLimitKey, category: input.rateLimitCategory, penaltySeconds: seconds)
                                continuation.yield(.warning(category: .throttle, message: message))
                                try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
                                currentIteration -= 1
                                continue cognitiveLoop

                            case .networkRetry(let message):
                                continuation.yield(.warning(category: .retry, message: message))
                                currentIteration -= 1
                                continue cognitiveLoop

                            case .parseRetry(let systemAlert, let attemptCount, let maxAttempts):
                                memoryStrategy.recordSystemAlert(msg: systemAlert)
                                continuation.yield(.warning(category: .parseFailure, message: "Invalid JSON output. Retrying (\(attemptCount)/\(maxAttempts))..."))
                                await GlobalRateLimiter.shared.wait(forKey: input.rateLimitKey, category: input.rateLimitCategory)
                                continue cognitiveLoop

                            case .modelReload(let message):
                                continuation.yield(.warning(category: .retry, message: message))
                                let reloaded = await MLXService.shared.reloadCurrentModel()
                                if !reloaded {
                                    continuation.yield(.content("The model was unloaded and could not be reloaded automatically. Please try again."))
                                    continuation.yield(.executionFinished(outcome: .failed, reason: "Model reload failed"))
                                    continuation.finish()
                                    return
                                }
                                currentIteration -= 1 // Don't count reload as an iteration
                                continue cognitiveLoop

                            case .abort(let reason):
                                if !input.suppressEpisodeManagement {
                                    sessionState.closeActiveEpisode(status: "FAILED", outcome: reason)
                                    await SessionGraphStore.shared.updateActiveState(conversationID: input.conversationID, state: sessionState)
                                    logState.info("💾 Auto-Patched Active Episode to: FAILED")
                                }
                                continuation.yield(.content(reason))
                                continuation.yield(.executionFinished(outcome: .failed, reason: reason))
                                continuation.finish()
                                return
                            }
                        }
                        
                        // --- Pre-Execution Setup ---
                        // [Memory Refactor] Flags are now handled by the strategy logic if needed.
                        
                        // Yield the internal thought trace if the provider extracted one (e.g., Native Thinking)
                        if let thought = step.thought, !thought.isEmpty {
                            let sanitized = OutputSanitizer.sanitizeForUI(thought)
                            if !sanitized.isEmpty {
                                continuation.yield(.thought("Step \(currentIteration) — \(sanitized)"))
                            }
                        }

                        // Yield the assistant monologue/reasoning text
                        // (Avoid yielding redundant text if thought and reasoning are identical)
                        if !step.reasoning.isEmpty && step.reasoning != step.thought {
                            let sanitized = OutputSanitizer.sanitizeForUI(step.reasoning)
                            if !sanitized.isEmpty {
                                continuation.yield(.thought(sanitized))
                            }
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
                            continuation.yield(.warning(category: .formatCorrection, message: "Format correction: model described tool intent without structured output. Retrying..."))
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

                        // Wire ask_user responses to latestClarification for prompt injection
                        for obs in observations where obs.toolName == "ask_user" && obs.isSuccess {
                            let answer = obs.result.replacingOccurrences(of: "User Response: ", with: "")
                            latestClarification = ClarificationContext(query: obs.params, response: answer)
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
                        switch repetitiveAction {
                        case .abort(let reason):
                            shouldAbort = true
                            abortReason = reason
                        case .proceedWithWarning(let message):
                            // Surface the imminent-abort signal to the UI so the user can
                            // intervene (cancel, refine prompt) before the next iteration trips.
                            continuation.yield(.warning(category: .circuitBreaker, message: message))
                        case .proceed, .intervene:
                            break
                        }

                        if shouldAbort {
                            // Consult ErrorRecovery.onToolFailure policy before aborting
                            switch input.errorRecovery.onToolFailure {
                            case .skipAndContinue:
                                // Log the failure but let the agent continue reasoning
                                continuation.yield(.thought("⚠️ Tool failures detected — skipping and continuing."))
                                memoryStrategy.recordSystemAlert(msg: "Previous tool calls failed: \(abortReason). Continue with available information.")
                                circuitBreaker.resetCountersOnSuccess()
                                // Don't abort — fall through to next iteration

                            case .fallbackPrompt:
                                // Inject a fallback hint and let the agent try a different approach
                                continuation.yield(.thought("⚠️ Tool failures detected — trying alternative approach."))
                                let userMessage = input.errorRecovery.fallbackMessage ?? ErrorRecovery.defaultFallbackMessage
                                memoryStrategy.recordSystemAlert(msg: "Tools are failing repeatedly: \(abortReason). \(userMessage)")
                                circuitBreaker.resetCountersOnSuccess()
                                // Don't abort — fall through to next iteration

                            case .abort:
                                // Default behavior: synthesize best-effort response and exit
                                executionSummary.markComplete(failureReason: abortReason)
                                continuation.yield(.warning(category: .circuitBreaker, message: "Aborting: \(abortReason)"))
                                // Circuit breaker abort: always force synthesis so the user
                                // gets a coherent explanation, not raw partial reasoning.
                                let response = await ResponseSynthesizer.synthesize(
                                    summary: executionSummary,
                                    personaInstructions: input.instructions,
                                    originalQuery: input.userInput,
                                    forceSynthesis: true
                                )
                                if !input.suppressEpisodeManagement {
                                    sessionState.closeActiveEpisode(status: "FAILED", outcome: response)
                                    await SessionGraphStore.shared.updateActiveState(conversationID: input.conversationID, state: sessionState)
                                    logState.info("💾 Auto-Patched Active Episode to: FAILED")
                                }
                                continuation.yield(.content(response))
                                continuation.yield(.executionFinished(outcome: .failed, reason: abortReason))
                                continuation.finish()
                                return
                            }
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

                    // --- Cancellation Gate ---
                    // Check for cancellation BEFORE post-loop synthesis. Without this,
                    // a cancel that arrives while the model response is in-flight allows
                    // the executor to complete via Null-Termination and run the full
                    // synthesis path — but the continuation is already closed by
                    // ActiveStreamManager, so the content is silently dropped and the
                    // user sees an empty message instead of the cancellation placeholder.
                    try Task.checkCancellation()

                    // --- Post-Loop Handoff ---
                    let iterationExhausted = currentIteration >= self.maxIterations

                    if iterationExhausted {
                        // Consult ErrorRecovery.onIterationExhaustion policy
                        switch input.errorRecovery.onIterationExhaustion {
                        case .failHard:
                            // Fail immediately without synthesis
                            let failureMsg = "Reached maximum allowed steps (\(maxIterations)) without completion."
                            executionSummary.markComplete(failureReason: failureMsg)
                            if !input.suppressEpisodeManagement {
                                sessionState.closeActiveEpisode(status: "FAILED", outcome: failureMsg)
                                await SessionGraphStore.shared.updateActiveState(conversationID: input.conversationID, state: sessionState)
                                logState.info("💾 Auto-Patched Active Episode to: FAILED (failHard)")
                            }
                            continuation.yield(.error(failureMsg))
                            continuation.yield(.executionFinished(outcome: .failed, reason: failureMsg))
                            continuation.finish()
                            return

                        case .synthesizeBestEffort:
                            // Default: synthesize best response from accumulated work
                            executionSummary.markComplete(failureReason: "Reached maximum allowed steps (\(maxIterations)) without completion.")
                        }
                    } else {
                        executionSummary.markComplete()
                    }

                    // --- UI Progress: Synthesis ---
                    continuation.yield(.thought("Composing final response…"))

                    let exitStatus = iterationExhausted ? "FAILED" : "COMPLETED"
                    let response = await ResponseSynthesizer.synthesize(
                        summary: executionSummary,
                        personaInstructions: input.instructions,
                        originalQuery: input.userInput,
                        isNativeFlow: input.generatorStrategy is NativeStructuredGenerator,
                        forceSynthesis: input.responseSynthesisEnabled
                    )

                    if !input.suppressEpisodeManagement {
                        sessionState.closeActiveEpisode(status: exitStatus, outcome: response)
                        await SessionGraphStore.shared.updateActiveState(conversationID: input.conversationID, state: sessionState)
                        logState.info("💾 Auto-Patched Active Episode to: \(exitStatus)")
                    }

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

                    // Emit accumulated token usage before finishing
                    if accumulatedTokenUsage.totalTokens > 0 {
                        continuation.yield(.tokenUsage(accumulatedTokenUsage))
                    }

                    continuation.yield(.content(response))
                    let terminalOutcome: ExecutionOutcome = exitStatus == "COMPLETED" ? .completed : .failed
                    let terminalReason: String? = exitStatus == "COMPLETED" ? nil : "Reached maximum iterations (\(maxIterations)) without explicit completion"
                    continuation.yield(.executionFinished(outcome: terminalOutcome, reason: terminalReason))
                    continuation.finish()

                } catch is CancellationError {
                    logger.notice("🚫 Execution Task Cancelled cleanly.")
                    await ExecutionSuspensionService.shared.cancel(for: input.conversationID)
                    if !input.suppressEpisodeManagement {
                        sessionState.cancelActiveEpisode()
                        await SessionGraphStore.shared.updateActiveState(conversationID: input.conversationID, state: sessionState)
                    }
                    continuation.yield(.thought("Cancelled by user."))
                    // Emit a content placeholder so the message bubble isn't left empty.
                    // Without this, cancelled messages show an empty bubble with action
                    // buttons as if the agent completed normally.
                    continuation.yield(.content("*Operation stopped by user.*"))
                    continuation.yield(.executionFinished(outcome: .cancelled, reason: "User stopped the run"))
                    continuation.finish()
                } catch {
                    logger.error("ReAct Fatal Error: \(error.localizedDescription)")
                    await ExecutionSuspensionService.shared.cancel(for: input.conversationID)
                    continuation.yield(.executionFinished(outcome: .failed, reason: error.localizedDescription))
                    continuation.finish(throwing: error)
                }
            }
            
            continuation.onTermination = { @Sendable _ in task.cancel() }
        }
    }
    
}

