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

                // Hoisted above the do-block (like sessionState) so the cancellation/fatal
                // catch blocks can also flush. Emits the run's accumulated usage before ANY
                // terminal exit — previously only the happy-path exit emitted `.tokenUsage`,
                // so circuit-breaker / exhaustion / cancel / fatal exits dropped the whole
                // run's accounting (audit gap #3). Captures the var by reference.
                var accumulatedTokenUsage = TokenUsage()
                let flushTokenUsage = {
                    if accumulatedTokenUsage.totalTokens > 0 {
                        continuation.yield(.tokenUsage(accumulatedTokenUsage))
                    }
                }

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
                    var executionSummary = ExecutionSummary(originalGoal: input.userInput)
                    let executionTrace = input.traceContext

                    // Parse-loop blindness guard: when the parser rejects model output
                    // (`.suspectedFormatFailure`), we inject a corrective alert and retry.
                    // If the model emits the *byte-identical* output multiple times in a row,
                    // the corrective alert isn't landing — the model is stuck. Tracking the
                    // last failed `step.reasoning` lets us abort early with a typed reason
                    // instead of burning the entire iteration budget on the same stuck output.
                    var lastFailedReasoning: String? = nil
                    var consecutiveIdenticalFormatFailures = 0
                    let maxIdenticalFormatFailures = 2  // 2 retries on the same output, then bail
                    
                    var memoryStrategy = input.workingMemory
                    var previousScratchpadLength = 0
                    // Components are built from SEPARATE policy tiers — the legacy
                    // single-knob wiring (retryPolicy.maxRetries driving all three
                    // caps) now lives only inside the resolver's compatibility shim.
                    var circuitBreaker = CognitiveCircuitBreaker(
                        maxConsecutiveToolFailures: input.resiliencePolicy.loop.maxConsecutiveToolFailures,
                        maxRepetitiveActions: input.resiliencePolicy.loop.maxRepetitiveActions
                    )
                    var retryStrategy = LLMRetryStrategy(
                        maxConsecutiveParseFailures: input.resiliencePolicy.cognitive.maxParseFailures,
                        backoffStrategy: input.resiliencePolicy.transport.backoffStrategy,
                        transport: input.resiliencePolicy.transport
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
                    // #22: native-payload (liveConversationTurns) compaction bookkeeping.
                    // The scratchpad budget governs only the legacy <working_memory> path;
                    // the native turn array is bounded at the compaction site instead.
                    // `nativePrefixCount` = the seeded system+history+kickoff turns that must
                    // never be compacted (captured once at iter-1 seeding). `didInjectFullBudgetAlert`
                    // gates the synthesis nudge to once (re-appending it every iteration was
                    // the bug this fixes). `compactedExchangesTotal` feeds the honest marker.
                    var nativePrefixCount = 0
                    var compactedExchangesTotal = 0
                    var didInjectFullBudgetAlert = false
                    let nativeKeepRecentExchanges = 3

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

                    // #21: Read the user personal profile ONCE, before the loop, and inject it on
                    // EVERY iteration via `context` below. On the native path it's folded into the
                    // stable system-prompt prefix at iter-1 seeding (later iters append only); on the
                    // legacy path the prompt is rebuilt each iteration, so a cached value keeps the
                    // profile from vanishing after iter 1 — without re-hitting MainActor/UserDefaults
                    // per iteration. Suppressed in workflow mode (nodes use task+input, not personal context).
                    let userProfile: String?
                    if input.workflowContext == nil {
                        userProfile = await MainActor.run {
                            guard UserDefaults.standard.bool(forKey: AppSettings.ciFeatureUserPersonalKey) else { return nil }
                            return UserPersonalService.shared.getProfileForInjection()
                        }
                    } else {
                        userProfile = nil
                    }

                    // --- Start Episode ---
                    // [G3/G5] When wrapped by a capability (Planning, Reflexion), the wrapper
                    // owns the episode lifecycle. Skip to avoid N+1 duplicate episodes.
                    if !input.suppressEpisodeManagement {
                        logState.info("New Top-Level Request Detected: Appending new MemoryEpisode.")
                        sessionState.episodes.append(MemoryEpisode(primaryGoal: input.userInput, status: .active))
                        sessionState.workingMemory.removeValue(forKey: "current_focus")
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
                        let iterationMetadata: [String: String] = ["iteration": "\(currentIteration)"]
                        
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

                        // `userProfile` is read ONCE before the loop (#21) and injected into
                        // `context` below on every iteration.

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
                            promptLayerConfig: input.workflowContext != nil ? .workflow : .agent,
                            workflowContext: input.workflowContext
                        )

                        // G12: Seed native conversation turns on iter 1. System prompt and
                        // history are built via PromptBuilder (no working_memory), normalized
                        // to the provider's shape, then the kickoff user message carrying the
                        // original query is appended. Subsequent iterations only APPEND
                        // assistant/tool turns — the prefix stays byte-stable.
                        if currentIteration == 1, let nativeGen = nativeGenerator {
                            let canonicalMessages = nativeGen.compileMessages(from: context)
                            liveConversationTurns = canonicalMessages.map { nativeGen.toolTurnAdapter.normalizeCanonical(message: $0) }

                            // Capability-seeded context (Planning dependency results, Reflexion
                            // prior-trial output) lives only in the working-memory scratchpad,
                            // which compileMessages excludes on the native path — in-run
                            // observations flow as tool turns instead, but pre-run seeds have no
                            // tool turns to ride. Fold the iter-1 scratchpad into the kickoff
                            // user turn so seeds reach native providers. Nothing in-run has been
                            // recorded yet, so the scratchpad here is exactly the seeds; unseeded
                            // runs hit the empty sentinel and the kickoff turn stays byte-identical
                            // (KV-cache prefix unchanged). Sentinel literal matches PromptBuilder's
                            // working-memory guard.
                            let seededContext = context.compiledScratchpad
                            let hasSeededContext = !seededContext.isEmpty && seededContext != "No actions taken yet."
                            let kickoffText = hasSeededContext
                                ? PromptWrapping.xml.section("prior_context", content: seededContext) + "\n\n" + input.userInput
                                : input.userInput

                            // Pre-resolve attached image bytes (async) so the sync adapter
                            // can serialize them into the kickoff user turn natively. Empty
                            // → byte-identical text turn (KV-cache prefix unchanged). A failed
                            // resolve throws → surfaced as an execution error, never dropped.
                            let resolvedUserImages = try await resolveUserImages(input.userPayload)
                            liveConversationTurns.append(
                                nativeGen.toolTurnAdapter.userTurn(text: kickoffText, images: resolvedUserImages)
                            )
                            // #22: everything seeded so far (system + history + kickoff) is the
                            // protected prefix — compaction never touches indices below this.
                            nativePrefixCount = liveConversationTurns.count
                            logger.info("🧵 [Native] Seeded liveConversationTurns (\(liveConversationTurns.count) initial turns, \(resolvedUserImages.count) image(s), priorContext=\(hasSeededContext ? "\(seededContext.count) chars" : "none"))")
                        }

                        try Task.checkCancellation()

                        // --- Memory Pressure Check ---
                        // #22: this scratchpad-budget warning is for the legacy <working_memory>
                        // path ONLY. On the native turn path the scratchpad isn't what's sent —
                        // `liveConversationTurns` is — so `budgetUtilization` (and any "older
                        // observations are being evicted" claim) would be dishonest here. Native
                        // pressure is measured and reported truthfully at the compaction site
                        // below, after each iteration's turns are appended. `utilization` stays in
                        // scope for the per-iteration logging line further down.
                        let utilization = memoryStrategy.budgetUtilization
                        if nativeGenerator == nil, utilization > 0.75 {
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

                            // Reasoning is suppressed by `ReasoningQualityFilter` for stub
                            // patterns ("Executing tool X..."), so it is empty for most
                            // small/Q4 model outputs. Logging "📄 Model Reasoning: " with
                            // nothing after the colon is misleading during triage; show
                            // an explicit `(none)` marker instead.
                            if step.reasoning.isEmpty {
                                logger.info("📄 Model Reasoning: (none)")
                            } else {
                                logger.info("📄 Model Reasoning: \(step.reasoning)")
                            }
                            if step.toolCalls.isEmpty {
                                logger.info("🛑 No tool calls produced.")
                            } else {
                                logger.info("🛠️ Produced \(step.toolCalls.count) Tool Calls: \(step.toolCalls.map { $0.name }.joined(separator: ", "))")
                            }
                            
                            retryStrategy.resetParseFailures()
                            
                        } catch {
                            // User cancellation is not an LLM error — exit to the
                            // dedicated CancellationError catch instead of letting it
                            // increment retry counters and flash a parse warning. A cancel
                            // surfaces as URLError(.cancelled) (not a Swift CancellationError),
                            // so also normalize on `Task.isCancelled`.
                            if error is CancellationError || Task.isCancelled { throw CancellationError() }

                            // --- Error Retry Handling ---
                            let action = retryStrategy.handleError(error)
                            switch action {
                            case .throttle(let seconds, let message):
                                // chip task_70f0522b: avoid the 429 double-drain. CloudRequestPipeline
                                // already drains the bucket for a cloud 429 (it throws CloudProviderError
                                // only after draining). Drain here ONLY for providers that bypass the
                                // pipeline (Ollama/local → LLMProviderError.httpError), so the penalty
                                // isn't applied twice. The retry SLEEP below still happens either way.
                                if !(error is CloudProviderError) {
                                    await GlobalRateLimiter.shared.drainAndPenalize(key: input.rateLimitKey, category: input.rateLimitCategory, penaltySeconds: seconds)
                                }
                                continuation.yield(.warning(category: .throttle, message: message))
                                // `seconds` is sanitized upstream (finite, ≥0, ≤1h) —
                                // the guard is cheap insurance against the trapping
                                // UInt64(negative/NaN) conversion.
                                if seconds > 0, seconds.isFinite {
                                    try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
                                }
                                currentIteration -= 1
                                continue cognitiveLoop

                            case .networkRetry(let message, let delaySeconds):
                                continuation.yield(.warning(category: .retry, message: message))
                                // Strategy-owned backoff. Bounded by the transport
                                // budget — exhaustion arrives as `.fatal`, so this can
                                // no longer loop forever (audit gap #5). Cancellation
                                // during the sleep is caught at the loop-top check.
                                if delaySeconds > 0 {
                                    try? await Task.sleep(nanoseconds: UInt64(delaySeconds * 1_000_000_000))
                                }
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
                                    flushTokenUsage()
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
                                    sessionState.closeActiveEpisode(outcome: .failed, message: reason)
                                    await SessionGraphStore.shared.updateActiveState(conversationID: input.conversationID, state: sessionState)
                                    logState.info("💾 Auto-Patched Active Episode to: FAILED")
                                }
                                continuation.yield(.content(reason))
                                flushTokenUsage()
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
                                    sessionState.closeActiveEpisode(outcome: .failed, message: reason)
                                    await SessionGraphStore.shared.updateActiveState(conversationID: input.conversationID, state: sessionState)
                                    logState.info("💾 Auto-Patched Active Episode to: FAILED (capability)")
                                }
                                continuation.yield(.error(.init(reason)))
                                flushTokenUsage()
                                continuation.yield(.executionFinished(outcome: .failed, reason: reason))
                                continuation.finish()
                                return

                            case .fatal(let reason, let category):
                                // Deterministic provider failure (auth, bad model id,
                                // context overflow, exhausted retry budget). The reason
                                // is already user-facing and the category already honest
                                // — render an error card and stop. Previously these fell
                                // into parse-failure handling: 3 futile retries, a
                                // "try rephrasing" message, and `.parseExhausted`
                                // telemetry (audit gap #5).
                                let classified = ClassifiedAgentError.synthetic(
                                    category: category,
                                    origin: "ReActAgentExecutor.retryStrategy.fatal",
                                    message: reason,
                                    context: ["iteration": "\(currentIteration)"]
                                )
                                await TraceRecorder.shared.emitAgentError(
                                    span: input.traceContext,
                                    error: classified,
                                    iteration: currentIteration
                                )
                                if !input.suppressEpisodeManagement {
                                    sessionState.closeActiveEpisode(outcome: .failed, message: reason)
                                    await SessionGraphStore.shared.updateActiveState(conversationID: input.conversationID, state: sessionState)
                                    logState.info("💾 Auto-Patched Active Episode to: FAILED (provider fatal)")
                                }
                                continuation.yield(.error(.init(reason)))
                                flushTokenUsage()
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
                            // Identical-output detection. If the model emits byte-identical
                            // reasoning multiple iterations in a row, the corrective alert
                            // isn't landing — abort with `.repetitiveActionLoop` instead of
                            // burning the full iteration budget on the same stuck output.
                            // This catches the real-world case where Llama-3 keeps emitting
                            // `{"name":"X","parameters":{...}}` 12+ times despite the alert.
                            let currentReasoning = step.reasoning.trimmingCharacters(in: .whitespacesAndNewlines)
                            if !currentReasoning.isEmpty, currentReasoning == lastFailedReasoning {
                                consecutiveIdenticalFormatFailures += 1
                                if consecutiveIdenticalFormatFailures > maxIdenticalFormatFailures {
                                    let abortReason = "Model emitted the same malformed output \(consecutiveIdenticalFormatFailures + 1) times in a row — corrective alerts aren't landing. Likely a parser/dialect mismatch."
                                    logger.error("🛑 Identical-output parse loop detected at iteration \(currentIteration). Aborting.")
                                    let classified = ClassifiedAgentError.synthetic(
                                        category: .parseExhausted,
                                        origin: "ReActAgentExecutor.identicalOutputLoop",
                                        message: abortReason,
                                        context: [
                                            "iteration": "\(currentIteration)",
                                            "repeat_count": "\(consecutiveIdenticalFormatFailures + 1)",
                                            "raw_snippet": String(currentReasoning.prefix(120))
                                        ]
                                    )
                                    await TraceRecorder.shared.emitAgentError(
                                        span: input.traceContext,
                                        error: classified,
                                        iteration: currentIteration
                                    )
                                    continuation.yield(.error(.init(abortReason)))
                                    flushTokenUsage()
                                    continuation.yield(.executionFinished(outcome: .failed, reason: abortReason))
                                    continuation.finish()
                                    return
                                }
                            } else {
                                lastFailedReasoning = currentReasoning.isEmpty ? nil : currentReasoning
                                consecutiveIdenticalFormatFailures = 0
                            }

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
                            // Parse succeeded — reset the identical-output guard so
                            // intermittent format failures (which the corrective alert
                            // *did* land for) don't trip the abort prematurely.
                            lastFailedReasoning = nil
                            consecutiveIdenticalFormatFailures = 0
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
                                params: terminal.params,
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
                        // Native mirroring is deferred until after this iteration's
                        // assistant/tool turns are appended — turn order is chronological,
                        // unlike the scratchpad, which always renders alerts last. (Without
                        // any mirror this emphasis only ever reached legacy-path models.)
                        var pendingDenialAlerts: [String] = []
                        for obs in observations {
                            memoryStrategy.recordObservation(stepId: obs.stepId, toolCallId: obs.toolCallId, toolName: obs.toolName, params: obs.params, result: obs.result, artifacts: obs.artifacts)

                            if obs.failureCategory == .userDenied {
                                let denialAlert = "User DENIED tool '\(obs.toolName)' with the attempted arguments. DO NOT retry this exact action — either choose a different tool, finalize with what you have, or explain the limitation."
                                memoryStrategy.recordSystemAlert(msg: denialAlert)
                                pendingDenialAlerts.append(denialAlert)
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
                            // Serialize the assistant turn from the EXECUTED calls only.
                            // executeToolCalls drops calls without producing observations
                            // (exact-duplicate dedup, same-path write dedup, final_answer
                            // siblings) — serializing the full step.toolCalls would leave
                            // tool_use ids with no tool_result, which Claude/OpenAI reject
                            // with a 400 and Gemini rejects as a functionCall/functionResponse
                            // count mismatch. Filtering keeps both sides of the pairing
                            // converged on the observation set; dropped calls were never
                            // executed, so omitting them from history is the honest record
                            // (the model may legitimately re-issue them).
                            let executedCallIds = Set(observations.map(\.toolCallId))
                            let executedCalls = step.toolCalls.filter { executedCallIds.contains($0.id) }
                            liveConversationTurns.append(
                                nativeGen.toolTurnAdapter.assistantTurn(
                                    toolCalls: executedCalls,
                                    reasoning: sanitizedReasoning
                                )
                            )
                            liveConversationTurns.append(
                                contentsOf: nativeGen.toolTurnAdapter.toolResultTurns(observations: truncatedObservations)
                            )
                            // Denial emphasis follows the tool results it refers to —
                            // chronological parity with the scratchpad's end-of-prompt alerts.
                            for alert in pendingDenialAlerts {
                                liveConversationTurns.append(nativeGen.toolTurnAdapter.systemAlertTurn(message: alert))
                            }

                            // #22: bound the native payload. All tool_use/tool_result pairing for
                            // this iteration is complete here, so dropping the oldest whole
                            // exchanges can't orphan an id. Compaction runs every iteration the
                            // payload is over budget (it must, to bound growth), but the UI
                            // warning + synthesis nudge surface ONCE: once a run is steadily over
                            // budget (e.g. an oversized prefix), it evicts an exchange every
                            // iteration, and re-yielding the warning / re-appending the nudge turn
                            // each time would just be noise (the nudge turn would itself grow the
                            // payload — the exact every-iteration bug this fix removes). The
                            // in-context summary marker keeps the running count honest for the model.
                            if input.nativeContextBudgetChars > 0 {
                                let droppedNow = compactNativeConversation(
                                    &liveConversationTurns,
                                    adapter: nativeGen.toolTurnAdapter,
                                    budgetChars: input.nativeContextBudgetChars,
                                    protectedPrefixCount: nativePrefixCount,
                                    keepRecentExchanges: nativeKeepRecentExchanges,
                                    cumulativeDropped: compactedExchangesTotal
                                )
                                if droppedNow > 0 {
                                    compactedExchangesTotal += droppedNow
                                    logger.info("🧹 [Native] Compacted \(droppedNow) tool exchange(s) (\(compactedExchangesTotal) total) to fit context budget.")
                                    if !didInjectFullBudgetAlert {
                                        didInjectFullBudgetAlert = true
                                        continuation.yield(.warning(category: .memoryPressure, message: "Memory pressure: older tool observations are being summarized to fit the model's context window."))
                                        let nudge = "Working memory is near the context limit and older observations have been summarized out. "
                                            + "Prioritize synthesizing a final answer from available context "
                                            + "rather than calling additional tools."
                                        memoryStrategy.recordSystemAlert(msg: nudge)
                                        liveConversationTurns.append(nativeGen.toolTurnAdapter.systemAlertTurn(message: nudge))
                                    }
                                }
                            }
                        }

                        // Wire ask_user responses to latestClarification for prompt injection
                        for obs in observations where obs.toolName == "ask_user" && obs.isSuccess {
                            let answer = obs.result.replacingOccurrences(of: "User Response: ", with: "")
                            latestClarification = ClarificationContext(query: obs.params, response: answer)
                        }

                        var shouldAbort = false
                        var abortReason = ""
                        // Category for the classified abort error. Repetitive-action is the
                        // historical default; the ask_user idle gate overrides to .cbIdleLimit.
                        var abortCategory: AgentErrorCategory = .cbRepetitiveAction
                        // Loop-hygiene aborts (ask_user idle exhaustion) bypass the user's
                        // ErrorRecovery.onToolFailure tolerance — that policy governs tool
                        // failures, not interrogation loops.
                        var abortBypassesRecoveryPolicy = false

                        for obs in observations {
                            let isSuccess = obs.isSuccess
                            executionSummary.record(toolCallId: obs.toolCallId, toolName: obs.toolName, params: obs.params, output: obs.output, isSuccess: isSuccess)

                            // Route user denials to the dedicated 2-strike denial counter.
                            // Any other failure goes through the general 3-strike tool-failure
                            // counter. Denials still increment the general counter too, so
                            // mixed denial+failure patterns hit the 3-strike limit normally.
                            let isDenial = obs.failureCategory == .userDenied
                            let resultAction: CircuitBreakerAction = isDenial
                                ? circuitBreaker.recordDenial()
                                : circuitBreaker.recordToolResult(isSuccess: isSuccess)

                            if case .abort(let reason) = resultAction {
                                shouldAbort = true
                                abortReason = reason
                            }

                            // Only genuinely hallucinated names (not in the registry) enter
                            // the prompt's "DO NOT USE" ban list. Ordinary failures — file
                            // not found, timeouts, denials, rejected final_answer — are
                            // retryable by design; banning the tool for them contradicts
                            // the corrective observation the model just received.
                            if obs.failureCategory == .notFound {
                                circuitBreaker.recordHallucination(obs.toolName)
                            }
                        }

                        // --- Ask-User Friction Gate ---
                        // Bounds consecutive interrogation: nudge the model past the ask_user
                        // limit, abort at the idle limit. Counters reset only on real tool
                        // progress (see the resetCountersOnSuccess gate below), so a run that
                        // does nothing but question the user can't ride to maxIterations.
                        for obs in observations where obs.toolName == "ask_user" {
                            switch circuitBreaker.evaluateAskUser() {
                            case .intervene(let systemMessage):
                                continuation.yield(.warning(
                                    category: .circuitBreaker,
                                    message: "Repeated clarification requests — nudging the model to proceed without asking again."
                                ))
                                memoryStrategy.recordSystemAlert(msg: systemMessage)
                                if let adapter = nativeGenerator?.toolTurnAdapter {
                                    liveConversationTurns.append(adapter.systemAlertTurn(message: systemMessage))
                                }
                            case .abort(let reason):
                                shouldAbort = true
                                abortReason = reason
                                abortCategory = .cbIdleLimit
                                abortBypassesRecoveryPolicy = true
                            case .proceed, .proceedWithWarning:
                                break
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
                        case .intervene(let systemMessage):
                            // No current producer returns .intervene from this evaluation,
                            // but a breaker directive must never be silently dropped again
                            // (audit gap #3) — route it like any other model alert.
                            memoryStrategy.recordSystemAlert(msg: systemMessage)
                            if let adapter = nativeGenerator?.toolTurnAdapter {
                                liveConversationTurns.append(adapter.systemAlertTurn(message: systemMessage))
                            }
                        case .proceed:
                            break
                        }

                        if shouldAbort {
                            // Consult ErrorRecovery.onToolFailure policy before aborting —
                            // unless the abort is loop hygiene (ask_user idle), which the
                            // tolerance policy doesn't govern.
                            let effectivePolicy: ToolFailurePolicy = abortBypassesRecoveryPolicy
                                ? .abort
                                : input.errorRecovery.onToolFailure
                            switch effectivePolicy {
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
                                // downstream error_chain_id correlation. `abortCategory`
                                // carries the trigger: .cbRepetitiveAction for tool-loop
                                // aborts, .cbIdleLimit for ask_user idle exhaustion.
                                executionSummary.markComplete(failureReason: abortReason)
                                let classified = ClassifiedAgentError.synthetic(
                                    category: abortCategory,
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
                                    forceSynthesis: true,
                                    onUsage: { accumulatedTokenUsage.accumulate($0) }
                                )
                                if !input.suppressEpisodeManagement {
                                    sessionState.closeActiveEpisode(outcome: .failed, message: response)
                                    await SessionGraphStore.shared.updateActiveState(conversationID: input.conversationID, state: sessionState)
                                    logState.info("💾 Auto-Patched Active Episode to: FAILED")
                                }
                                continuation.yield(.content(response))
                                flushTokenUsage()
                                continuation.yield(.executionFinished(outcome: .failed, reason: abortReason))
                                continuation.finish()
                                return
                            }
                        }

                        // Reset ask-user/idle friction only when the iteration made real tool
                        // progress — an iteration that only asked another question is not
                        // progress, and an unconditional reset would zero the friction the
                        // ask-user gate above just accumulated.
                        let madeToolProgress = observations.contains { $0.isSuccess && $0.toolName != "ask_user" }
                        if madeToolProgress {
                            circuitBreaker.resetCountersOnSuccess()
                        }

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
                                sessionState.closeActiveEpisode(outcome: .failed, message: failureMsg)
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
                            continuation.yield(.error(.init(failureMsg)))
                            flushTokenUsage()
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

                    // Single typed source of truth: the executor's terminal outcome.
                    // Everything below — episode close, trace text, stream event — derives
                    // from `terminalOutcome`. The previous `exitStatus` string variable
                    // re-encoded this fact in three places and was the root of vocabulary
                    // drift between SessionGraph episode status and ExecutionOutcome.
                    let terminalOutcome: ExecutionOutcome = iterationExhausted ? .failed : .completed
                    let terminalReason: String? = iterationExhausted
                        ? "Reached maximum iterations (\(maxIterations)) without explicit completion"
                        : nil

                    let response = await ResponseSynthesizer.synthesize(
                        summary: executionSummary,
                        personaInstructions: input.instructions,
                        originalQuery: input.userInput,
                        isNativeFlow: input.generatorStrategy is NativeStructuredGenerator,
                        forceSynthesis: input.responseSynthesisEnabled,
                        onUsage: { accumulatedTokenUsage.accumulate($0) }
                    )

                    if !input.suppressEpisodeManagement {
                        sessionState.closeActiveEpisode(outcome: terminalOutcome, message: response)
                        await SessionGraphStore.shared.updateActiveState(conversationID: input.conversationID, state: sessionState)
                        logState.info("💾 Auto-Patched Active Episode to: \(terminalOutcome.rawValue.uppercased())")
                    }

                    onTraceUpdate(AgentTraceLog(
                        traceID: input.traceContext.traceID,
                        spanID: input.traceContext.spanID,
                        parentSpanID: input.traceContext.parentSpanID,
                        stepNumber: currentIteration,
                        state: .thinking(.finalizing),
                        content: terminalOutcome == .completed ? "Task completed successfully." : "Task failed or reached max iterations."
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
                    flushTokenUsage()
                    continuation.yield(.executionFinished(outcome: .cancelled, reason: "User stopped the run"))
                    continuation.finish()
                } catch {
                    // Classify the fatal error so analytics can bucket unexpected throws.
                    // Typed retrieval failures (e.g. an attached image that couldn't be
                    // resolved for a vision turn) carry a precise category — honour it so
                    // the trace lands in the right bucket instead of the generic crash one.
                    // Everything else buckets as .toolSystemCrash since it most closely
                    // matches "some execution layer threw unexpectedly."
                    let fatalCategory = (error as? FileRetrievalError)?.category ?? .toolSystemCrash
                    let fatalMessage = (error as? FileRetrievalError)?.message ?? "ReAct fatal error: \(error.localizedDescription)"
                    let classified = error.classify(
                        as: fatalCategory,
                        origin: "ReActAgentExecutor.fatalCatch",
                        message: fatalMessage
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
                    flushTokenUsage()
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

/// Approximate serialized character footprint of a native turn dict — recursively sums
/// string lengths and dictionary keys. Used to budget the native conversation payload
/// (`liveConversationTurns`) without paying a full JSON-serialization cost per check (#22).
/// `internal` (not `fileprivate`) so the compaction logic is directly unit-testable.
func approximateTurnChars(_ value: Any) -> Int {
    switch value {
    case let s as String:
        return s.count
    case let dict as [String: Any]:
        return dict.reduce(0) { $0 + $1.key.count + approximateTurnChars($1.value) }
    case let array as [Any]:
        return array.reduce(0) { $0 + approximateTurnChars($1) }
    case let number as NSNumber:
        return number.stringValue.count
    default:
        return 0
    }
}

/// Compacts the native conversation payload when it outgrows `budgetChars`, dropping the
/// OLDEST whole tool exchanges and replacing the dropped span with one summary marker
/// turn. Returns the number of exchanges dropped this call (0 = nothing safely
/// compactable / already under budget). (#22)
///
/// An "exchange" begins at an assistant-tool-call turn (`adapter.classifyTurn ==
/// .toolCallAssistant`) and runs up to the next one — so it always carries the
/// assistant turn together with its paired `tool_result` turn(s) and any trailing alert
/// turns. Cutting only at these boundaries is pairing-safe by construction: an assistant
/// turn is never separated from its results (which Claude/OpenAI 400 and Gemini
/// count-mismatch on). Even if a result turn were misclassified, contiguity with its
/// assistant turn keeps the pair on the same side of the cut.
///
/// The protected prefix (`0 ..< protectedPrefixCount` = system + history + kickoff) is
/// never touched, and the most recent `keepRecentExchanges` exchanges are always kept
/// intact. Dropping from the front necessarily breaks the KV-cache prefix from the cut
/// point — the intended trade when the alternative is overflowing the context window.
/// `internal` (not `fileprivate`) so the compaction logic is directly unit-testable.
func compactNativeConversation(
    _ turns: inout [[String: Any]],
    adapter: any ToolTurnAdapter,
    budgetChars: Int,
    protectedPrefixCount: Int,
    keepRecentExchanges: Int,
    cumulativeDropped: Int
) -> Int {
    guard budgetChars > 0 else { return 0 }
    // Always keep at least one recent exchange — a keep-floor of 0 would make
    // `maxDroppable == exchangeStarts.count` and index `exchangeStarts[count]` out of
    // bounds below. (Production passes 3; the clamp hardens the exposed internal helper.)
    let keepRecent = max(1, keepRecentExchanges)
    let totalChars = turns.reduce(0) { $0 + approximateTurnChars($1) }
    guard totalChars > budgetChars else { return 0 }

    // Exchange-start indices = assistant(tool_calls) turns after the protected prefix.
    let prefix = min(max(0, protectedPrefixCount), turns.count)
    var exchangeStarts: [Int] = []
    for i in prefix..<turns.count where adapter.classifyTurn(turns[i]) == .toolCallAssistant {
        exchangeStarts.append(i)
    }
    // Need more exchanges than we promise to keep, else nothing is safely droppable.
    guard exchangeStarts.count > keepRecent else { return 0 }

    // Drop oldest exchanges until under budget, never below the keep-recent floor.
    // `cut` walks forward to the start of the first KEPT exchange; everything in
    // [prefix, cut) — leading alert turns plus the dropped exchanges — is removed.
    let maxDroppable = exchangeStarts.count - keepRecent
    let markerChars = 200 // conservative footprint of the inserted summary marker turn
    var removed = 0
    var cut = prefix
    var dropped = 0
    for k in 1...maxDroppable {
        let blockEnd = exchangeStarts[k] // start of the (k)-th-from-oldest kept candidate
        while cut < blockEnd {
            removed += approximateTurnChars(turns[cut])
            cut += 1
        }
        dropped = k
        if totalChars - removed + markerChars <= budgetChars { break }
    }
    guard dropped > 0, cut > prefix else { return 0 }

    let marker = adapter.systemAlertTurn(
        message: "[Context note: \(cumulativeDropped + dropped) earlier tool exchange(s) were summarized out to stay within the context window. Re-run a tool if you need that detail again.]"
    )
    turns.replaceSubrange(prefix..<cut, with: [marker])
    return dropped
}

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

/// Pre-resolves attached image payloads to base64 for the agent's native kickoff
/// user turn (adapters are synchronous, so resolution happens here). Throws if an
/// image can't be retrieved — surfaced as an execution error (consistent with the
/// bot path), never a silent drop. Empty/nil payload → no images.
fileprivate func resolveUserImages(_ payload: Payload?) async throws -> [ResolvedImage] {
    guard let payload else { return [] }
    var resolved: [ResolvedImage] = []
    for block in payload {
        guard case .image(let img) = block else { continue }
        let data: Data
        do {
            data = try await img.reference.resolve()
        } catch {
            // Throw a *typed* retrieval failure so it renders as a categorized
            // "Image Read Failed" card (icon + remediation) rather than a generic
            // crash — symmetric with the chat attachment path. (Without this it
            // fell into the executor's fatal catch and was bucketed as a generic
            // `.toolSystemCrash` with a "Response Error" card.)
            let pathLabel: String
            switch img.reference {
            case .diskPath(let url):  pathLabel = url.path
            case .remoteURL(let url): pathLabel = url.absoluteString
            case .ephemeralData:      pathLabel = img.alt ?? "attached image"
            }
            throw FileRetrievalError.imageResolutionFailed(path: pathLabel, underlying: error.localizedDescription)
        }
        resolved.append(ResolvedImage(mimeType: img.mimeType, base64: data.base64EncodedString()))
    }
    return resolved
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
            terminalKind: terminalKind,
            failureCategory: failureCategory
        )
    }
}

