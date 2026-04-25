//
//  ReActAgentExecutor.swift
//  Devgentic
//
//  Created by Raj Singh on 28/01/26.
//  Updated: Phase 5 - Modular Orchestrator Refactoring & Memory Pointers
//

import Foundation
import OSLog

private let logger = DGLogger(category: "ReActExecutor")
private let logState = DGLogger(category: "State")
private let logToolExecution = DGLogger(category: "ToolExecution")

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

                // Install trace/span context so all DGLogger calls inside the executor
                // (and downstream components — mediator, parser, circuit breaker) auto-stamp
                // their LogEntry with the trace IDs for post-hoc correlation.
                await LogContext.with(
                    traceID: input.traceContext.traceID,
                    spanID: input.traceContext.spanID,
                    phase: .tooling
                ) {
                do {
                    logger.info("🚀 ReAct Execution Initiated. Model Instance: \(String(describing: model))")
                    
                    let spyModel = APISpyModel(inner: model)
                    
                    var currentIteration = 0
                    var latestClarification: ClarificationContext? = nil
                    var accumulatedTokenUsage = TokenUsage()
                    var executionSummary = ExecutionSummary(originalGoal: input.userInput)
                    let executionTrace = input.traceContext
                    
                    var memoryStrategy = input.workingMemory
                    var previousScratchpadLength = 0
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

                    // --- G12: Native-Turn State Machine ---
                    // When the generator is NativeStructuredGenerator we own a growing
                    // conversation-turns array across iterations instead of re-compiling
                    // working memory into a user message each turn. On iter 1 the array
                    // is seeded from PromptBuilder (system + history + kickoff user);
                    // each subsequent iter appends `assistant(tool_calls) → tool(result)`
                    // turns produced by the provider-specific `ToolTurnAdapter`.
                    // For MLX / dialect generators this stays nil — those keep the
                    // legacy `<working_memory>` user-message path.
                    let nativeGenerator: NativeStructuredGenerator? = input.generatorStrategy as? NativeStructuredGenerator
                    var liveConversationTurns: [[String: Any]] = []

                    // --- G6: Reading-Tool Gate ---
                    // `update_project_context` is hidden from the tool schema until the agent
                    // has successfully invoked grounding tools. Prevents weak local models
                    // from speculatively writing project memory before they've explored.
                    // `codebase_map` counts because on the Code interface it returns a rich
                    // structural survey that substantively grounds the model — excluding it
                    // was causing exploration-heavy queries ("Analyse the project") to burn
                    // extra iterations bouncing off the gate.
                    var readingToolSuccessCount = 0
                    let readingToolNames: Set<String> = [
                        "read_file", "find_definition", "code_search", "file_overview", "codebase_map"
                    ]
                    let gatedToolNames: Set<String> = ["update_project_context"]
                    // Small-tier models (≤14B — e.g. qwen2.5-coder:14b) thrash against a
                    // threshold of 2 because they tend to start with one structural tool and
                    // immediately want to persist. Lower the bar for them; medium/large
                    // models keep the stricter default.
                    let readingGateThreshold: Int = (input.modelTier == .small) ? 1 : 2
                    var readingGateLoggedUnlock = false

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

                        // G6: Filter gated tools from the schema until prerequisites are met.
                        // When the list doesn't contain a gated tool (e.g. non-Code profile),
                        // this is a zero-cost no-op.
                        let availableToolsThisIteration: [AgentTool] = {
                            if readingToolSuccessCount >= readingGateThreshold {
                                return input.tools
                            }
                            return input.tools.filter { !gatedToolNames.contains($0.name) }
                        }()

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
                            availableTools: availableToolsThisIteration,
                            userProfile: userProfile,
                            skillManifests: input.skillManifests,
                            taskDescription: input.workflowContext?.taskDescription,
                            promptLayerConfig: input.workflowContext != nil ? .workflow : .agent
                        )

                        // G12: Seed native conversation turns on iter 1. System prompt and
                        // history are built via PromptBuilder (no working_memory), normalized
                        // to the provider's shape, then the kickoff user message carrying the
                        // original query is appended. Subsequent iterations only APPEND
                        // assistant/tool turns — the prefix stays byte-stable.
                        if currentIteration == 1, let nativeGen = nativeGenerator {
                            let canonicalMessages = nativeGen.compileMessages(from: context)
                            liveConversationTurns = canonicalMessages.map { nativeGen.toolTurnAdapter.normalizeCanonical(message: $0) }
                            liveConversationTurns.append(
                                nativeGen.toolTurnAdapter.normalizeCanonical(
                                    message: ["role": "user", "content": input.userInput]
                                )
                            )
                            logger.info("🧵 [Native] Seeded liveConversationTurns (\(liveConversationTurns.count) initial turns)")
                        }

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
                                let memoryAlert = "Working memory is full. Older observations have been evicted. "
                                    + "Prioritize synthesizing a final answer from available context "
                                    + "rather than calling additional tools."
                                memoryStrategy.recordSystemAlert(msg: memoryAlert)
                                if let adapter = nativeGenerator?.toolTurnAdapter {
                                    liveConversationTurns.append(adapter.systemAlertTurn(message: memoryAlert))
                                }
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
                            
                            let genStart = Date()
                            if let nativeGen = nativeGenerator {
                                // G12 native path: thread the growing turn array through the provider.
                                step = try await nativeGen.generateNativeStep(
                                    model: spyModel,
                                    nativeMessages: liveConversationTurns,
                                    availableTools: availableToolsThisIteration,
                                    iteration: currentIteration
                                )
                            } else {
                                // Legacy path (MLX, dialect generators): rebuilds messages from context each iter.
                                step = try await input.generatorStrategy.generateCognitiveStep(
                                    model: spyModel,
                                    context: context,
                                    iteration: currentIteration
                                )
                            }
                            let genDuration = Date().timeIntervalSince(genStart)

                            // G12 instrumentation: per-iter latency + scratchpad growth delta.
                            // Before refactor: delta grows each iter and genDuration tracks it.
                            // After refactor: scratchpad largely unused on native path, genDuration
                            // should plateau on iter 2+ as KV cache hits the conversation prefix.
                            let scratchpadLen = context.compiledScratchpad.count
                            let delta = scratchpadLen - previousScratchpadLength
                            let deltaSign = delta >= 0 ? "+" : ""
                            logger.info("⏱️ [ITER \(currentIteration)] gen=\(String(format: "%.2f", genDuration))s | scratchpad=\(scratchpadLen) chars (Δ\(deltaSign)\(delta))")
                            previousScratchpadLength = scratchpadLen

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
                                if let adapter = nativeGenerator?.toolTurnAdapter {
                                    liveConversationTurns.append(adapter.systemAlertTurn(message: systemAlert))
                                }
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
                                // Structured classification for the retry-strategy abort path.
                                // `.parseExhausted` is the most common abort trigger (consecutive
                                // parse failures exceed policy); using it as default — the
                                // retry strategy's own reason string carries finer detail in
                                // `context`. If we ever split retry-abort into finer subtypes,
                                // thread the triggering category from RetryAction itself.
                                let classified = ClassifiedAgentError.synthetic(
                                    category: .parseExhausted,
                                    origin: "ReActAgentExecutor.retryStrategy.abort",
                                    message: reason,
                                    context: ["iteration": "\(currentIteration)"]
                                )
                                await TraceRecorder.shared.emitAgentError(
                                    span: input.traceContext,
                                    error: classified,
                                    iteration: currentIteration
                                )
                                if !input.suppressEpisodeManagement {
                                    sessionState.closeActiveEpisode(status: "FAILED", outcome: reason)
                                    await SessionGraphStore.shared.updateActiveState(conversationID: input.conversationID, state: sessionState)
                                    logState.info("💾 Auto-Patched Active Episode to: FAILED")
                                }
                                continuation.yield(.content(reason))
                                continuation.yield(.executionFinished(outcome: .failed, reason: reason))
                                continuation.finish()
                                return

                            case .capabilityFailure(let reason):
                                // Hard capability gap — emit as `.error` so the UI renders a
                                // distinct error card instead of mixing the message into
                                // streaming prose where it looks like agent output.
                                let classified = ClassifiedAgentError.synthetic(
                                    category: .providerCapabilityMissing,
                                    origin: "ReActAgentExecutor.retryStrategy.capabilityFailure",
                                    message: reason,
                                    context: ["iteration": "\(currentIteration)"]
                                )
                                await TraceRecorder.shared.emitAgentError(
                                    span: input.traceContext,
                                    error: classified,
                                    iteration: currentIteration
                                )
                                if !input.suppressEpisodeManagement {
                                    sessionState.closeActiveEpisode(status: "FAILED", outcome: reason)
                                    await SessionGraphStore.shared.updateActiveState(conversationID: input.conversationID, state: sessionState)
                                    logState.info("💾 Auto-Patched Active Episode to: FAILED (capability)")
                                }
                                continuation.yield(.error(reason))
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

                        // Yield the LLM's visible assistant monologue as a dedicated
                        // `.reasoning` event (distinct from system narration which uses
                        // `.thought`) and persist it to working memory so subsequent
                        // iterations can see the model's prior thought chain — fixes
                        // the reasoning amnesia where each iteration started with no
                        // trace of the previous one's monologue.
                        // Skip if empty or identical to `.thought` content to avoid duplication.
                        if !step.reasoning.isEmpty && step.reasoning != step.thought {
                            let sanitized = OutputSanitizer.sanitizeForUI(step.reasoning)
                            if !sanitized.isEmpty {
                                continuation.yield(.reasoning(sanitized))
                                memoryStrategy.recordReasoning(stepId: currentIteration, text: sanitized)
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
                        case .suspectedFormatFailure(let originalReason, _):
                            // Typed parse failure — build a reason-specific corrective alert
                            // so the model gets targeted feedback (e.g. "unknown tool name,
                            // did you mean X?" vs "your JSON had syntax errors"). The old
                            // generic "describe tool calls in prose" message is preserved
                            // as the fallback inside `ParseFailureReason.modelCorrectiveAlert`
                            // when the failure shape is `.proseDescribedIntent`.
                            //
                            // If the model called a tool name that belongs to the gated set
                            // (see G6 reading-gate), promote `.unknownToolName → .gatedTool`
                            // so the UI chip and model alert both explain "locked, read N
                            // more files" instead of an alarming "Unknown tool" hallucination
                            // claim. The tool exists — it's just not available yet.
                            let reason: ParseFailureReason = {
                                if case .unknownToolName(let attempted, _) = originalReason,
                                   gatedToolNames.contains(attempted),
                                   readingToolSuccessCount < readingGateThreshold {
                                    let remaining = max(0, readingGateThreshold - readingToolSuccessCount)
                                    let noun = remaining == 1 ? "file" : "files"
                                    let hint = "Read \(remaining) more source \(noun) (e.g. `read_file`, `file_overview`, `codebase_map`) to unlock it"
                                    return .gatedTool(attempted: attempted, unlockHint: hint)
                                }
                                return originalReason
                            }()

                            let toolNames = availableToolsThisIteration.map(\.name)
                            let modelAlert = reason.modelCorrectiveAlert(availableToolNames: toolNames)
                            memoryStrategy.recordSystemAlert(msg: modelAlert)
                            if let adapter = nativeGenerator?.toolTurnAdapter {
                                liveConversationTurns.append(adapter.systemAlertTurn(message: modelAlert))
                            }

                            // Gated tools get a quieter chip — it's a policy lock, not a
                            // format correction. Other failure shapes retain the existing
                            // "Format correction (…)" prefix so regressions are obvious.
                            let warningMessage: String
                            if case .gatedTool = reason {
                                warningMessage = reason.uiChipLabel
                            } else {
                                warningMessage = "Format correction (\(reason.uiChipLabel)): retrying iteration \(currentIteration)."
                            }
                            continuation.yield(.warning(
                                category: .formatCorrection,
                                message: warningMessage
                            ))
                            logger.warning("🔄 Suspected format failure [\(reason.uiChipLabel)]. Injecting typed corrective alert and retrying iteration \(currentIteration).")
                            continue cognitiveLoop
                        case .proceed:
                            break
                        }

                        if step.toolCalls.isEmpty { break cognitiveLoop }

                        // 3. ACTING & OBSERVING PHASE (Shared Parallel Execution)
                        // Pass the same filtered list used in the schema so that a gated tool
                        // (e.g. update_project_context) dispatched via hallucination fails with
                        // "tool not found" rather than silently executing.
                        let observations = try await executeToolCalls(
                            toolCalls: step.toolCalls,
                            availableTools: availableToolsThisIteration,
                            conversationID: input.conversationID,
                            currentIteration: currentIteration,
                            iterationSpan: iterationSpan,
                            toolMediator: toolMediator,
                            continuation: continuation,
                            onTraceUpdate: onTraceUpdate
                        )

                        // --- G6: Advance Reading-Tool Gate Counter ---
                        // Count successful reading-tool invocations so `update_project_context`
                        // becomes available once the agent has actually read some source.
                        for obs in observations where obs.isSuccess && readingToolNames.contains(obs.toolName) {
                            readingToolSuccessCount += 1
                        }
                        if !readingGateLoggedUnlock && readingToolSuccessCount >= readingGateThreshold {
                            readingGateLoggedUnlock = true
                            logger.info("🔓 Reading gate unlocked (\(readingToolSuccessCount)/\(readingGateThreshold) successful reading tools) — gated tools now available: \(gatedToolNames.sorted().joined(separator: ", "))")

                            // Tell the model the tool is now available and how to use it.
                            // Previously this guidance lived in the system prompt (causing
                            // the model to attempt the call while the gate was still closed).
                            memoryStrategy.recordSystemAlert(msg: CodeSystemPrompt.updateProjectContextUnlockAlert)
                            if let adapter = nativeGenerator?.toolTurnAdapter {
                                liveConversationTurns.append(adapter.systemAlertTurn(
                                    message: CodeSystemPrompt.updateProjectContextUnlockAlert
                                ))
                            }
                        }

                        // --- Terminal Signal Fast-Exit (final_answer) ---
                        // ToolExecutionLoop intercepts final_answer and returns a terminal
                        // observation. Seat it as the final agent thought and break — the
                        // post-loop ResponseSynthesizer's native fast-path will surface
                        // `finalAgentThought` to the user verbatim. For legacy/non-native
                        // flows the synthesizer treats it as the agent's conclusion and
                        // formats accordingly. Either way: the answer survives.
                        if let terminal = observations.first(where: { $0.isTerminalSignal && $0.terminalKind == .finalAnswer }) {
                            executionSummary.record(
                                toolCallId: terminal.toolCallId,
                                toolName: terminal.toolName,
                                params: terminal.params,
                                output: terminal.output,
                                isSuccess: true
                            )
                            executionSummary.finalAgentThought = terminal.output
                            memoryStrategy.recordObservation(
                                stepId: terminal.stepId,
                                toolCallId: terminal.toolCallId,
                                toolName: terminal.toolName,
                                result: terminal.result,
                                artifacts: terminal.artifacts
                            )
                            logger.info("🏁 Terminal signal received (final_answer). Exiting cognitive loop at iteration \(currentIteration).")
                            break cognitiveLoop
                        }

                        // Commit observations to memory strategy.
                        // User-denied tool calls ALSO get promoted to a system alert so the
                        // "do not retry" directive renders at the end of the scratchpad
                        // (high-attention position) instead of buried in the observation list.
                        // Detection is via the canonical denial string produced by
                        // `ToolExecutionResult.userDenied`.
                        for obs in observations {
                            memoryStrategy.recordObservation(stepId: obs.stepId, toolCallId: obs.toolCallId, toolName: obs.toolName, result: obs.result, artifacts: obs.artifacts)

                            if !obs.isSuccess && obs.result.hasPrefix("System Security: User explicitly denied") {
                                memoryStrategy.recordSystemAlert(
                                    msg: "User DENIED tool '\(obs.toolName)' with the attempted arguments. DO NOT retry this exact action — either choose a different tool, finalize with what you have, or explain the limitation."
                                )
                            }
                        }

                        // G12: Extend native conversation turns with this iter's assistant(tool_calls)
                        // + tool(result) exchange. Observations are sorted to match the order of the
                        // model's original tool_calls (Gemini matches functionResponse → functionCall
                        // by position) and truncated via the memory strategy so a huge tool output
                        // doesn't blow past the per-entry cap that the scratchpad path already enforces.
                        // Reasoning is sanitized — same policy as the legacy recordReasoning path —
                        // so leaked markdown fences / tool-call prose don't pollute the conversation.
                        if let nativeGen = nativeGenerator {
                            let orderedObservations = sortObservationsByToolCallOrder(
                                observations: observations,
                                toolCalls: step.toolCalls
                            )
                            let truncatedObservations = orderedObservations.map { obs in
                                obs.withResult(memoryStrategy.truncatedResult(for: obs.result))
                            }
                            let sanitizedReasoning: String? = {
                                guard !step.reasoning.isEmpty, step.reasoning != step.thought else { return nil }
                                let s = OutputSanitizer.sanitizeForUI(step.reasoning)
                                return s.isEmpty ? nil : s
                            }()
                            liveConversationTurns.append(
                                nativeGen.toolTurnAdapter.assistantTurn(
                                    toolCalls: step.toolCalls,
                                    reasoning: sanitizedReasoning
                                )
                            )
                            liveConversationTurns.append(
                                contentsOf: nativeGen.toolTurnAdapter.toolResultTurns(observations: truncatedObservations)
                            )
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

                            // Route user denials to the dedicated 2-strike denial counter.
                            // Any other failure goes through the general 3-strike tool-failure
                            // counter. Denials still increment the general counter too, so
                            // mixed denial+failure patterns hit the 3-strike limit normally.
                            let isDenial = !isSuccess && obs.result.hasPrefix("System Security: User explicitly denied")
                            let resultAction: CircuitBreakerAction = isDenial
                                ? circuitBreaker.recordDenial()
                                : circuitBreaker.recordToolResult(isSuccess: isSuccess)

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
                        case .proceedWithWarning(let uiMessage, let modelAlert):
                            // G2: Dual-channel imminent-abort signal.
                            //   UI   — terse chip so the human can intervene (cancel, refine prompt).
                            //   Model — directive alert injected into the next prompt's working
                            //           memory so the model itself can course-correct before the
                            //           hard abort. Without this injection, the warning reaches
                            //           only the UI and the model repeats blindly into the 3rd
                            //           strike.
                            continuation.yield(.warning(category: .circuitBreaker, message: uiMessage))
                            memoryStrategy.recordSystemAlert(msg: modelAlert)
                            if let adapter = nativeGenerator?.toolTurnAdapter {
                                liveConversationTurns.append(adapter.systemAlertTurn(message: modelAlert))
                            }
                        case .proceed, .intervene:
                            break
                        }

                        if shouldAbort {
                            // Consult ErrorRecovery.onToolFailure policy before aborting
                            switch input.errorRecovery.onToolFailure {
                            case .skipAndContinue:
                                // Log the failure but let the agent continue reasoning
                                continuation.yield(.thought("⚠️ Tool failures detected — skipping and continuing."))
                                let skipAlert = "Previous tool calls failed: \(abortReason). Continue with available information."
                                memoryStrategy.recordSystemAlert(msg: skipAlert)
                                if let adapter = nativeGenerator?.toolTurnAdapter {
                                    liveConversationTurns.append(adapter.systemAlertTurn(message: skipAlert))
                                }
                                circuitBreaker.resetCountersOnSuccess()
                                // Don't abort — fall through to next iteration

                            case .fallbackPrompt:
                                // Inject a fallback hint and let the agent try a different approach
                                continuation.yield(.thought("⚠️ Tool failures detected — trying alternative approach."))
                                let userMessage = input.errorRecovery.fallbackMessage ?? ErrorRecovery.defaultFallbackMessage
                                let fallbackAlert = "Tools are failing repeatedly: \(abortReason). \(userMessage)"
                                memoryStrategy.recordSystemAlert(msg: fallbackAlert)
                                if let adapter = nativeGenerator?.toolTurnAdapter {
                                    liveConversationTurns.append(adapter.systemAlertTurn(message: fallbackAlert))
                                }
                                circuitBreaker.resetCountersOnSuccess()
                                // Don't abort — fall through to next iteration

                            case .abort:
                                // Circuit-breaker abort path. Classify BEFORE emitting the
                                // user-facing warning so the chain ID is available for
                                // downstream error_chain_id correlation. The CB trigger could
                                // be repetitive-action, consecutive-fail, or tool-retry-limit;
                                // we use `.cbRepetitiveAction` as the typical default, since
                                // that's the most common source of circuit-breaker aborts.
                                // If we want finer classification, the breaker could return
                                // the triggering category explicitly.
                                executionSummary.markComplete(failureReason: abortReason)
                                let classified = ClassifiedAgentError.synthetic(
                                    category: .cbRepetitiveAction,
                                    origin: "ReActAgentExecutor.circuitBreakerAbort",
                                    message: "Circuit breaker triggered: \(abortReason)",
                                    context: ["iteration": "\(currentIteration)"]
                                )
                                await TraceRecorder.shared.emitAgentError(
                                    span: input.traceContext,
                                    error: classified,
                                    iteration: currentIteration
                                )
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
                            // Structured error telemetry — this is a fatal exit path, not a
                            // caught exception. Use `.synthetic(...)` so the SpanEvent carries
                            // the category + chainID. `cbIdleLimit` doesn't quite fit (that's
                            // ask_user exhaustion); iteration exhaustion reuses the same
                            // phase-level fatal semantics. If we see these in dashboards and
                            // want finer detail, add a dedicated `executorIterationExhausted`
                            // case to AgentErrorCategory.
                            let classified = ClassifiedAgentError.synthetic(
                                category: .cbIdleLimit,
                                origin: "ReActAgentExecutor.iterationExhaustion.failHard",
                                message: failureMsg,
                                context: [
                                    "max_iterations": "\(maxIterations)",
                                    "final_iteration": "\(currentIteration)"
                                ]
                            )
                            await TraceRecorder.shared.emitAgentError(
                                span: input.traceContext,
                                error: classified,
                                iteration: currentIteration
                            )
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
                    // Classify the fatal error so analytics can bucket unexpected throws.
                    // Uses `.executionThrew`-analogue — there isn't a perfect category for
                    // "executor-level fatal throw"; the taxonomy has domain-specific fatals
                    // (parseExhausted, providerAuth, etc.) but catches at this level are
                    // already misclassified most of the time. Bucket as .toolSystemCrash
                    // since it most closely matches "some execution layer threw unexpectedly."
                    let classified = error.classify(
                        as: .toolSystemCrash,
                        origin: "ReActAgentExecutor.fatalCatch",
                        message: "ReAct fatal error: \(error.localizedDescription)"
                    )
                    logger.error(
                        "ReAct Fatal Error: \(classified.message)",
                        error: classified,
                        category: classified.category
                    )
                    await TraceRecorder.shared.emitAgentError(
                        span: input.traceContext,
                        error: classified
                    )
                    await ExecutionSuspensionService.shared.cancel(for: input.conversationID)
                    continuation.yield(.executionFinished(outcome: .failed, reason: classified.message))
                    continuation.finish(throwing: error)
                }
                } // close LogContext.with
            }

            continuation.onTermination = { @Sendable _ in task.cancel() }
        }
    }

}

