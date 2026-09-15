// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2026 Raj Singh
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
    // Internal (not private) so ExecutorFactoryTests can assert the configured
    // limit is actually threaded — the .code fallthrough bug was invisible
    // precisely because this value couldn't be observed from outside.
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
                // Declared ABOVE the `do` so the CancellationError catch can report how far the
                // run got — a teardown line with no iteration count could not be tied back to
                // the abandoned work.
                var currentIteration = 0
                do {
                    logger.info("🚀 ReAct Execution Initiated. Model Instance: \(String(describing: model))")

                    // Per-call LLM spans: the scope tells the spy which STEP span to parent
                    // each model call under; the loop updates it as it opens each iteration
                    // span. Before the first iteration it carries the root context, so a
                    // pre-loop call would still parent somewhere real.
                    let llmSpanScope = LLMSpanScope(input.traceContext)
                    let spyModel = APISpyModel(inner: model, spanScope: llmSpanScope)

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
                        maxRepetitiveActions: input.resiliencePolicy.loop.maxRepetitiveActions,
                        maxConsecutiveDenials: input.resiliencePolicy.loop.maxConsecutiveDenials
                    )
                    // [Loop Safety] Per-run memory of human interactions: replays identical
                    // clarification answers and auto-denies identical declined requests, so
                    // the user is never asked the same thing twice in one run. A capability
                    // wrapper (Planning/Reflexion) may pass a SHARED instance so answers —
                    // including the pre-plan clarification — carry across subtasks/trials.
                    let interactionMemory = input.interactionMemory ?? RunInteractionMemory()
                    // The wire format THIS run parses back, and the source for BOTH corrective
                    // alerts — `LLMRetryStrategy`'s (thrown, unclassified errors) and
                    // `ParseFailureReason.modelCorrectiveAlert`'s (the typed parse failures a
                    // generator RETURNS). One local so the two can never name different formats
                    // for the same run.
                    //
                    // Taken from the generator rather than from `ProviderConfig`, because the
                    // generator is what actually parses the response — and on the `.singleAction`
                    // path (AgentConnect.swift:985-994) the two disagree by design: the profile's
                    // stored dialect is discarded there and every model is asked for ReAct
                    // markdown. Reading the profile would teach the model the format nothing in
                    // the run is prepared to parse. nil on native flows, which is correct.
                    let runDialect = input.generatorStrategy.expectedDialect
                    var retryStrategy = LLMRetryStrategy(
                        maxConsecutiveParseFailures: input.resiliencePolicy.cognitive.maxParseFailures,
                        backoffStrategy: input.resiliencePolicy.transport.backoffStrategy,
                        transport: input.resiliencePolicy.transport,
                        dialect: runDialect
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
                    // Narrowed to what THIS run actually registered. The filter below was
                    // already a no-op for a non-Code profile, but the unlock branch was not:
                    // an ordinary Agent run has no `update_project_context`, yet the first
                    // successful read still fired the gate and injected the Code interface's
                    // "use update_project_context to persist findings into .devgentic/
                    // context.md" instructions. Field-observed 2026-07-25: the agent obeyed
                    // them, found no such tool, reached for `write_file` instead, and wrote
                    // a project-context document to ~/.devgentic/context.md rather than
                    // editing the file the user had asked about.
                    let gatedToolNames: Set<String> = Set(["update_project_context"])
                        .intersection(input.tools.map(\.name))
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
                    // per iteration.
                    //
                    // ⚠️ WORKFLOW NODES GET THIS TOO (owner decision, 2026-08-20). It used to be
                    // suppressed under `input.workflowContext == nil` on the reasoning that "nodes
                    // use task+input, not personal context" — but a node runs the user's own agent
                    // profile on the user's behalf, and the personal layer carries their skills and
                    // guardrails, which do not stop applying because the caller was a canvas. The
                    // layer stays gated behind the Core Intelligence user-personal toggle (default
                    // OFF), so this changes nothing for anyone who has not opted in.
                    //
                    // ⚠️ TWO GATES, NOT ONE. `PromptLayerConfig.workflow.includeUserProfile` gates
                    // the same layer at the prompt-assembly seam. Flipping only one leaves the value
                    // nil-but-permitted or permitted-but-nil — both render nothing, silently.
                    let userProfile: String? = await MainActor.run {
                        guard UserDefaults.standard.bool(forKey: AppSettings.ciFeatureUserPersonalKey) else { return nil }
                        return UserPersonalService.shared.getProfileForInjection()
                    }

                    // --- Start Episode ---
                    // [G3/G5] When wrapped by a capability (Planning, Reflexion), the wrapper
                    // owns the episode lifecycle. Skip to avoid N+1 duplicate episodes.
                    // [G1 Piece 2] On resume, the original run already opened an active episode (loaded
                    // from SessionGraphStore above); appending a second would double-count. The resumed
                    // run continues that episode and closes it normally at the end.
                    if !input.suppressEpisodeManagement && input.resumeState == nil {
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
                        // The limiter swallows sleep interruption internally (its wait is
                        // non-throwing); surface a Stop pressed during a long cloud debt
                        // wait here instead of firing another generation.
                        try Task.checkCancellation()

                        let iterationSpan = executionTrace.newSpan()
                        let iterationMetadata: [String: String] = ["iteration": "\(currentIteration)"]
                        
                        await TraceRecorder.shared.beginSpan(context: iterationSpan, name: "iteration_\(currentIteration)", kind: .iteration)
                        // This iteration's model calls parent under THIS step span.
                        llmSpanScope.set(iterationSpan)
                        // Input-lane clock (Run-Report Phase 3): everything between here and
                        // the model call is prompt/context assembly — the report's Input lane.
                        let contextBuildStart = Date()

                        // Honest per-iteration status: continue/break-to-cognitiveLoop are the
                        // loop's DELIBERATE exits (retry, final answer) and each sets this flag
                        // inline; the seven mid-body `return`s are all failure terminals and any
                        // throw (Stop, provider fatal) unwinds past them — both leave it false,
                        // so an aborted iteration finally records `.error` instead of the old
                        // hardcoded `.completed`. `endedAt` is captured HERE, synchronously in
                        // the defer, so the persisted end is the real end even when this
                        // fire-and-forget write loses the race against endTrace's clamp
                        // (earliest-wins in TraceStore.updateSpan).
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
                        // Prompt-builder telemetry (Run-Report Phase 3): CONTEXT-injection
                        // events attribute to this iteration's span.
                        context.traceContext = iterationSpan

                        // G12: Seed native conversation turns on iter 1. System prompt and
                        // history are built via PromptBuilder (no working_memory), normalized
                        // to the provider's shape, then the kickoff user message carrying the
                        // original query is appended. Subsequent iterations only APPEND
                        // assistant/tool turns — the prefix stays byte-stable.
                        if currentIteration == 1, let nativeGen = nativeGenerator {
                            let canonicalMessages = nativeGen.compileMessages(from: context)
                            liveConversationTurns = canonicalMessages.map { nativeGen.toolTurnAdapter.normalizeCanonical(message: $0) }

                            // Re-attach prior-turn images. `compileMessages` returns
                            // `[[String: String]]`, so history arrives here text-only even
                            // when the user attached images two turns ago — that erasure is
                            // why a follow-up question used to get "no image was provided".
                            // Text-only histories no-op here and stay byte-identical.
                            let (historyImagesSpliced, historyImagesOmitted) = await spliceHistoryImages(
                                into: &liveConversationTurns,
                                historyTurns: input.nativeHistoryTurns,
                                canonical: canonicalMessages,
                                adapter: nativeGen.toolTurnAdapter,
                                correlation: "trace:\(input.traceContext.traceID)"
                            )

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
                            // Attachments ride the kickoff turn here because compileMessages
                            // excludes them on the native path (includeAttachmentContext: false).
                            // Both parts are nil/empty on unseeded, attachment-free runs, so the
                            // kickoff stays byte-identical (KV-cache prefix unchanged).
                            let kickoffText: String = {
                                var parts: [String] = []
                                if hasSeededContext {
                                    parts.append(PromptWrapping.xml.section("prior_context", content: seededContext))
                                }
                                if let attachments = input.attachmentContext, !attachments.isEmpty {
                                    parts.append(attachments)
                                }
                                // ⚠️ NOT on the workflow path (register EIO-2). A workflow node's
                                // input already rides the user message `compileMessages` built from
                                // `workflowContext.userMessagePrefix` — `<input>`-wrapped, escaped,
                                // with the attachment manifest and document sections the system
                                // prompt's security note refers to. Appending `input.userInput`
                                // here re-sent the SAME payload raw in a second consecutive user
                                // turn: 10 KB of upstream became 20 KB per request, in two
                                // encodings, on every iteration of every retry. Same rationale as
                                // `includeWorkingMemory: false` / `includeAttachmentContext: false`
                                // in `NativeStructuredGenerator.compileMessages`, from the other
                                // side of the seam: each payload gets exactly one carrier.
                                if input.workflowContext == nil {
                                    parts.append(input.userInput)
                                }
                                return parts.joined(separator: "\n\n")
                            }()

                            // Pre-resolve attached image bytes (async) so the sync adapter
                            // can serialize them into the kickoff user turn natively. Empty
                            // → byte-identical text turn (KV-cache prefix unchanged). A failed
                            // resolve throws → surfaced as an execution error, never dropped.
                            let resolvedUserImages = try await resolveUserImages(input.userPayload)
                            // ⚠️ Skip an EMPTY kickoff turn — now reachable, because a workflow
                            // node with no seeds and no attachments contributes nothing above. The
                            // prefix user message from `compileMessages` is already the last seeded
                            // turn, so the request still ends on a user turn; appending an empty
                            // one would send a blank message some providers reject outright.
                            // Images keep the turn: they have no other carrier.
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

                        // [G1 Piece 2] RESUME PREAMBLE — runs on iteration 1 for BOTH the native and the
                        // legacy path. The reconstruction is dialect-agnostic, so we replay the completed
                        // tool exchanges into whichever substrate this run uses:
                        //   • native: append paired assistant→result turns to `liveConversationTurns`;
                        //   • legacy: rely on the working-memory scratchpad the generator rebuilds each
                        //     iteration (records below populate it) — no native turn-array exists.
                        // Both also feed `executionSummary`. Then re-run the parked tool through the normal
                        // HITL path and jump the loop to the parked iteration so the NEXT pass generates N+1.
                        // Because this ALWAYS runs when resumeState is set (native OR legacy), a resumed run
                        // can never silently fall through to a fresh re-run that would duplicate tools.
                        if currentIteration == 1, let recon = input.resumeState {
                            let nativeAdapter = nativeGenerator?.toolTurnAdapter
                            logger.info("⏯️ [Resume] \(nativeAdapter != nil ? "native" : "legacy") replay of \(recon.completedSteps.count) completed step(s); parked=\(recon.parkedTool?.name ?? "none"); resumeIteration=\(recon.resumeIteration)")

                            // 1. Replay completed exchanges. Native: append paired native turns. Both: record
                            //    into working memory + summary (the legacy generator's scratchpad rebuild and
                            //    end-of-run synthesis read these).
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

                                // [Loop Safety] Re-prime the repetition bookkeeping + interaction
                                // memory from the replayed iteration so prevention and the
                                // fingerprint streak survive the park → resume cycle (the breaker
                                // and memory are per-run locals that would otherwise start at zero).
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

                            // 2. Restore the reading-gate counter so gated tools stay unlocked.
                            readingToolSuccessCount = recon.readingToolSuccessCount

                            // 3. Re-run the parked tool via the EXISTING (dialect-agnostic) path — re-raises
                            //    the HITL banner (requestConfirmation/requestClarification → enqueueHITL →
                            //    suspend) and returns the observation once the user responds.
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
                                    if obs.isSuccess && readingToolNames.contains(obs.toolName) { readingToolSuccessCount += 1 }
                                    executionSummary.record(toolCallId: obs.toolCallId, toolName: obs.toolName, params: obs.params, output: obs.output, isSuccess: obs.isSuccess, failureCategory: obs.failureCategory)
                                    memoryStrategy.recordObservation(stepId: obs.stepId, toolCallId: obs.toolCallId, toolName: obs.toolName, params: obs.params, result: obs.result, artifacts: obs.artifacts)
                                }
                            }

                            // 4. Jump to the parked iteration; the loop's `currentIteration += 1` makes the
                            //    next generated step iteration N+1. Iter-1 native seeding won't re-run.
                            currentIteration = recon.resumeIteration
                            iterationFinishedNormally = true; continue cognitiveLoop
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
                            //
                            // ⚠️ ONCE PER RUN, via the same `didInjectFullBudgetAlert` the native
                            // path uses at :1115. That flag's own declaration comment already says
                            // it "gates the synthesis nudge to once (re-appending it every
                            // iteration was the bug this fixes)" — the fix simply never reached
                            // this path, and the two are mutually exclusive (`nativeGenerator ==
                            // nil` guards this block), so one flag correctly means one nudge per
                            // run either way.
                            //
                            // ⚠️ Un-guarded, this was self-reinforcing rather than merely noisy.
                            // The message is a CONSTANT, so every over-budget iteration recorded a
                            // byte-identical alert; each one added ~183 chars to
                            // `budgetUtilization`, which pushed utilization higher, which re-fired
                            // this branch next iteration. In a real 2026-09-13 run the reported
                            // figure climbed 78 → 90 → 101 → 120 → 138 → 157 → 175%, and three
                            // copies of this one sentence were enough to fill every
                            // `maxSystemAlerts` slot — evicting the format correctives that were
                            // the only thing that could have rescued the run.
                            if utilization >= 1.0, !didInjectFullBudgetAlert {
                                didInjectFullBudgetAlert = true
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
                            // Close the Input-lane bracket: context assembly ran from the top
                            // of this iteration to here (the model call starts now).
                            await TraceRecorder.shared.emitMetric(
                                span: iterationSpan,
                                key: "input_assembly",
                                valueMs: Int(genStart.timeIntervalSince(contextBuildStart) * 1000)
                            )
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
                                // `try` (not `try?`): Retry-After can be up to an hour, and a
                                // swallowed CancellationError here made Stop fire a fresh
                                // provider request instead of aborting — the throw propagates
                                // to the CancellationError catch (clean .cancelled exit).
                                if seconds > 0, seconds.isFinite {
                                    try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
                                }
                                currentIteration -= 1
                                iterationFinishedNormally = true; continue cognitiveLoop

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
                                iterationFinishedNormally = true; continue cognitiveLoop

                            case .parseRetry(let systemAlert, let attemptCount, let maxAttempts):
                                memoryStrategy.recordSystemAlert(msg: systemAlert)
                                if let adapter = nativeGenerator?.toolTurnAdapter {
                                    liveConversationTurns.append(adapter.systemAlertTurn(message: systemAlert))
                                }
                                continuation.yield(.warning(category: .parseFailure, message: "Invalid JSON output. Retrying (\(attemptCount)/\(maxAttempts))..."))
                                await GlobalRateLimiter.shared.wait(forKey: input.rateLimitKey, category: input.rateLimitCategory)
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
                                // The UI still shows it. On a failed parse this is the user's ONLY
                                // window onto what the model actually emitted — the raw output is
                                // logged at `.debug`, which never reaches an exported bundle.
                                continuation.yield(.reasoning(sanitized))

                                // ⚠️ NOT written to working memory when the parse FAILED, and that
                                // asymmetry is the whole point of this branch.
                                //
                                // On a typed failure `step.reasoning` is not reasoning at all — it
                                // is the raw unparseable blob (HeuristicCognitiveParser.swift:197
                                // returns `reasoning: rawText`; CognitiveParsePipeline's exhausted
                                // path does the same). Recording it put the model's own malformed
                                // output back in front of it next iteration as `[Step N thought]`,
                                // and the model copied it.
                                //
                                // ⚠️ That is not a theory. In the 2026-09-13 gemma:7b agent run the
                                // scratchpad reached 13 copies of one broken JSON object, and from
                                // iteration 4 on every response contained `“arguments”...[truncated]`
                                // — OUR truncation marker, appended by `perEntryCap` — proving the
                                // model was transcribing its own recorded output rather than
                                // generating. Outputs went byte-identical and the run died on the
                                // identical-output detector at iteration 14, after 75 seconds. The
                                // scratchpad hit 176% of budget carrying nothing but that garbage,
                                // which then evicted the entries that mattered.
                                //
                                // The corrective alert already carries everything the model needs —
                                // that its last output could not be parsed, the attempt count, and
                                // (since invariant 80) the exact format this run CAN read. Re-showing
                                // the unparseable text adds no information and supplies a template to
                                // copy.
                                //
                                // ⚠️ The identical-output detector is unaffected: it reads
                                // `step.reasoning` directly (:825), never working memory, so the
                                // stuck-model abort still fires.
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
                        
                        // --- Termination Evaluation (Phase 4 Component) ---
                        let termStatus = terminationEvaluator.evaluate(step: step, currentIteration: currentIteration, maxIterations: self.maxIterations)
                        switch termStatus {
                        case .maxIterationsReached:
                            break
                        case .completed(let finalThought):
                            executionSummary.finalAgentThought = finalThought
                            // Terminal prose exit (genuineCompletion): there are no tool
                            // calls, so `executeToolCalls` — which emits the per-iteration
                            // reasoning row — never runs. Without this the final iteration's
                            // span is empty in the Report Inspector and the event-derived
                            // iteration count misses it.
                            onTraceUpdate(AgentTraceLog(
                                traceID: iterationSpan.traceID,
                                spanID: iterationSpan.spanID,
                                parentSpanID: iterationSpan.parentSpanID,
                                stepNumber: currentIteration,
                                state: .thinking(.reasoning),
                                content: "Model answered directly (no tool calls).",
                                metadata: ["iteration": "\(currentIteration)"]
                            ))
                            iterationFinishedNormally = true; break cognitiveLoop
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
                            let modelAlert = reason.modelCorrectiveAlert(
                                availableToolNames: toolNames,
                                dialect: runDialect
                            )
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
                            iterationFinishedNormally = true; continue cognitiveLoop
                        case .proceed:
                            // Parse succeeded — reset the identical-output guard so
                            // intermittent format failures (which the corrective alert
                            // *did* land for) don't trip the abort prematurely.
                            lastFailedReasoning = nil
                            consecutiveIdenticalFormatFailures = 0
                            break
                        }

                        if step.toolCalls.isEmpty { iterationFinishedNormally = true; break cognitiveLoop }

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
                            interactionMemory: interactionMemory,
                            continuation: continuation,
                            approvalNodeID: input.workflowContext?.nodeID,
                            unattendedAutoApprove: input.workflowContext?.unattendedAutoApprove ?? false,
                            onTraceUpdate: onTraceUpdate
                        )

                        // --- G6: Advance Reading-Tool Gate Counter ---
                        // Count successful reading-tool invocations so `update_project_context`
                        // becomes available once the agent has actually read some source.
                        for obs in observations where obs.isSuccess && readingToolNames.contains(obs.toolName) {
                            readingToolSuccessCount += 1
                        }
                        if !readingGateLoggedUnlock, !gatedToolNames.isEmpty,
                           readingToolSuccessCount >= readingGateThreshold {
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
                            // final_answer is a control signal, NOT evidence — deliberately not
                            // recorded into executionSummary.toolResults. Recording it as a
                            // hardcoded-success tool result let hallucinated answers masquerade
                            // as corroborating evidence in synthesis ("it was confirmed that…")
                            // and inflated completionStatus (all-evidence-failed runs read
                            // partialSuccess). Its text reaches the user via finalAgentThought.
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
                            iterationFinishedNormally = true; break cognitiveLoop
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
                            executionSummary.record(toolCallId: obs.toolCallId, toolName: obs.toolName, params: obs.params, output: obs.output, isSuccess: isSuccess, failureCategory: obs.failureCategory)

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

                        // (Clarification loops are no longer counter-governed: identical re-asks
                        // are replayed from RunInteractionMemory — deterministic outputs — so the
                        // repetition detection below catches them; distinct questions are
                        // legitimate and bounded by the human in the loop + the iteration budget.)

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
                                // A circuit-breaker abort no longer forces synthesis. The
                                // abort is already communicated by the warning event above,
                                // the failed tool rows, and the terminal reason below —
                                // it does not justify handing the run to the IC model
                                // against the user's opt-in. Whatever partial reasoning
                                // exists is surfaced as-is; a run with nothing usable
                                // still lands on the deterministic template floor.
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
                                // Degraded success: the breaker stopped the run, but a usable
                                // best-effort answer was synthesized — surface it as "completed
                                // with warnings" so consumers (esp. workflow nodes) don't discard
                                // the output. Empty synthesis = a true failure. The episode above
                                // deliberately stays `.failed` — the run did NOT achieve its goal
                                // cleanly, and that's the signal episodic memory should keep.
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

                    // Only UNRECOVERED EVIDENCE failures drive outcome honesty and
                    // synthesis routing:
                    //  • user decisions (denied confirmation, skipped ask_user) are
                    //    choices, not tool failures — a denied write followed by task
                    //    completion must not amber the run or store a FAILED episode;
                    //  • a failure the agent retried to success (same tool + args) is
                    //    a recovered blip, not a caveat on the final answer.
                    let allResults = executionSummary.toolResults
                    let effectiveFailures = allResults.enumerated().filter { index, result in
                        guard !result.isSuccess else { return false }
                        if result.failureCategory == .userDenied || result.failureCategory == .cancelled {
                            return false
                        }
                        // Recovered = a LATER success repeated the same call (retry-to-
                        // success). Order matters: an EARLIER success with identical args
                        // is a different sub-goal, not a recovery — masking a trailing
                        // failure behind it would flip a would-be-amber run to green and
                        // store a poisoned "clean" episode.
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
                        // Opt-in ONLY. `effectiveFailures` deliberately does NOT appear
                        // here any more: an unrecovered failure used to force synthesis,
                        // which punched through the native fast-path and handed a
                        // complete answer to the IC model for a lossy rewrite. It still
                        // drives the terminal outcome + reason below — that is the
                        // honest failure signal, and it is the one the UI consumes.
                        synthesisOptedIn: input.responseSynthesisEnabled,
                        suppressLLM: input.suppressLLMSynthesis,
                        onUsage: { accumulatedTokenUsage.accumulate($0) }
                    )

                    // Single typed source of truth: the executor's terminal outcome,
                    // derived from the run's factual record — not just from which door
                    // the loop exited. Unrecovered evidence failures →
                    // `.completedWithWarnings` (answer shown + amber chip; workflow
                    // nodes still complete). A tool-less prose answer stays
                    // `.completed`: no tool evidence either way, and flagging it would
                    // false-positive on every conversational ask. Exhaustion keeps its
                    // best-effort upgrade.
                    let terminalOutcome: ExecutionOutcome = {
                        if iterationExhausted {
                            let hasBestEffort = !response.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                            return hasBestEffort ? .completedWithWarnings : .failed
                        }
                        return effectiveFailures.isEmpty ? .completed : .completedWithWarnings
                    }()

                    let terminalReason: String? = {
                        if iterationExhausted {
                            return "Reached maximum iterations (\(maxIterations)) without explicit completion"
                        }
                        guard !effectiveFailures.isEmpty else { return nil }
                        let names = Set(effectiveFailures.map(\.toolName)).sorted().joined(separator: ", ")
                        let evidenceCount = executionSummary.evidenceResults.count
                        return "\(effectiveFailures.count) of \(evidenceCount) tool call(s) failed (\(names))"
                    }()

                    // Episode outcome follows the stream outcome. SessionGraph's own
                    // EpisodeOutcome mapping (`completedWithWarnings → .failed`) keeps
                    // episodic memory conservative, so degraded runs are never stored
                    // as clean recipes for future retrieval.
                    let episodeOutcome: ExecutionOutcome = terminalOutcome

                    if !input.suppressEpisodeManagement {
                        sessionState.closeActiveEpisode(outcome: episodeOutcome, message: response)
                        await SessionGraphStore.shared.updateActiveState(conversationID: input.conversationID, state: sessionState)
                        logState.info("💾 Auto-Patched Active Episode to: \(episodeOutcome.rawValue.uppercased())")
                    }

                    // `iterations` metadata carries the authoritative loop counter and
                    // `outcome` the honest terminal verdict to EvaluationLogger — the
                    // event-derived count drifts (prose exits emit no .reasoning row;
                    // throttle notices emit an extra one), and a bare finalizing event
                    // must not imply success.
                    let finalizingContent: String = {
                        switch terminalOutcome {
                        case .completed:
                            return "Task completed successfully."
                        case .completedWithWarnings:
                            return "Task completed with warnings" + (terminalReason.map { ": \($0)" } ?? ".")
                        case .failed, .cancelled:
                            return "Task failed or reached max iterations."
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
                    // Field-debuggability: name WHOSE run died and how far it got. This line used to
                    // be a bare "Cancelled cleanly", which — landing seconds after unrelated log
                    // traffic (a workflow node's teardown resolves asynchronously) — could not be
                    // tied back to a node, a conversation, or the work it abandoned.
                    logger.notice("🚫 Execution Task Cancelled cleanly — \(input.workflowContext.map { "workflow node '\($0.nodeName)' [\($0.nodeID.uuidString.prefix(8))]" } ?? "chat run") conv \(input.conversationID.uuidString.prefix(8)), torn down during iteration \(currentIteration). CONSEQUENCE: partial progress is discarded; the outcome (Stop vs node timeout vs per-node skip) is decided by whoever cancelled this task, not here.")
                    // ⚠️ NODE-SCOPED WHEN THIS RUN IS A WORKFLOW NODE (N3). The conversation-wide drain
                    // force-resolves EVERY park in the conversation — including a SIBLING node's, whose
                    // tool would then be reported "denied by the user" though the user never saw it.
                    // A sub-workflow child is constructed with the PARENT's conversationID, so a child's
                    // node timeout used to sweep the outer run's banners too. Chat and code runs have no
                    // `workflowContext`, so they keep the conversation-wide sweep unchanged.
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
                    // Report the honest terminal outcome to the session summary. Without
                    // this, a user Stop prints "FAIL ❌" in the executor-span rollup
                    // (no reported outcome + didFinishSuccessfully false) when the
                    // truthful label is CANCELLED 🚫.
                    onTraceUpdate(AgentTraceLog(
                        traceID: input.traceContext.traceID,
                        spanID: input.traceContext.spanID,
                        parentSpanID: input.traceContext.parentSpanID,
                        stepNumber: 0,
                        state: .thinking(.finalizing),
                        content: "Cancelled by user.",
                        metadata: ["outcome": ExecutionOutcome.cancelled.rawValue]
                    ))
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
                    // ⚠️ NODE-SCOPED WHEN THIS RUN IS A WORKFLOW NODE (N3). The conversation-wide drain
                    // force-resolves EVERY park in the conversation — including a SIBLING node's, whose
                    // tool would then be reported "denied by the user" though the user never saw it.
                    // A sub-workflow child is constructed with the PARENT's conversationID, so a child's
                    // node timeout used to sweep the outer run's banners too. Chat and code runs have no
                    // `workflowContext`, so they keep the conversation-wide sweep unchanged.
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

/// Approximate serialized character footprint of a native turn dict — recursively sums
/// string lengths and dictionary keys. Used to budget the native conversation payload
/// (`liveConversationTurns`) without paying a full JSON-serialization cost per check (#22).
/// `internal` (not `fileprivate`) so the compaction logic is directly unit-testable.
///
/// IMAGES ARE NOT COUNTED AT BASE64 LENGTH. They used to be, and it made this gauge
/// wildly wrong: a 1 MB screenshot scored ~1,370,000 chars against an 8K–98K budget,
/// so a single image looked like a ~14× overflow. The compactor below would then drop
/// every droppable tool exchange, hit its keep-recent floor, and give up — shipping an
/// over-budget request anyway, minus the tool results the run actually needed. An
/// image's real cost is ~1–2k tokens regardless of file size, so it is charged flat
/// via `ImageTokenHeuristic`.
func approximateTurnChars(_ value: Any) -> Int {
    approximateTurnChars(value, key: nil)
}

/// Keys under which each provider adapter parks image bytes:
///   - Ollama: `"images": [base64, …]`
///   - Gemini: `"inlineData": {mimeType, data}`
///   - OpenAI: `"image_url": {url: "data:image/…;base64,…"}`
/// Claude nests its payload under `"source"` with `type == "base64"`, which is
/// matched structurally below rather than by key (`source` is too generic).
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
    // This is the dead-end case: we are OVER budget and cannot legally shrink. The
    // request ships anyway and the provider decides — historically with no local
    // breadcrumb at all, so an over-context 400 looked like it came from nowhere.
    guard exchangeStarts.count > keepRecent else {
        nativeTurnLogger.warning("[NATIVE] Payload is \(totalChars) chars against a \(budgetChars) budget but only \(exchangeStarts.count) droppable exchange(s) exist (keep-floor \(keepRecent)) — CANNOT compact. Sending over budget; expect a provider context-length error.")
        return 0
    }

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

/// Locates the contiguous run of `block` inside `haystack`, returning its start index.
///
/// `PromptBuilder` appends the lowered history turns in one `append(contentsOf:)`, so
/// they are contiguous by construction. Matching on content rather than computing an
/// index keeps this correct if the surrounding prompt layers ever change shape — a
/// failed match degrades to "no history images" instead of splicing into the wrong turn.
fileprivate func locateTurnBlock(_ block: [[String: String]], in haystack: [[String: String]]) -> Int? {
    guard !block.isEmpty, haystack.count >= block.count else { return nil }
    for start in 0...(haystack.count - block.count) where Array(haystack[start..<(start + block.count)]) == block {
        return start
    }
    return nil
}

/// Splices prior-turn images into the already-normalized history turns.
///
/// WHY A SPLICE: history reaches the native path through `compileMessages`, whose
/// return type is `[[String: String]]` — text-only, and shared with the bot path.
/// Rather than widen that type (which would touch six generators and the MLX Jinja
/// renderer), the history is lowered to text there and its images are re-attached
/// here, where the provider adapter can serialize them natively.
///
/// FAILURE POLICY — deliberately ASYMMETRIC with the current turn. `resolveUserImages`
/// THROWS on an unreadable current-turn image (the user just attached it; failing
/// loudly is correct). Here we warn-log and OMIT: killing a live run because an image
/// from three turns ago was moved on disk would be worse than answering without it.
/// This is the one place transcript and model input are allowed to diverge, so every
/// omission is logged with its consequence.
///
/// Returns the number of images successfully spliced and the number omitted.
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
            // Resolve the bytes, then normalize to something every provider can load.
            // A history image is replayed on EVERY subsequent request, so an unsupported
            // media_type (HEIC, the macOS default) would once have 400'd the conversation
            // permanently — now `resolveSendable` transcodes it to JPEG instead. Only the
            // truly-undecodable is omitted (it stays visible in the transcript regardless).
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

/// Pre-resolves attached image payloads to base64 for the agent's native kickoff
/// user turn (adapters are synchronous, so resolution happens here). Throws if an
/// image can't be retrieved — surfaced as an execution error (consistent with the
/// bot path), never a silent drop. Empty/nil payload → no images.
///
/// Contrast `spliceHistoryImages`, which OMITS rather than throws: a current-turn
/// image the user just attached must fail loudly; a stale one from an earlier turn
/// must not kill the run.
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

