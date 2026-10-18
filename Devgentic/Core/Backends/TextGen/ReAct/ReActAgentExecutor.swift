// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
//
//  ReActAgentExecutor.swift
//  Devgentic
//
//  Created by Raj Singh.
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
    // Internal rather than private so tests can assert the configured limit is actually threaded through.
    nonisolated let maxIterations: Int
    
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
                
                // Initialized here so the cancellation/catch blocks can reach it.
                var sessionState: SessionGraph
                if let activeState = input.activeState {
                    sessionState = activeState
                } else {
                    sessionState = await SessionGraphStore.shared.getActiveState(for: input.conversationID)
                }
                let currentConstraints = Set(sessionState.negativeConstraints)

                // Hoisted above the do-block (like sessionState) so the cancellation/fatal catch blocks can also flush. Emits the run's
                // accumulated usage before any terminal exit (circuit-breaker, exhaustion, cancel, fatal), not only the happy path.
                var accumulatedTokenUsage = TokenUsage()
                let flushTokenUsage = {
                    if accumulatedTokenUsage.totalTokens > 0 {
                        continuation.yield(.tokenUsage(accumulatedTokenUsage))
                    }
                }

                // Install trace/span context so DGLogger calls inside the executor and downstream components (mediator, parser,
                // circuit breaker) stamp their LogEntry with the trace IDs.
                await LogContext.with(
                    traceID: input.traceContext.traceID,
                    spanID: input.traceContext.spanID,
                    phase: .tooling
                ) {
                // Declared above the `do` so the CancellationError catch can report how far the run got.
                var currentIteration = 0
                do {
                    logger.info("🚀 ReAct Execution Initiated. Model Instance: \(String(describing: model))")

                    // Per-call LLM spans: the scope tells the spy which step span to parent each model call under; the loop updates it
                    // as it opens each iteration span. Before the first iteration it carries the root context.
                    let llmSpanScope = LLMSpanScope(input.traceContext)
                    let spyModel = APISpyModel(inner: model, spanScope: llmSpanScope)

                    var latestClarification: ClarificationContext? = nil
                    var executionSummary = ExecutionSummary(originalGoal: input.userInput)
                    let executionTrace = input.traceContext

                    // Parse-loop guard: ends the loop (`formatCorrectionsExhausted`, then the "On Budget Exhausted" policy) after
                    // `maxConsecutiveFormatFailures` rejections in a row or `maxIdenticalFormatFailures` repeats of a byte-identical reply.
                    var lastFailedReasoning: String? = nil
                    var consecutiveIdenticalFormatFailures = 0
                    let maxIdenticalFormatFailures = 2
                    var consecutiveFormatFailures = 0
                    let maxConsecutiveFormatFailures = max(1, input.resiliencePolicy.cognitive.maxParseFailures)
                    // Set when the guard above ends the loop; the reason shown to the user.
                    var formatCorrectionsExhausted: String? = nil

                    var memoryStrategy = input.workingMemory
                    var previousScratchpadLength = 0
                    // Components are built from separate policy tiers; the legacy single-knob wiring lives only in the resolver's
                    // compatibility shim.
                    var circuitBreaker = CognitiveCircuitBreaker(
                        maxConsecutiveToolFailures: input.resiliencePolicy.loop.maxConsecutiveToolFailures,
                        maxRepetitiveActions: input.resiliencePolicy.loop.maxRepetitiveActions,
                        maxConsecutiveDenials: input.resiliencePolicy.loop.maxConsecutiveDenials,
                        // Every trigger kind honours the profile's tolerance today
                        // (`AbortTrigger.honoursToolFailurePolicy`), so this is exact.
                        repetitionEndsRun: input.errorRecovery.onToolFailure == .abort
                    )
                    // Downgraded breaker triggers already shown to the user, so a loop that keeps
                    // going warns ONCE, not every iteration (the model is still nudged every time).
                    var announcedLoopWarnings: Set<String> = []
                    // Per-run memory of human interactions: replays identical clarification answers and auto-denies identical declined
                    // requests. A capability wrapper (Planning/Reflexion) may pass a shared instance so answers carry across subtasks.
                    let interactionMemory = input.interactionMemory ?? RunInteractionMemory()
                    // The wire format this run parses back, the single source for both corrective alerts. Taken from the generator,
                    // not `ProviderConfig`, since the generator does the parsing (`.singleAction` discards the stored dialect).
                    let runDialect = input.generatorStrategy.expectedDialect
                    var retryStrategy = LLMRetryStrategy(
                        maxConsecutiveParseFailures: input.resiliencePolicy.cognitive.maxParseFailures,
                        backoffStrategy: input.resiliencePolicy.transport.backoffStrategy,
                        transport: input.resiliencePolicy.transport,
                        dialect: runDialect
                    )
                    let toolMediator = ToolExecutionMediator()
                    let terminationEvaluator = EpisodeTerminationEvaluator()

                    // Native-turn state machine: with a NativeStructuredGenerator we own a growing turns array across iterations, seeded on
                    // iteration 1 from PromptBuilder and extended via `ToolTurnAdapter`. MLX / dialect generators leave it nil.
                    let nativeGenerator: NativeStructuredGenerator? = input.generatorStrategy as? NativeStructuredGenerator
                    var liveConversationTurns: [[String: Any]] = []
                    // Native-payload compaction bookkeeping: the scratchpad budget governs only the legacy <working_memory> path.
                    // `nativePrefixCount` = seeded turns never compacted; `didInjectFullBudgetAlert` gates the synthesis nudge to once.
                    var nativePrefixCount = 0
                    var compactedExchangesTotal = 0
                    var didInjectFullBudgetAlert = false
                    let nativeKeepRecentExchanges = 3

                    // The run's full loadout — what an attempted call is recognised against.
                    let runToolNames: Set<String> = Set(input.tools.map(\.name))
                    // Captured once per run, not per iteration: a minute ticking over mid-run changes prompt bytes and forces the whole
                    // prompt to be re-read (see MLXPromptCache); a few minutes of staleness is harmless.
                    let runClock = EnvironmentFacts.clock()

                    // Read the user personal profile once, before the loop, and inject it each iteration via `context`; workflow nodes too.
                    // Gated by the Core Intelligence toggle and `PromptLayerConfig.workflow.includeUserProfile`; flip both or it is empty.
                    let userProfile: String? = await MainActor.run {
                        guard UserDefaults.standard.bool(forKey: AppSettings.ciFeatureUserPersonalKey) else { return nil }
                        return UserPersonalService.shared.getProfileForInjection()
                    }

                    // Skipped when a capability wrapper owns the episode lifecycle, and on resume, where the original run's episode
                    // continues; appending a second would double-count.
                    if !input.suppressEpisodeManagement && input.resumeState == nil {
                        logState.info("New Top-Level Request Detected: Appending new MemoryEpisode.")
                        sessionState.episodes.append(MemoryEpisode(primaryGoal: input.userInput, status: .active))
                        sessionState.workingMemory.removeValue(forKey: "current_focus")
                        await SessionGraphStore.shared.updateActiveState(conversationID: input.conversationID, state: sessionState)
                    }
                    
                    // MARK: - Cognitive Loop
                    // Set when the loop ends on the model's answer (prose or `final_answer`), so an answer on the last allowed step isn't
                    // replaced by the exhaustion template.
                    var reachedAnswer = false
                    // Largest request payload (chars) the user approved at the large-request gate
                    // this run; 0 = none yet. See `LargeRequestGate.needsConfirmation`.
                    var largeRequestApprovedThroughChars = 0

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
                        
                        await GlobalRateLimiter.shared.waitForCapacity(forKey: input.rateLimitKey, category: input.rateLimitCategory)
                        // The limiter swallows sleep interruption internally (its wait is non-throwing); surface a Stop pressed during a long
                        // cloud debt wait here instead of firing another generation.
                        try Task.checkCancellation()

                        let iterationSpan = executionTrace.newSpan()
                        let iterationMetadata: [String: String] = ["iteration": "\(currentIteration)"]
                        
                        await TraceRecorder.shared.beginSpan(context: iterationSpan, name: "iteration_\(currentIteration)", kind: .iteration)
                        // This iteration's model calls parent under THIS step span.
                        llmSpanScope.set(iterationSpan)
                        // Input-lane clock: everything between here and the model call is prompt/context assembly.
                        let contextBuildStart = Date()

                        // Honest per-iteration status: deliberate exits set this flag; failure returns and throws leave it false, so an aborted
                        // iteration records `.error`. `endedAt` is captured synchronously in the defer so the persisted end is the real end.
                        var iterationFinishedNormally = false
                        defer {
                            let endedAt = Date()
                            let s: SpanStatus = iterationFinishedNormally ? .completed : .error
                            Task { await TraceRecorder.shared.endSpan(spanID: iterationSpan.spanID, status: s, at: endedAt) }
                        }
                        
                        // --- Build Context ---
                        let envFacts = EnvironmentFacts(
                            osVersion: ProcessInfo.processInfo.operatingSystemVersionString,
                            shellType: "Zsh (Non-Interactive Mode)",
                            userName: NSUserName(),
                            homeDirectory: NSHomeDirectory(),
                            currentDate: runClock.date,
                            currentTime: runClock.time,
                            workspaceRoot: input.workspaceRoot
                        )

                        // `userProfile` is read ONCE before the loop (#21) and injected into
                        // `context` below on every iteration.

                        let availableToolsThisIteration: [AgentTool] = input.tools

                        var context = SemanticContext(
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
                            promptLayerConfig: input.workflowContext != nil ? .workflow : .agent,
                            workflowContext: input.workflowContext,
                            attachmentContext: input.attachmentContext,
                            knowledgeBaseContext: input.knowledgeBaseContext,
                            toolGuidanceContext: input.toolGuidanceContext,
                            userImagePayload: input.userPayload
                        )
                        context.projectKnowledge = input.projectKnowledge
                        // Prompt-builder telemetry: context-injection events attribute to this iteration's span.
                        context.traceContext = iterationSpan
                        // The full loadout, so a prompt-dialect parse recognises a broken call to
                        // any tool this run offers (`AttemptedToolCallGrammar`).
                        context.runToolNames = runToolNames

                        // Seed native conversation turns on iteration 1: system prompt and history from PromptBuilder, then the kickoff user
                        // message. Later iterations only append assistant/tool turns, so the prefix stays byte-stable.
                        if currentIteration == 1, let nativeGen = nativeGenerator {
                            let canonicalMessages = nativeGen.compileMessages(from: context)
                            liveConversationTurns = canonicalMessages.map { nativeGen.toolTurnAdapter.normalizeCanonical(message: $0) }

                            // Re-attach prior-turn images: `compileMessages` returns text-only history, which would erase images attached earlier.
                            // Text-only histories no-op here and stay byte-identical.
                            let (historyImagesSpliced, historyImagesOmitted) = await spliceHistoryImages(
                                into: &liveConversationTurns,
                                historyTurns: input.nativeHistoryTurns,
                                canonical: canonicalMessages,
                                adapter: nativeGen.toolTurnAdapter,
                                correlation: "trace:\(input.traceContext.traceID)"
                            )

                            // Capability-seeded context (Planning dependency results, Reflexion prior-trial output) lives only in the scratchpad,
                            // which the native path excludes; fold the iteration-1 scratchpad into the kickoff turn (unseeded runs stay identical).
                            let seededContext = context.compiledScratchpad
                            let hasSeededContext = !seededContext.isEmpty && seededContext != "No actions taken yet."
                            // Attachments ride the kickoff turn because compileMessages excludes them on the native path. Unseeded, attachment-free
                            // runs leave the kickoff byte-identical (KV-cache prefix unchanged).
                            let kickoffText: String = {
                                var parts: [String] = []
                                // Layout B: the per-message part (episodic history, current time, retrieved context) leads this turn so the system
                                // message stays constant; a workflow node keeps it in its prefix user message instead.
                                if input.workflowContext == nil,
                                   let turn = PromptBuilder.turnContext(context: context, layerConfig: context.promptLayerConfig, wrapping: .xml) {
                                    parts.append(turn)
                                }
                                if hasSeededContext {
                                    parts.append(PromptWrapping.xml.section("prior_context", content: seededContext))
                                }
                                if let attachments = input.attachmentContext, !attachments.isEmpty {
                                    parts.append(attachments)
                                }
                                // Not on the workflow path: a workflow node's input already rides the user message `compileMessages` built, so appending
                                // `input.userInput` would send the same payload twice. Each payload gets exactly one carrier.
                                if input.workflowContext == nil {
                                    parts.append(input.userInput)
                                }
                                return parts.joined(separator: "\n\n")
                            }()

                            // Pre-resolve attached image bytes (async) so the sync adapter can serialize them into the kickoff user turn.
                            // A failed resolve throws and surfaces as an execution error, never dropped.
                            let resolvedUserImages = try await resolveUserImages(input.userPayload)
                            // Skip an empty kickoff turn: the prefix user message already ends the request on a user turn, and a blank message
                            // is rejected by some providers. Images keep the turn, having no other carrier.
                            if !kickoffText.isEmpty || !resolvedUserImages.isEmpty {
                                liveConversationTurns.append(
                                    nativeGen.toolTurnAdapter.userTurn(text: kickoffText, images: resolvedUserImages)
                                )
                            }
                            // #22: everything seeded so far (system + history + kickoff) is the
                            // protected prefix — compaction never touches indices below this.
                            nativePrefixCount = liveConversationTurns.count
                            logger.info("🧵 [Native] trace:\(input.traceContext.traceID) Seeded liveConversationTurns (\(liveConversationTurns.count) initial turns, \(resolvedUserImages.count) image(s) this turn, \(historyImagesSpliced) from history\(historyImagesOmitted > 0 ? ", \(historyImagesOmitted) omitted" : ""), priorContext=\(hasSeededContext ? "\(seededContext.count) chars" : "none"))")
                        }

                        // Resume preamble (native and legacy): replay completed tool exchanges, re-run the parked tool through the normal HITL
                        // path and jump to the parked iteration. Always runs when `resumeState` is set, so a resumed run cannot duplicate tools.
                        if currentIteration == 1, let recon = input.resumeState {
                            let nativeAdapter = nativeGenerator?.toolTurnAdapter
                            logger.info("⏯️ [Resume] \(nativeAdapter != nil ? "native" : "legacy") replay of \(recon.completedSteps.count) completed step(s); parked=\(recon.parkedTool?.name ?? "none"); resumeIteration=\(recon.resumeIteration)")

                            // Replay completed exchanges: native appends paired native turns; both record into working memory and the summary,
                            // which the legacy scratchpad rebuild and end-of-run synthesis read.
                            for step in recon.completedSteps {
                                if let nativeAdapter {
                                    liveConversationTurns.append(nativeAdapter.assistantTurn(toolCalls: step.toolCalls, reasoning: step.reasoning))
                                    liveConversationTurns.append(contentsOf: nativeAdapter.toolResultTurns(observations: step.observations))
                                }
                                if let reasoning = step.reasoning, !reasoning.isEmpty {
                                    memoryStrategy.recordReasoning(stepId: step.stepId, text: reasoning)
                                }
                                for obs in step.observations {
                                    executionSummary.record(toolCallId: obs.toolCallId, toolName: obs.toolName, params: obs.params, output: obs.output, isSuccess: obs.isSuccess, failureCategory: obs.failureCategory)
                                    memoryStrategy.recordObservation(stepId: obs.stepId, toolCallId: obs.toolCallId, toolName: obs.toolName, params: obs.params, result: obs.result, artifacts: obs.artifacts)
                                }

                                // Re-prime the repetition bookkeeping and interaction memory from the replayed iteration so prevention and the
                                // fingerprint streak survive park and resume (these per-run locals would otherwise restart at zero).
                                circuitBreaker.primeReplayedIteration(step.observations)
                                for obs in step.observations {
                                    if obs.toolName == "ask_user" {
                                        // Ask observations carry the question in `params` and the
                                        // response in `output` ("User Response: …").
                                        let prefix = "User Response: "
                                        let response: String? = obs.isSuccess
                                            ? (obs.output.hasPrefix(prefix) ? String(obs.output.dropFirst(prefix.count)) : obs.output)
                                            : nil
                                        await interactionMemory.recordAnswer(question: obs.params, response: response)
                                    } else if obs.failureCategory == .userDenied {
                                        await interactionMemory.recordDenial(toolName: obs.toolName, params: obs.params)
                                    }
                                }
                            }

                            // Re-run the parked tool via the dialect-agnostic path: it re-raises the HITL banner and returns the observation
                            // once the user responds.
                            if let parked = recon.parkedTool {
                                let parkedObs = try await executeToolCalls(
                                    toolCalls: [parked],
                                    availableTools: input.tools,
                                    conversationID: input.conversationID,
                                    currentIteration: recon.resumeIteration,
                                    iterationSpan: iterationSpan,
                                    toolMediator: toolMediator,
                                    interactionMemory: interactionMemory,
                                    continuation: continuation,
                                    approvalNodeID: input.workflowContext?.nodeID,
                                    unattendedAutoApprove: input.workflowContext?.unattendedAutoApprove ?? false,
                                    workspaceRoot: input.workspaceRoot,
                                    onTraceUpdate: onTraceUpdate
                                )
                                if let nativeAdapter {
                                    // Pairing-safe: only serialize calls that produced an observation
                                    // (mirror of the loop's executedCallIds filter) so no orphaned tool_use.
                                    let executedIds = Set(parkedObs.map(\.toolCallId))
                                    let executedCalls = [parked].filter { executedIds.contains($0.id) }
                                    if !executedCalls.isEmpty {
                                        liveConversationTurns.append(nativeAdapter.assistantTurn(toolCalls: executedCalls, reasoning: nil))
                                        liveConversationTurns.append(contentsOf: nativeAdapter.toolResultTurns(observations: parkedObs))
                                    }
                                }
                                for obs in parkedObs {
                                    executionSummary.record(toolCallId: obs.toolCallId, toolName: obs.toolName, params: obs.params, output: obs.output, isSuccess: obs.isSuccess, failureCategory: obs.failureCategory)
                                    memoryStrategy.recordObservation(stepId: obs.stepId, toolCallId: obs.toolCallId, toolName: obs.toolName, params: obs.params, result: obs.result, artifacts: obs.artifacts)
                                }
                            }

                            // 3. Jump to the parked iteration; the loop's `currentIteration += 1` makes the
                            //    next generated step iteration N+1. Iter-1 native seeding won't re-run.
                            currentIteration = recon.resumeIteration
                            iterationFinishedNormally = true; continue cognitiveLoop
                        }

                        try Task.checkCancellation()

                        // Memory pressure: this scratchpad-budget warning is for the legacy <working_memory> path only; on the native path the
                        // turn array is what is sent, so its pressure is reported at the compaction site below.
                        let utilization = memoryStrategy.budgetUtilization
                        if nativeGenerator == nil, utilization > 0.75 {
                            let pct = Int(utilization * 100)
                            let message = utilization >= 1.0
                                ? "Memory pressure: \(pct)% of scratchpad budget used — older observations are being evicted."
                                : "Memory pressure: \(pct)% of scratchpad budget used."
                            logger.warning("⚠️ \(message)")
                            continuation.yield(.warning(category: .memoryPressure, message: message))

                            // Why: a constant alert re-recorded each iteration inflates `budgetUtilization` and refires, evicting the format correctives.
                            // Proactive throttling: once the budget is exhausted, nudge the model toward synthesis (tools stay callable).
                            // Fires once per run via `didInjectFullBudgetAlert`, shared with the native path (the two are mutually exclusive).
                            if utilization >= 1.0, !didInjectFullBudgetAlert {
                                didInjectFullBudgetAlert = true
                                let memoryAlert = "Working memory is full. Older observations have been evicted. "
                                    + "Prioritize synthesizing a final answer from available context "
                                    + "rather than calling additional tools."
                                memoryStrategy.recordSystemAlert(msg: memoryAlert)
                            }
                        }

                        // Large cloud request gate (see `LargeRequestGate`), native path only: it resends the whole turn array and is the only
                        // path `largeRequestConfirmChars` is set for.
                        if nativeGenerator != nil, input.largeRequestConfirmChars > 0 {
                            let payloadChars = liveConversationTurns.reduce(0) { $0 + approximateTurnChars($1) }
                                + ToolSchemaSizes.chars(for: availableToolsThisIteration.map(\.name))
                            if LargeRequestGate.needsConfirmation(
                                payloadChars: payloadChars,
                                thresholdChars: input.largeRequestConfirmChars,
                                approvedThroughChars: largeRequestApprovedThroughChars
                            ) {
                                let tokens = LargeRequestGate.estimatedTokens(chars: payloadChars)
                                let approvalNodeID = input.workflowContext?.nodeID
                                if await SessionToolApprovals.shared.isAllowed(
                                    toolName: LargeRequestGate.bannerToolName,
                                    conversationID: input.conversationID,
                                    nodeID: approvalNodeID
                                ) {
                                    logger.info("[LARGE_REQUEST] ~\(tokens) tokens to \(model.modelName) — allowed for this chat earlier, not asking. conv \(input.conversationID.uuidString.prefix(8))")
                                    largeRequestApprovedThroughChars = payloadChars
                                } else if !WorkflowRunAttendance.canReachAHuman {
                                    // Nobody can answer a banner in an unattended run, and parking here
                                    // would only end at the run's time limit. Warn and send.
                                    logger.warning("[LARGE_REQUEST] ~\(tokens) tokens to \(model.modelName) in an UNATTENDED run. CONSEQUENCE: sent without asking — nobody can answer a banner here.")
                                    continuation.yield(.warning(category: .contextPressure, message: "Sending a large request (~\(tokens.formatted()) tokens) to \(model.modelName)."))
                                    largeRequestApprovedThroughChars = payloadChars
                                } else {
                                    let operationID = UUID()
                                    logger.notice("[LARGE_REQUEST] ~\(tokens) tokens (\(payloadChars) chars) to \(model.modelName) is over the \(LargeRequestGate.thresholdTokens)-token warning level. CONSEQUENCE: the run PARKS on a confirmation banner before anything is sent.")
                                    continuation.yield(.requestConfirmation(
                                        toolName: LargeRequestGate.bannerToolName,
                                        params: LargeRequestGate.bannerText(payloadChars: payloadChars, modelName: model.modelName),
                                        operationID: operationID,
                                        sourceNodeID: approvalNodeID,
                                        sourceNodeName: input.workflowContext?.nodeName
                                    ))
                                    let approved = await ExecutionSuspensionService.shared.suspend(
                                        for: operationID, conversationID: input.conversationID, nodeID: approvalNodeID)
                                    // A Stop also resolves the park as `false`; let it take the
                                    // cancellation path rather than reporting a decline nobody made.
                                    try Task.checkCancellation()
                                    guard approved else {
                                        logger.notice("[LARGE_REQUEST] DECLINED by the user (~\(tokens) tokens). CONSEQUENCE: the run stops here; nothing was sent.")
                                        let reason = "User declined a ~\(tokens)-token request to the cloud model"
                                        if !input.suppressEpisodeManagement {
                                            sessionState.closeActiveEpisode(outcome: .cancelled, message: reason)
                                            await SessionGraphStore.shared.updateActiveState(conversationID: input.conversationID, state: sessionState)
                                        }
                                        iterationFinishedNormally = true
                                        continuation.yield(.content(LargeRequestGate.declinedText(payloadChars: payloadChars)))
                                        flushTokenUsage()
                                        continuation.yield(.executionFinished(outcome: .cancelled, reason: reason))
                                        continuation.finish()
                                        return
                                    }
                                    logger.info("[LARGE_REQUEST] APPROVED by the user (~\(tokens) tokens). CONSEQUENCE: sent; the next ask comes if the payload grows by another \(LargeRequestGate.thresholdTokens) tokens.")
                                    largeRequestApprovedThroughChars = payloadChars
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
                            // Close the Input-lane bracket: context assembly ran from the top
                            // of this iteration to here (the model call starts now).
                            await TraceRecorder.shared.emitMetric(
                                span: iterationSpan,
                                key: "input_assembly",
                                valueMs: Int(genStart.timeIntervalSince(contextBuildStart) * 1000)
                            )
                            if let nativeGen = nativeGenerator {
                                // Native path: thread the growing turn array through the provider. Streamed as a provisional draft (`.draftText`) so a
                                // long step shows text as written; the draft is withdrawn unless the step is the final answer.
                                let draft = DraftTextRelay(enabled: Self.streamsDrafts(for: input)) { text in
                                    continuation.yield(.draftText(text))
                                }
                                do {
                                    step = try await nativeGen.generateNativeStep(
                                        model: spyModel,
                                        nativeMessages: liveConversationTurns,
                                        availableTools: availableToolsThisIteration,
                                        iteration: currentIteration,
                                        runToolNames: runToolNames,
                                        onTextDelta: draft.onTextDelta
                                    )
                                } catch {
                                    draft.withdraw()
                                    throw error
                                }
                                let isFinalAnswer: Bool = {
                                    if case .genuineCompletion = step.parseOutcome { return true }
                                    return false
                                }()
                                if isFinalAnswer { draft.flush() } else { draft.withdraw() }
                            } else {
                                // Legacy path (MLX, dialect generators): rebuilds messages from context each iteration. The scope keys `MLXPromptCache`
                                // per conversation and wraps this call only, so planning, reflection and synthesis never evict the agent's cache.
                                step = try await MLXPromptCacheScope.$key.withValue(input.conversationID.uuidString) {
                                    try await input.generatorStrategy.generateCognitiveStep(
                                        model: spyModel,
                                        context: context,
                                        iteration: currentIteration
                                    )
                                }
                            }
                            let genDuration = Date().timeIntervalSince(genStart)

                            // Instrumentation: per-iteration latency and scratchpad growth delta.
                            let scratchpadLen = context.compiledScratchpad.count
                            let delta = scratchpadLen - previousScratchpadLength
                            let deltaSign = delta >= 0 ? "+" : ""
                            logger.info("⏱️ [ITER \(currentIteration)] gen=\(String(format: "%.2f", genDuration))s | scratchpad=\(scratchpadLen) chars (Δ\(deltaSign)\(delta))")
                            previousScratchpadLength = scratchpadLen

                            // Accumulate token usage from this cognitive step
                            if let usage = step.tokenUsage {
                                accumulatedTokenUsage.accumulate(usage)

                                // The provider's own count says whether this prompt filled the window. Ollama doesn't error: it drops the start of the
                                // prompt (instructions and the `final_answer` contract go first) and answers anyway, so the run just misbehaves.
                                if let overflow = ContextCutLog.overflow(in: usage, step: currentIteration, windowTokens: input.contextWindowTokens) {
                                    logger.warning("[CONTEXT] Step \(currentIteration)'s prompt used \(usage.inputTokens) of the \(input.contextWindowTokens)-token window — the provider had to cut it. CONSEQUENCE: Ollama drops the START of the prompt, so the model may have lost its instructions from this step on; the context gauge reports it. Conversation \(input.conversationID.uuidString.prefix(8)), trace \(input.traceContext.traceID).")
                                    ContextCutLog.post(overflow: overflow, conversationID: input.conversationID,
                                                       traceID: input.traceContext.traceID)
                                }
                            }

                            // Reasoning is empty for most small/Q4 outputs, so log an explicit `(none)` marker. `step.reasoning` is the model's
                            // visible text (the final answer on a no-tool step); its thinking is `step.thought`.
                            if step.reasoning.isEmpty {
                                logger.info("📄 Model text: (none)")
                            } else {
                                logger.info("📄 Model text\(step.toolCalls.isEmpty ? " (final answer)" : ""): \(step.reasoning)")
                            }
                            if let thought = step.thought, !thought.isEmpty {
                                logger.info("🧠 Thinking trace: \(thought.count) chars")
                            }
                            if step.toolCalls.isEmpty {
                                logger.info("🛑 No tool calls produced.")
                            } else {
                                logger.info("🛠️ Produced \(step.toolCalls.count) Tool Calls: \(step.toolCalls.map { $0.name }.joined(separator: ", "))")
                            }
                            
                            retryStrategy.resetParseFailures()
                            
                        } catch {
                            // User cancellation is not an LLM error: exit to the CancellationError catch instead of bumping retry counters. A cancel
                            // surfaces as URLError(.cancelled), not CancellationError, so also normalize on `Task.isCancelled`.
                            if error is CancellationError || Task.isCancelled { throw CancellationError() }

                            // --- Error Retry Handling ---
                            let action = retryStrategy.handleError(error)
                            switch action {
                            case .throttle(let seconds, let message):
                                // Avoid the 429 double-drain: CloudRequestPipeline already drains the bucket for a cloud 429. Drain here only for
                                // providers that bypass it (Ollama/local); the retry sleep below happens either way.
                                if !(error is CloudProviderError) {
                                    await GlobalRateLimiter.shared.drainAndPenalize(key: input.rateLimitKey, category: input.rateLimitCategory, penaltySeconds: seconds)
                                }
                                continuation.yield(.warning(category: .throttle, message: message))
                                // `seconds` is sanitized upstream (finite, 0...1h); the guard insures against the trapping UInt64 conversion. `try`, not
                                // `try?`: Retry-After can reach an hour and swallowing CancellationError would make Stop fire a fresh request.
                                if seconds > 0, seconds.isFinite {
                                    try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
                                }
                                currentIteration -= 1
                                iterationFinishedNormally = true; continue cognitiveLoop

                            case .networkRetry(let message, let delaySeconds):
                                continuation.yield(.warning(category: .retry, message: message))
                                // Strategy-owned backoff, bounded by the transport budget (exhaustion arrives as `.fatal`); cancellation during the
                                // sleep is caught at the loop-top check.
                                if delaySeconds > 0 {
                                    try? await Task.sleep(nanoseconds: UInt64(delaySeconds * 1_000_000_000))
                                }
                                currentIteration -= 1
                                iterationFinishedNormally = true; continue cognitiveLoop

                            case .parseRetry(let systemAlert, let attemptCount, let maxAttempts):
                                memoryStrategy.recordSystemAlert(msg: systemAlert)
                                if let adapter = nativeGenerator?.toolTurnAdapter {
                                    liveConversationTurns.append(adapter.systemAlertTurn(message: systemAlert))
                                }
                                continuation.yield(.warning(category: .parseFailure, message: "Invalid JSON output. Retrying (\(attemptCount)/\(maxAttempts))..."))
                                await GlobalRateLimiter.shared.waitForCapacity(forKey: input.rateLimitKey, category: input.rateLimitCategory)
                                iterationFinishedNormally = true; continue cognitiveLoop

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
                                iterationFinishedNormally = true; continue cognitiveLoop

                            case .abort(let reason):
                                // Structured classification for the retry-strategy abort path: `.parseExhausted` is the most common trigger, so it is
                                // the default; the retry strategy's own reason string carries finer detail in `context`.
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
                                // Hard capability gap: emitted as `.error` so the UI renders a distinct error card instead of mixing the message into
                                // streaming prose.
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
                                // Deterministic provider failure (auth, bad model id, context overflow, exhausted retry budget): the reason is already
                                // user-facing and the category honest, so render an error card and stop rather than treat it as a parse failure.
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
                                // No "Step N —" prefix: each trace already sits in its own "Thinking"
                                // row in order, so the number only pushed the model's words right.
                                continuation.yield(.thought(sanitized))
                            }
                        }

                        // Yield the visible monologue as `.reasoning` (distinct from `.thought`) and persist it to working memory so later
                        // iterations see it. Skipped if empty, equal to `.thought`, or the final answer, which would appear twice.
                        let isFinalAnswer: Bool = {
                            if case .genuineCompletion = step.parseOutcome { return true }
                            return false
                        }()
                        if !isFinalAnswer, !step.reasoning.isEmpty && step.reasoning != step.thought {
                            let sanitized = OutputSanitizer.sanitizeForUI(step.reasoning)
                            if !sanitized.isEmpty {
                                // The UI still shows it: on a failed parse this is the user's only window onto what the model emitted, since the raw
                                // output is logged at `.debug`, which never reaches an exported bundle.
                                continuation.yield(.reasoning(sanitized))

                                // Why: the corrective alert already carries what the model needs; the identical-output detector reads `step.reasoning`
                                // directly.
                                // Not written to working memory when the parse failed: `step.reasoning` is then the raw unparseable blob, and
                                // recording it shows the model its own malformed output as a prior thought, which it copies.
                                if case .failed = step.parseOutcome {
                                    logger.debug(
                                        "[MEMORY] Iteration \(currentIteration) produced an unparseable "
                                        + "step — its raw output is NOT recorded as reasoning. "
                                        + "CONSEQUENCE: the scratchpad carries the typed corrective "
                                        + "alert instead of the malformed text, so the model cannot "
                                        + "copy its own failed output on the retry."
                                    )
                                } else {
                                    memoryStrategy.recordReasoning(stepId: currentIteration, text: sanitized)
                                }
                            }
                        }
                        
                        let termStatus = terminationEvaluator.evaluate(step: step, currentIteration: currentIteration, maxIterations: self.maxIterations)
                        switch termStatus {
                        case .maxIterationsReached:
                            // The budget is spent and this step's calls cannot be read — end now
                            // instead of running them (the evaluator logged which).
                            iterationFinishedNormally = true; break cognitiveLoop
                        case .completed(let finalThought):
                            executionSummary.finalAgentThought = finalThought
                            // Terminal prose exit (genuineCompletion): with no tool calls `executeToolCalls`, which emits the per-iteration
                            // reasoning row, never runs; without this the final iteration's span is empty in the Report Inspector.
                            onTraceUpdate(AgentTraceLog(
                                traceID: iterationSpan.traceID,
                                spanID: iterationSpan.spanID,
                                parentSpanID: iterationSpan.parentSpanID,
                                stepNumber: currentIteration,
                                state: .thinking(.reasoning),
                                content: "Model answered directly (no tool calls).",
                                metadata: ["iteration": "\(currentIteration)"]
                            ))
                            reachedAnswer = true
                            iterationFinishedNormally = true; break cognitiveLoop
                        case .suspectedFormatFailure(let originalReason, _):
                            // Byte-identical repeats: one trigger of the parse-loop guard, e.g. Llama-3 emitting the same `{"name":"X",...}` call
                            // 12+ times despite the alert.
                            let currentReasoning = step.reasoning.trimmingCharacters(in: .whitespacesAndNewlines)
                            if !currentReasoning.isEmpty, currentReasoning == lastFailedReasoning {
                                consecutiveIdenticalFormatFailures += 1
                            } else {
                                lastFailedReasoning = currentReasoning.isEmpty ? nil : currentReasoning
                                consecutiveIdenticalFormatFailures = 0
                            }
                            consecutiveFormatFailures += 1

                            // Parse-loop guard (see `maxConsecutiveFormatFailures`): stop correcting
                            // and leave the loop like an exhausted budget.
                            let stuckOnIdenticalOutput = consecutiveIdenticalFormatFailures > maxIdenticalFormatFailures
                            if stuckOnIdenticalOutput || consecutiveFormatFailures >= maxConsecutiveFormatFailures {
                                // The latest reply becomes the answer only when the parser found no call in it, never when the model demonstrably tried
                                // to call something. A backstop: `AttemptedToolCallGrammar` already converts such text upstream.
                                let isTextShapeFailure: Bool = {
                                    switch originalReason {
                                    case .malformedJSON, .noStructuredOutput: return true
                                    default: return false
                                    }
                                }()
                                let attemptedCall = AttemptedToolCallGrammar.attemptedCallName(
                                    in: currentReasoning, callableNames: runToolNames)
                                let keepsLastReply = isTextShapeFailure && !currentReasoning.isEmpty && attemptedCall == nil

                                let last = attemptedCall.map { "attempted call '\($0)'" } ?? originalReason.uiChipLabel
                                let exhaustion = AgentFailureReason.formatCorrectionsExhaustedMessage(
                                    count: stuckOnIdenticalOutput ? consecutiveIdenticalFormatFailures + 1 : consecutiveFormatFailures,
                                    last: last,
                                    identicalReplies: stuckOnIdenticalOutput)
                                formatCorrectionsExhausted = exhaustion
                                if keepsLastReply {
                                    executionSummary.finalAgentThought = currentReasoning
                                }
                                let shown = keepsLastReply
                                    ? "with the latest reply (\(currentReasoning.count) chars, no attempted call) as the answer"
                                    : "without showing the latest reply — it is an attempted call or empty"
                                logger.error("[FORMAT] Iteration \(currentIteration): \(exhaustion) CONSEQUENCE: no more corrective retries; the run ends under the '\(input.errorRecovery.onIterationExhaustion.rawValue)' exhaustion policy, \(shown). conv \(input.conversationID)")

                                var errorContext = [
                                    "iteration": "\(currentIteration)",
                                    "consecutive_failures": "\(consecutiveFormatFailures)",
                                    "last_reason": originalReason.uiChipLabel
                                ]
                                if stuckOnIdenticalOutput {
                                    errorContext["repeat_count"] = "\(consecutiveIdenticalFormatFailures + 1)"
                                    errorContext["raw_snippet"] = String(currentReasoning.prefix(120))
                                }
                                let classified = ClassifiedAgentError.synthetic(
                                    category: .parseExhausted,
                                    origin: stuckOnIdenticalOutput
                                        ? "ReActAgentExecutor.identicalOutputLoop"
                                        : "ReActAgentExecutor.consecutiveFormatFailures",
                                    message: exhaustion,
                                    context: errorContext
                                )
                                await TraceRecorder.shared.emitAgentError(
                                    span: input.traceContext,
                                    error: classified,
                                    iteration: currentIteration
                                )
                                continuation.yield(.warning(
                                    category: .formatCorrection,
                                    message: keepsLastReply
                                        ? "Format corrections didn't take after \(consecutiveFormatFailures) tries — showing the model's last reply as the answer."
                                        : "Format corrections didn't take after \(consecutiveFormatFailures) tries — stopping."
                                ))
                                iterationFinishedNormally = true; break cognitiveLoop
                            }

                            // Typed parse failure: build a reason-specific corrective alert so the model gets targeted feedback;
                            // `.proseDescribedIntent` falls back to the generic message inside `ParseFailureReason.modelCorrectiveAlert`.
                            let reason = originalReason

                            let toolNames = availableToolsThisIteration.map(\.name)
                            let modelAlert = reason.modelCorrectiveAlert(
                                availableToolNames: toolNames,
                                dialect: runDialect
                            )
                            memoryStrategy.recordSystemAlert(msg: modelAlert)
                            if let adapter = nativeGenerator?.toolTurnAdapter {
                                liveConversationTurns.append(adapter.systemAlertTurn(message: modelAlert))
                            }

                            continuation.yield(.warning(
                                category: .formatCorrection,
                                message: "Format correction (\(reason.uiChipLabel)): retrying iteration \(currentIteration)."
                            ))
                            logger.warning("🔄 Suspected format failure [\(reason.uiChipLabel)]. Injecting typed corrective alert and retrying iteration \(currentIteration).")
                            iterationFinishedNormally = true; continue cognitiveLoop
                        case .proceed:
                            // Parse succeeded: reset the identical-output guard so intermittent format failures don't trip the abort prematurely.
                            lastFailedReasoning = nil
                            consecutiveIdenticalFormatFailures = 0
                            consecutiveFormatFailures = 0
                            break
                        }

                        if step.toolCalls.isEmpty { iterationFinishedNormally = true; break cognitiveLoop }

                        // 3. ACTING & OBSERVING PHASE (Shared Parallel Execution)
                        let observations = try await executeToolCalls(
                            toolCalls: step.toolCalls,
                            availableTools: availableToolsThisIteration,
                            conversationID: input.conversationID,
                            currentIteration: currentIteration,
                            iterationSpan: iterationSpan,
                            toolMediator: toolMediator,
                            interactionMemory: interactionMemory,
                            continuation: continuation,
                            approvalNodeID: input.workflowContext?.nodeID,
                            unattendedAutoApprove: input.workflowContext?.unattendedAutoApprove ?? false,
                            workspaceRoot: input.workspaceRoot,
                            rejectedCalls: step.rejectedCalls,
                            onTraceUpdate: onTraceUpdate
                        )

                        // Terminal signal fast-exit (final_answer): ToolExecutionLoop returns a terminal observation; seat it as the final agent
                        // thought and break. The post-loop ResponseSynthesizer surfaces `finalAgentThought` verbatim or as the conclusion.
                        if let terminal = observations.first(where: { $0.isTerminalSignal && $0.terminalKind == .finalAnswer }) {
                            // final_answer is a control signal, not evidence: not recorded into executionSummary.toolResults, where it would pass
                            // hallucinated answers off as corroboration. Its text reaches the user via finalAgentThought.
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
                            reachedAnswer = true
                            iterationFinishedNormally = true; break cognitiveLoop
                        }

                        // Commit observations to the memory strategy. User-denied tool calls also become a system alert so "do not retry"
                        // renders last in the scratchpad; native mirroring waits for this iteration's turns to keep turn order chronological.
                        var pendingDenialAlerts: [String] = []
                        for obs in observations {
                            memoryStrategy.recordObservation(stepId: obs.stepId, toolCallId: obs.toolCallId, toolName: obs.toolName, params: obs.params, result: obs.result, artifacts: obs.artifacts)
                            // The scratchpad path's cut, reported like the native one, only when the scratchpad is what the model reads;
                            // on the native path the native fit decides and reporting both would double-count.
                            if nativeGenerator == nil, obs.result.count > memoryStrategy.perResultLimit {
                                ContextCutLog.post(
                                    cut: .init(toolName: obs.toolName, originalChars: obs.result.count,
                                               keptChars: memoryStrategy.perResultLimit),
                                    conversationID: input.conversationID, traceID: input.traceContext.traceID)
                            }

                            if obs.failureCategory == .userDenied {
                                let denialAlert = "User DENIED tool '\(obs.toolName)' with the attempted arguments. DO NOT retry this exact action — either choose a different tool, finalize with what you have, or explain the limitation."
                                memoryStrategy.recordSystemAlert(msg: denialAlert)
                                pendingDenialAlerts.append(denialAlert)
                            }
                        }

                        // Extend native turns with this iteration's assistant(tool_calls) + tool(result) exchange, observations sorted to
                        // match the tool_calls order (Gemini matches by position) and fitted by `ToolResultBudget`.
                        if let nativeGen = nativeGenerator {
                            let orderedObservations = sortObservationsByToolCallOrder(
                                observations: observations,
                                toolCalls: step.toolCalls
                            )
                            let prefixChars = liveConversationTurns
                                .prefix(nativePrefixCount)
                                .reduce(0) { $0 + approximateTurnChars($1) }
                            // Why: counting only the prefix hands each result all the room and overflows the request (cloud 400, Ollama drops the
                            // instructions).
                            // The room for a new result is the budget minus everything compaction cannot drop: the protected prefix plus the
                            // recent exchanges it keeps.
                            let keptRecentChars = unremovableRecentExchangeChars(
                                liveConversationTurns, adapter: nativeGen.toolTurnAdapter,
                                protectedPrefixCount: nativePrefixCount,
                                keepRecentExchanges: nativeKeepRecentExchanges)
                            let protectedChars = prefixChars + keptRecentChars
                            let perResultLimit = ToolResultBudget.limit(
                                payloadBudgetChars: input.nativeContextBudgetChars,
                                protectedChars: protectedChars,
                                resultsInBatch: orderedObservations.count
                            )
                            let truncatedObservations = orderedObservations.map { obs in
                                let fitted = ToolResultBudget.fit(obs.result, limit: perResultLimit,
                                                                  strategy: input.cutPolicy.strategy(forTool: obs.toolName))
                                if fitted.count < obs.result.count {
                                    ContextCutLog.post(
                                        cut: .init(toolName: obs.toolName, originalChars: obs.result.count, keptChars: fitted.count),
                                        conversationID: input.conversationID, traceID: input.traceContext.traceID)
                                    logger.info("[TOOLRESULT] '\(obs.toolName)' result cut from \(obs.result.count) to \(fitted.count) chars (limit \(perResultLimit) = payload budget \(input.nativeContextBudgetChars) − protected prefix \(prefixChars) − kept recent exchanges \(keptRecentChars), shared by \(orderedObservations.count) result(s) this step). CONSEQUENCE: the model sees its start and end with a note naming what was omitted and how to fetch it.")
                                }
                                return obs.withResult(fitted)
                            }
                            let sanitizedReasoning: String? = {
                                guard !step.reasoning.isEmpty, step.reasoning != step.thought else { return nil }
                                let s = OutputSanitizer.sanitizeForUI(step.reasoning)
                                return s.isEmpty ? nil : s
                            }()
                            // Serialize the assistant turn from the executed calls only: `executeToolCalls` drops calls without observations, and
                            // a tool_use without a tool_result is a 400 on Claude/OpenAI.
                            let executedCallIds = Set(observations.map(\.toolCallId))
                            let executedCalls = step.toolCalls.filter { executedCallIds.contains($0.id) }
                            liveConversationTurns.append(
                                nativeGen.toolTurnAdapter.assistantTurn(
                                    toolCalls: executedCalls,
                                    reasoning: sanitizedReasoning,
                                    replay: step.reasoningReplay
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

                            // Bound the native payload; pairing is complete here, so dropping the oldest whole exchanges can't orphan an id. The
                            // UI warning and synthesis nudge surface once, since the nudge turn itself grows the payload.
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
                                    ContextCutLog.post(compactedExchanges: droppedNow,
                                                       conversationID: input.conversationID,
                                                       traceID: input.traceContext.traceID)
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

                        var abortTrigger: AbortTrigger?
                        // One value, not three: `AbortTrigger` derives the reason, category and recovery-policy bypass from its `kind`, so
                        // they cannot drift and a new trigger cannot be added without answering for them.

                        for obs in observations {
                            let isSuccess = obs.isSuccess
                            executionSummary.record(toolCallId: obs.toolCallId, toolName: obs.toolName, params: obs.params, output: obs.output, isSuccess: isSuccess, failureCategory: obs.failureCategory)

                            // Route user denials to the dedicated 2-strike counter; other failures use the 3-strike tool-failure counter. Denials
                            // also bump the general counter, so mixed patterns hit the 3-strike limit.
                            let isDenial = obs.failureCategory == .userDenied
                            let resultAction: CircuitBreakerAction = isDenial
                                ? circuitBreaker.recordDenial()
                                : circuitBreaker.recordToolResult(isSuccess: isSuccess)

                            if case .abort(let trigger) = resultAction {
                                abortTrigger = trigger
                            }

                            // Only genuinely hallucinated names (not in the registry) enter the "DO NOT USE" ban list; ordinary failures (not
                            // found, timeouts, denials) are retryable by design.
                            if obs.failureCategory == .notFound {
                                circuitBreaker.recordHallucination(obs.toolName)
                            }
                        }

                        // Clarification loops aren't counter-governed: identical re-asks are replayed from RunInteractionMemory and caught by
                        // the repetition detection below; distinct questions are bounded by the human and the iteration budget.

                        // Check whether this iteration's observations are identical to previous ones; catches "successful but useless" loops
                        // (same tool, empty args, same result).
                        let repetitiveAction = circuitBreaker.evaluateRepetitiveActions(observations)
                        switch repetitiveAction {
                        case .abort(let trigger):
                            abortTrigger = trigger
                        case .proceedWithWarning(let uiMessage, let modelAlert):
                            // Dual-channel imminent-abort signal: the UI gets a terse chip so the human can intervene, and the model gets a
                            // directive alert in the next prompt's working memory so it can course-correct before the hard abort.
                            continuation.yield(.warning(category: .circuitBreaker, message: uiMessage))
                            memoryStrategy.recordSystemAlert(msg: modelAlert)
                            if let adapter = nativeGenerator?.toolTurnAdapter {
                                liveConversationTurns.append(adapter.systemAlertTurn(message: modelAlert))
                            }
                        case .intervene(let systemMessage):
                            // No current producer returns .intervene from this evaluation, but a breaker directive must never be silently dropped:
                            // route it like any other model alert.
                            memoryStrategy.recordSystemAlert(msg: systemMessage)
                            if let adapter = nativeGenerator?.toolTurnAdapter {
                                liveConversationTurns.append(adapter.systemAlertTurn(message: systemMessage))
                            }
                        case .proceed:
                            break
                        }

                        if let abortTrigger {
                            let abortReason = abortTrigger.reason
                            // Consult ErrorRecovery.onToolFailure only for kinds the policy governs; `honoursToolFailurePolicy` is derived from the
                            // trigger, so it cannot go silently wrong.
                            let effectivePolicy: ToolFailurePolicy = abortTrigger.honoursToolFailurePolicy
                                ? input.errorRecovery.onToolFailure
                                : .abort
                            logger.info("[BREAKER] \(abortTrigger.category.rawValue) requested an abort — conv \(input.conversationID.uuidString.prefix(8)), policy: \(effectivePolicy). CONSEQUENCE: \(effectivePolicy == .abort ? "the run STOPS here" : "the run CONTINUES with a corrective alert; the breaker's request was downgraded by the profile's ErrorRecovery tolerance").")
                            switch effectivePolicy {
                            case .skipAndContinue:
                                // Log the failure but let the agent continue reasoning
                                if announcedLoopWarnings.insert(abortTrigger.announcementKey).inserted {
                                    continuation.yield(.warning(category: .circuitBreaker,
                                                                message: abortTrigger.continuingWarning))
                                }
                                // The trigger's own wording, never a generic "tools failed".
                                let skipAlert = "\(abortTrigger.modelNarrative) Continue with the information you already have."
                                memoryStrategy.recordSystemAlert(msg: skipAlert)
                                if let adapter = nativeGenerator?.toolTurnAdapter {
                                    liveConversationTurns.append(adapter.systemAlertTurn(message: skipAlert))
                                }
                                // Don't abort — fall through to next iteration

                            case .fallbackPrompt:
                                // Inject a fallback hint and let the agent try a different approach. A loop here emits a real warning once per loop
                                // and the run continues; a `.thought` notice was too easy to miss.
                                if announcedLoopWarnings.insert(abortTrigger.announcementKey).inserted {
                                    continuation.yield(.warning(category: .circuitBreaker,
                                                                message: abortTrigger.continuingWarning))
                                }
                                let userMessage = input.errorRecovery.fallbackMessage ?? ErrorRecovery.defaultFallbackMessage
                                // The narrative comes from the trigger, which knows whether anything failed: a generic "tools are failing" line
                                // misleads the model when every call of a repetition loop succeeded.
                                let fallbackAlert = "\(abortTrigger.modelNarrative) \(userMessage)"
                                memoryStrategy.recordSystemAlert(msg: fallbackAlert)
                                if let adapter = nativeGenerator?.toolTurnAdapter {
                                    liveConversationTurns.append(adapter.systemAlertTurn(message: fallbackAlert))
                                }
                                // Don't abort — fall through to next iteration

                            case .abort:
                                // Circuit-breaker abort path. Classify before emitting the user-facing warning so the chain ID is available for
                                // correlation; `abortCategory` carries the trigger (.cbRepetitiveAction, .cbIdleLimit).
                                executionSummary.markComplete(failureReason: abortReason)
                                let classified = ClassifiedAgentError.synthetic(
                                    category: abortTrigger.category,
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
                                // A circuit-breaker abort does not force synthesis: the warning event, failed tool rows and terminal reason already
                                // communicate it, and forcing the IC model would override the user's opt-in.
                                let response = await ResponseSynthesizer.synthesize(
                                    summary: executionSummary,
                                    personaInstructions: input.instructions,
                                    originalQuery: input.userInput,
                                    synthesisOptedIn: input.responseSynthesisEnabled,
                                    suppressLLM: input.suppressLLMSynthesis,
                                    onUsage: { accumulatedTokenUsage.accumulate($0) }
                                )
                                if !input.suppressEpisodeManagement {
                                    sessionState.closeActiveEpisode(outcome: .failed, message: response)
                                    await SessionGraphStore.shared.updateActiveState(conversationID: input.conversationID, state: sessionState)
                                    logState.info("💾 Auto-Patched Active Episode to: FAILED")
                                }
                                continuation.yield(.content(response))
                                flushTokenUsage()
                                // Degraded success: the breaker stopped the run but a usable best-effort answer exists, so surface "completed with
                                // warnings" and keep the output. Empty synthesis is a true failure; the episode stays `.failed`.
                                let degraded = !response.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                                continuation.yield(.executionFinished(
                                    outcome: degraded ? .completedWithWarnings : .failed,
                                    reason: abortReason
                                ))
                                continuation.finish()
                                return
                            }
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

                        // Natural fall-through to the next iteration — the tenth and last
                        // deliberate exit of the loop body (see the flag's declaration above).
                        iterationFinishedNormally = true
                    } // End While Loop

                    // Check for cancellation before post-loop synthesis: a cancel during the in-flight response would otherwise synthesize
                    // after the continuation closed, silently dropping the content.
                    try Task.checkCancellation()

                    // --- Post-Loop Handoff ---
                    let iterationExhausted = currentIteration >= self.maxIterations && !reachedAnswer
                    // The other budget: the parse-loop guard ended the loop. Same policy as running out of iterations (a spent retry
                    // budget, no answer); the two never coincide since `.maxIterationsReached` comes first.
                    let formatExhausted: String? = iterationExhausted ? nil : formatCorrectionsExhausted
                    let budgetExhaustedReason: String? = iterationExhausted
                        ? "Reached maximum allowed steps (\(maxIterations)) without completion."
                        : formatExhausted

                    if let exhaustionReason = budgetExhaustedReason {
                        // Consult ErrorRecovery.onIterationExhaustion policy
                        switch input.errorRecovery.onIterationExhaustion {
                        case .failHard:
                            // Fail immediately without synthesis
                            let failureMsg = exhaustionReason
                            executionSummary.markComplete(failureReason: failureMsg)
                            if !input.suppressEpisodeManagement {
                                sessionState.closeActiveEpisode(outcome: .failed, message: failureMsg)
                                await SessionGraphStore.shared.updateActiveState(conversationID: input.conversationID, state: sessionState)
                                logState.info("💾 Auto-Patched Active Episode to: FAILED (failHard)")
                            }
                            // Structured error telemetry for a fatal exit path: `.synthetic(...)` carries the category and chainID. Iterations
                            // only; the parse-loop guard already emitted its own `.parseExhausted` error.
                            if iterationExhausted {
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
                            }
                            continuation.yield(.error(.init(failureMsg)))
                            flushTokenUsage()
                            continuation.yield(.executionFinished(outcome: .failed, reason: failureMsg))
                            continuation.finish()
                            return

                        case .synthesizeBestEffort:
                            // Default: synthesize best response from accumulated work
                            executionSummary.markComplete(failureReason: exhaustionReason)
                        }
                    } else {
                        executionSummary.markComplete()
                    }

                    // --- UI Progress: Synthesis ---
                    continuation.yield(.thought("Composing final response…"))

                    // Only unrecovered evidence failures drive outcome honesty and synthesis routing: user decisions (denied confirmation,
                    // skipped ask_user) are choices, and a failure retried to success is a recovered blip.
                    let allResults = executionSummary.toolResults
                    let effectiveFailures = allResults.enumerated().filter { index, result in
                        guard !result.isSuccess else { return false }
                        if result.failureCategory == .userDenied || result.failureCategory == .cancelled {
                            return false
                        }
                        // Recovered = a later success repeated the same call. Order matters: an earlier success with identical args is another
                        // sub-goal, and masking a trailing failure behind it would turn an amber run green.
                        let recovered = allResults[(index + 1)...].contains {
                            $0.isSuccess && $0.toolName == result.toolName && $0.params == result.params
                        }
                        return !recovered
                    }.map { $0.element }

                    let response = await ResponseSynthesizer.synthesize(
                        summary: executionSummary,
                        personaInstructions: input.instructions,
                        originalQuery: input.userInput,
                        isNativeFlow: input.generatorStrategy is NativeStructuredGenerator,
                        // Opt-in only: `effectiveFailures` does not force synthesis (it would hand a complete answer to the IC model); it
                        // drives the terminal outcome and reason below, which the UI consumes.
                        synthesisOptedIn: input.responseSynthesisEnabled,
                        suppressLLM: input.suppressLLMSynthesis,
                        onUsage: { accumulatedTokenUsage.accumulate($0) }
                    )

                    // Single typed source of truth for the terminal outcome, derived from the run's factual record: unrecovered evidence
                    // failures give `.completedWithWarnings`, a tool-less prose answer stays `.completed`.
                    let terminalOutcome: ExecutionOutcome = {
                        if budgetExhaustedReason != nil {
                            let hasBestEffort = !response.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                            return hasBestEffort ? .completedWithWarnings : .failed
                        }
                        return effectiveFailures.isEmpty ? .completed : .completedWithWarnings
                    }()

                    let terminalReason: String? = {
                        if iterationExhausted {
                            return "Reached maximum iterations (\(maxIterations)) without explicit completion"
                        }
                        if let formatExhausted { return formatExhausted }
                        guard !effectiveFailures.isEmpty else { return nil }
                        let names = Set(effectiveFailures.map(\.toolName)).sorted().joined(separator: ", ")
                        let evidenceCount = executionSummary.evidenceResults.count
                        return "\(effectiveFailures.count) of \(evidenceCount) tool call(s) failed (\(names))"
                    }()

                    // Episode outcome follows the stream outcome. SessionGraph's EpisodeOutcome mapping (`completedWithWarnings →
                    // .failed`) keeps episodic memory conservative, so degraded runs are never stored as clean recipes.
                    let episodeOutcome: ExecutionOutcome = terminalOutcome

                    if !input.suppressEpisodeManagement {
                        sessionState.closeActiveEpisode(outcome: episodeOutcome, message: response)
                        await SessionGraphStore.shared.updateActiveState(conversationID: input.conversationID, state: sessionState)
                        logState.info("💾 Auto-Patched Active Episode to: \(episodeOutcome.rawValue.uppercased())")
                    }

                    // `iterations` carries the authoritative loop counter and `outcome` the terminal verdict to EvaluationLogger; the
                    // event-derived count drifts and a bare finalizing event must not imply success.
                    let finalizingContent: String = {
                        switch terminalOutcome {
                        case .completed:
                            return "Task completed successfully."
                        case .completedWithWarnings:
                            return "Task completed with warnings" + (terminalReason.map { ": \($0)" } ?? ".")
                        case .failed, .cancelled:
                            return "Task failed or reached max iterations."
                        case .timedOut:   // never emitted by an executor; listed for exhaustiveness
                            return "Task stopped at its execution limit."
                        }
                    }()
                    onTraceUpdate(AgentTraceLog(
                        traceID: input.traceContext.traceID,
                        spanID: input.traceContext.spanID,
                        parentSpanID: input.traceContext.parentSpanID,
                        stepNumber: currentIteration,
                        state: .thinking(.finalizing),
                        content: finalizingContent,
                        metadata: [
                            "iterations": "\(currentIteration)",
                            "outcome": terminalOutcome.rawValue
                        ]
                    ))

                    logger.info("--- 🏁 REACT EXECUTION COMPLETE 🏁 ---")
                    logger.info("Model: \(model.modelName)")
                    logger.info("Final Synthesized Response: \(response.count) chars") // the reply is content; full text is logged at debug only
                    logger.debug("Final Synthesized Response: \(response)")
                    logger.info("--------------------------------------")

                    // Emit accumulated token usage before finishing
                    if accumulatedTokenUsage.totalTokens > 0 {
                        continuation.yield(.tokenUsage(accumulatedTokenUsage))
                    }

                    continuation.yield(.content(response))
                    continuation.yield(.executionFinished(outcome: terminalOutcome, reason: terminalReason))
                    continuation.finish()

                } catch is CancellationError {
                    // Name whose run died and how far it got, so the line can be tied to a node, a conversation and the work it abandoned.
                    logger.notice("🚫 Execution Task Cancelled cleanly — \(input.workflowContext.map { "workflow node '\($0.nodeName)' [\($0.nodeID.uuidString.prefix(8))]" } ?? "chat run") conv \(input.conversationID.uuidString.prefix(8)), torn down during iteration \(currentIteration). CONSEQUENCE: partial progress is discarded; the outcome (Stop vs node timeout vs per-node skip) is decided by whoever cancelled this task, not here.")
                    // Node-scoped when this run is a workflow node: the conversation-wide drain force-resolves every park in the
                    // conversation, including a sibling node's. Chat and code runs have no `workflowContext` and sweep conversation-wide.
                    if let nodeID = input.workflowContext?.nodeID {
                        await ExecutionSuspensionService.shared.cancelNode(nodeID, in: input.conversationID)
                    } else {
                        await ExecutionSuspensionService.shared.cancel(for: input.conversationID)
                    }
                    if !input.suppressEpisodeManagement {
                        sessionState.cancelActiveEpisode()
                        await SessionGraphStore.shared.updateActiveState(conversationID: input.conversationID, state: sessionState)
                    }
                    continuation.yield(.thought("Cancelled by user."))
                    // Report the honest terminal outcome to the session summary; otherwise a user Stop is rolled up as a failure instead
                    // of cancelled.
                    onTraceUpdate(AgentTraceLog(
                        traceID: input.traceContext.traceID,
                        spanID: input.traceContext.spanID,
                        parentSpanID: input.traceContext.parentSpanID,
                        stepNumber: 0,
                        state: .thinking(.finalizing),
                        content: "Cancelled by user.",
                        metadata: ["outcome": ExecutionOutcome.cancelled.rawValue]
                    ))
                    // Emit a content placeholder so the message bubble isn't left empty, which would look as if the agent completed
                    // normally.
                    continuation.yield(.content("*Operation stopped by user.*"))
                    flushTokenUsage()
                    continuation.yield(.executionFinished(outcome: .cancelled, reason: "User stopped the run"))
                    continuation.finish()
                } catch {
                    // Classify the fatal error so analytics can bucket unexpected throws. Typed retrieval failures (e.g. an unresolvable
                    // attached image) carry a precise category; everything else buckets as .toolSystemCrash.
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
                    // Node-scoped when this run is a workflow node: the conversation-wide drain force-resolves every park in the
                    // conversation, including a sibling node's. Chat and code runs have no `workflowContext` and sweep conversation-wide.
                    if let nodeID = input.workflowContext?.nodeID {
                        await ExecutionSuspensionService.shared.cancelNode(nodeID, in: input.conversationID)
                    } else {
                        await ExecutionSuspensionService.shared.cancel(for: input.conversationID)
                    }
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

/// Logger for the file-scope native-turn helpers, which have no `self` to borrow one from.
fileprivate let nativeTurnLogger = Logger(subsystem: DGLogger.subsystem, category: "NativeTurns")

/// Approximate serialized character footprint of a native turn dict, summing string lengths and keys recursively, to
/// budget `liveConversationTurns` without full JSON serialization. Images are charged flat via `ImageTokenHeuristic`,
/// not at base64 length, which would make one screenshot look like a ~14x overflow.
func approximateTurnChars(_ value: Any) -> Int {
    approximateTurnChars(value, key: nil)
}

/// Keys under which each provider adapter parks image bytes: Ollama `images`, Gemini `inlineData`, OpenAI `image_url`.
/// Claude nests its payload under `source` with `type == base64`, matched structurally rather than by key (too
/// generic).
private func isImagePayloadKey(_ key: String) -> Bool {
    key == "images" || key == "inlineData" || key == "image_url"
}

private func approximateTurnChars(_ value: Any, key: String?) -> Int {
    if let key, isImagePayloadKey(key) {
        return imagePayloadChars(value)
    }
    switch value {
    case let s as String:
        // OpenAI inlines an image as a `data:` URL string.
        if s.hasPrefix("data:image/") { return ImageTokenHeuristic.budgetCharsPerImage }
        return s.count
    case let dict as [String: Any]:
        // Claude: {"type": "base64", "media_type": …, "data": <base64>}
        if (dict["type"] as? String) == "base64" { return ImageTokenHeuristic.budgetCharsPerImage }
        return dict.reduce(0) { $0 + $1.key.count + approximateTurnChars($1.value, key: $1.key) }
    case let array as [Any]:
        // Carry the parent key down so `"images": [b64, b64]` charges per element.
        return array.reduce(0) { $0 + approximateTurnChars($1, key: key) }
    case let number as NSNumber:
        return number.stringValue.count
    default:
        return 0
    }
}

private func imagePayloadChars(_ value: Any) -> Int {
    if let array = value as? [Any] {
        return array.count * ImageTokenHeuristic.budgetCharsPerImage
    }
    return ImageTokenHeuristic.budgetCharsPerImage
}

/// Chars of the turns after the protected prefix that `compactNativeConversation` can never drop once the next exchange
/// is appended: what a new tool result must leave room for. Mirrors that function's rule (it keeps the newest
/// `keepRecentExchanges` whole exchanges); keep the two together.
func unremovableRecentExchangeChars(
    _ turns: [[String: Any]],
    adapter: any ToolTurnAdapter,
    protectedPrefixCount: Int,
    keepRecentExchanges: Int
) -> Int {
    let prefix = min(max(0, protectedPrefixCount), turns.count)
    let keepPrior = max(1, keepRecentExchanges) - 1
    let starts = (prefix..<turns.count).filter { adapter.classifyTurn(turns[$0]) == .toolCallAssistant }
    // After the append there will be `starts.count + 1` exchanges; compaction drops none unless that
    // exceeds the keep-floor.
    let from = starts.count + 1 <= max(1, keepRecentExchanges) ? prefix : starts[starts.count - keepPrior]
    return turns[from...].reduce(0) { $0 + approximateTurnChars($1) }
}

// Why: cuts fall only on exchange boundaries, so an assistant tool call is never separated from its results (providers reject that).
/// Compacts the native conversation when it outgrows `budgetChars`: drops the oldest whole tool exchanges and
/// replaces them with one summary turn. Returns how many exchanges were dropped (0 when nothing can be dropped safely).
/// The protected prefix and the newest `keepRecentExchanges` exchanges are never touched.
func compactNativeConversation(
    _ turns: inout [[String: Any]],
    adapter: any ToolTurnAdapter,
    budgetChars: Int,
    protectedPrefixCount: Int,
    keepRecentExchanges: Int,
    cumulativeDropped: Int
) -> Int {
    guard budgetChars > 0 else { return 0 }
    // Always keep at least one recent exchange: a keep-floor of 0 would index `exchangeStarts[count]` out of bounds below.
    // Production passes 3; the clamp hardens the exposed internal helper.
    let keepRecent = max(1, keepRecentExchanges)
    let totalChars = turns.reduce(0) { $0 + approximateTurnChars($1) }
    guard totalChars > budgetChars else { return 0 }

    // Exchange-start indices = assistant(tool_calls) turns after the protected prefix.
    let prefix = min(max(0, protectedPrefixCount), turns.count)
    var exchangeStarts: [Int] = []
    for i in prefix..<turns.count where adapter.classifyTurn(turns[i]) == .toolCallAssistant {
        exchangeStarts.append(i)
    }
    // Needs more exchanges than we promise to keep, else nothing is safely droppable. This is the dead end: over budget
    // and unable to shrink, so the request ships anyway and the provider decides.
    guard exchangeStarts.count > keepRecent else {
        nativeTurnLogger.warning("[NATIVE] Payload is \(totalChars) chars against a \(budgetChars) budget but only \(exchangeStarts.count) droppable exchange(s) exist (keep-floor \(keepRecent)) — CANNOT compact. Sending over budget; expect a provider context-length error.")
        return 0
    }

    // Drop oldest exchanges until under budget, never below the keep-recent floor. `cut` walks forward to the first kept
    // exchange; everything in [prefix, cut) is removed.
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

/// Reorders observations to match the positional order of the assistant's original `PendingToolCall`s. Gemini matches
/// `functionResponse` to `functionCall` by position, so out-of-order TaskGroup completion would mismatch; Claude and
/// OpenAI match by id, and sorting uniformly is cheap.
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

/// Locates the contiguous run of `block` inside `haystack`, returning its start index. History turns are appended in
/// one `append(contentsOf:)`, so they are contiguous; matching on content stays correct if prompt layers change shape,
/// and a failed match degrades to no history images.
fileprivate func locateTurnBlock(_ block: [[String: String]], in haystack: [[String: String]]) -> Int? {
    guard !block.isEmpty, haystack.count >= block.count else { return nil }
    for start in 0...(haystack.count - block.count) where Array(haystack[start..<(start + block.count)]) == block {
        return start
    }
    return nil
}

/// Splices prior-turn images into the already-normalized history turns, returning the number spliced and omitted.
/// History reaches the native path as text-only `[[String: String]]`, so images are re-attached here. Unlike the
/// current turn, an unreadable history image is logged and omitted, not thrown.
fileprivate func spliceHistoryImages(
    into turns: inout [[String: Any]],
    historyTurns: [HistoryTurn]?,
    canonical: [[String: String]],
    adapter: any ToolTurnAdapter,
    correlation: String
) async -> (spliced: Int, omitted: Int) {
    let logger = nativeTurnLogger
    guard let historyTurns, !historyTurns.isEmpty else { return (0, 0) }
    let totalImages = historyTurns.totalImageCount
    guard totalImages > 0 else { return (0, 0) }

    guard let offset = locateTurnBlock(historyTurns.asWireDicts(), in: canonical) else {
        logger.warning("[HISTORY] \(correlation) could not locate the \(historyTurns.count)-turn history block inside the compiled prompt — omitting all \(totalImages) prior-turn image(s); the model will answer without seeing them")
        return (0, totalImages)
    }

    var spliced = 0
    var omitted = 0

    for (index, turn) in historyTurns.enumerated() {
        let images = turn.imageMedia
        guard !images.isEmpty else { continue }

        let target = offset + index
        // Bound read into a local: `turns` is `inout`, and os.Logger's interpolation
        // is an autoclosure, which cannot capture it.
        let liveTurnCount = turns.count
        guard target < liveTurnCount else {
            omitted += images.count
            logger.warning("[HISTORY] \(correlation) history turn \(index) maps past the end of the live turn array (\(target) >= \(liveTurnCount)) — omitting \(images.count) image(s); the model will not see them")
            continue
        }

        var resolved: [ResolvedImage] = []
        for image in images {
            // Resolve the bytes, then normalize to something every provider can load: a replayed history image with an unsupported
            // media_type (e.g. HEIC) is transcoded to JPEG by `resolveSendable`; only the undecodable is omitted.
            do {
                let data = try await image.reference.resolve()
                guard let sendable = VisionImageFormat.resolveSendable(data: data) else {
                    omitted += 1
                    logger.warning("[HISTORY] \(correlation) omitted image '\(image.label ?? "unnamed")' (history turn \(index)): bytes are not a decodable image, cannot transcode — the model will not see it; it remains visible in the transcript.")
                    continue
                }
                if sendable.wasTranscoded {
                    logger.info("[HISTORY] \(correlation) transcoded prior-turn image '\(image.label ?? "unnamed")' (history turn \(index)) → image/jpeg for provider compatibility")
                }
                resolved.append(ResolvedImage(mimeType: sendable.mimeType, base64: sendable.data.base64EncodedString()))
            } catch {
                omitted += 1
                logger.warning("[HISTORY] \(correlation) omitted image '\(image.label ?? "unnamed")' (history turn \(index)): \(error.localizedDescription) — the model will not see this image; it remains visible in the transcript")
            }
        }

        guard !resolved.isEmpty else { continue }
        turns[target] = adapter.userTurn(text: turn.text, images: resolved)
        spliced += resolved.count
    }

    return (spliced, omitted)
}

/// Pre-resolves attached image payloads to base64 for the agent's native kickoff user turn (adapters are synchronous).
/// Throws if an image can't be retrieved, surfaced as an execution error, never a silent drop. Unlike
/// `spliceHistoryImages`, which omits, a just-attached image must fail loudly.
fileprivate func resolveUserImages(_ payload: Payload?) async throws -> [ResolvedImage] {
    guard let payload else { return [] }
    var resolved: [ResolvedImage] = []
    for block in payload {
        guard case .image(let img) = block else { continue }
        let data: Data
        do {
            data = try await img.reference.resolve()
        } catch {
            // Throw a typed retrieval failure so it renders as a categorized "Image Read Failed" card (icon + remediation) rather
            // than a generic crash, as the chat attachment path does.
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



// MARK: - Draft streaming

extension ReActAgentExecutor {
    /// Whether this run streams provisional step text. Off when the user turned streaming off, and in
    /// workflow nodes, whose events are forwarded selectively and never render a draft.
    static func streamsDrafts(for input: AgentInput) -> Bool {
        guard input.workflowContext == nil else { return false }
        let defaults = UserDefaults.standard
        // Unset means the app default, which is ON (`SettingsCoordinator`).
        guard defaults.object(forKey: AppSettings.useStreamingResponseKey) != nil else { return true }
        return defaults.bool(forKey: AppSettings.useStreamingResponseKey)
    }
}

/// Turns a model's text deltas into throttled, cumulative `.draftText` events for one step. Cumulative, so dropping an
/// intermediate emission loses nothing; throttled to `interval` since a cloud model sends a token every few
/// milliseconds. Thread-safe: the provider calls `onTextDelta` from its stream loop.
final class DraftTextRelay: @unchecked Sendable {
    private let enabled: Bool
    private let interval: TimeInterval
    private let emit: @Sendable (String) -> Void
    private let lock = NSLock()
    private var text = ""
    private var lastEmit = Date.distantPast
    private var emittedText: String?

    init(enabled: Bool, interval: TimeInterval = 0.1, emit: @escaping @Sendable (String) -> Void) {
        self.enabled = enabled
        self.interval = interval
        self.emit = emit
    }

    /// Nil when disabled, so the generator makes the ordinary blocking call.
    var onTextDelta: (@Sendable (String) -> Void)? {
        guard enabled else { return nil }
        return { [weak self] delta in self?.append(delta) }
    }

    private func append(_ delta: String) {
        lock.lock()
        text += delta
        let now = Date()
        let due = now.timeIntervalSince(lastEmit) >= interval
        if due { lastEmit = now; emittedText = text }
        let snapshot = text
        lock.unlock()
        if due { emit(snapshot) }
    }

    /// Emits any text the throttle held back, so the draft shows the whole answer until `.content`
    /// replaces it.
    func flush() {
        lock.lock()
        let pending = emittedText != nil && emittedText != text ? text : nil
        if pending != nil { emittedText = text }
        lock.unlock()
        if let pending { emit(pending) }
    }

    /// Withdraws the draft if one was shown: the step was monologue before tool calls (it reaches the
    /// timeline via `.reasoning`), an unparseable output, or it failed.
    func withdraw() {
        lock.lock()
        let shown = emittedText != nil
        emittedText = nil
        text = ""
        lock.unlock()
        if shown { emit("") }
    }
}