// MARK: - G12 Native-Turn Helpers

/// Reorders observations to match the positional order of the assistant's original
/// `PendingToolCall`s. Gemini matches `functionResponse` parts back to `functionCall`
/// parts by position (no tool_call_id), so an out-of-order `TaskGroup` completion would
/// produce wrong correspondence. Claude and OpenAI match by id — this is defensive and
/// cheap, so we sort uniformly regardless of provider.
fileprivate func sortObservationsByToolCallOrder(
    observations: [ToolObservation],
    toolCalls: [PendingToolCall]
) -> [ToolObservation] {
    let idToIndex: [String: Int] = Dictionary(
        uniqueKeysWithValues: toolCalls.enumerated().map { ($0.element.id, $0.offset) }
    )
    return observations.sorted { lhs, rhs in
        let lIndex = idToIndex[lhs.toolCallId] ?? Int.max
        let rIndex = idToIndex[rhs.toolCallId] ?? Int.max
        return lIndex < rIndex
    }
}

fileprivate extension ToolObservation {
    /// Returns a copy with the `result` field replaced. Used on the native-turn path
    /// to swap in the `WorkingMemoryStrategy`-truncated result before serializing into
    /// `tool_result` turns — keeps per-entry budget policy in one place.
    func withResult(_ newResult: String) -> ToolObservation {
        ToolObservation(
            stepId: stepId,
            toolCallId: toolCallId,
            toolName: toolName,
            result: newResult,
            summary: summary,
            isSuccess: isSuccess,
            params: params,
            output: output,
            artifacts: artifacts,
            isTerminalSignal: isTerminalSignal,
            terminalKind: terminalKind
        )
    }
}

