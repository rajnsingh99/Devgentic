// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
//
//  PlanningCapability.swift
//  Devgentic
//
//  Created by Raj Singh.
//

import Foundation
import OSLog

private let logger = DGLogger(category: "PlanningCapability")

// MARK: - Capability Definition

/// Decomposes a task into subtasks via the LLM, then executes each with the wrapped inner executor.
/// Supports parallel subtask execution (via `dependsOn`) and per-subtask tool filtering (via `toolHints`).
struct PlanningCapability: ExecutorCapability, Sendable {

    /// Whether an error is a fault of the plumbing rather than of the model's answer.
    /// An infrastructure fault means planning never happened and the run must fail; a content fault may degrade to one task.
    /// Typed, never prose-matched, so the classification lives in one place and tests can assert the set.
    static func isInfrastructureFault(_ error: Error) -> Bool {
        if error is MLXService.ServiceError { return true }   // local model-slot race / no model
        if error is CloudProviderError { return true }        // 4xx/5xx/429 from a cloud provider
        if error is LLMProviderError { return true }          // Ollama & local HTTP transport
        if error is TransportFatalError { return true }       // retries exhausted / deterministic
        if error is URLError { return true }                  // DNS, connection, timeout
        return false
    }

    /// Whether parallel subtask execution is honoured at all. Parallel subtasks serialize at the LLM layer (one GPU locally,
    /// shared rate limits in the cloud), so they only add ordering nondeterminism. The stored field is kept so profiles
    /// retain their preference; flip this when batch inference or multi-model routing makes parallelism real.
    static let parallelSubtasksSupported = false
    let config: PlanningCapabilityConfig

    func wrap(_ executor: any Executor) -> any Executor {
        PlanningExecutorWrapper(
            innerExecutor: executor,
            config: config
        )
    }
}

// MARK: - Executor Wrapper

actor PlanningExecutorWrapper: Executor {

    nonisolated let executorLabel: String = "Planning → ReAct"
    nonisolated private let innerExecutor: any Executor
    nonisolated private let config: PlanningCapabilityConfig

    init(innerExecutor: any Executor, config: PlanningCapabilityConfig) {
        // Dependency results are seeded into `workingMemory`, which only executors consuming `AgentInput.workingMemory`
        // (e.g. ReActAgentExecutor) read; any other inner executor silently discards the seeded context.
        assert(innerExecutor is ReActAgentExecutor,
               "PlanningCapability requires an inner executor that consumes workingMemory (e.g., ReActAgentExecutor).")
        self.innerExecutor = innerExecutor
        self.config = config
    }

    nonisolated func execute(
        model: any LLMProvider,
        input: AgentInput,
        onTraceUpdate: @escaping @Sendable (AgentTraceLog) -> Void
    ) -> AsyncThrowingStream<AgentStreamEvent, Error> {

        return AsyncThrowingStream(AgentStreamEvent.self) { continuation in
            let task = Task {

                var sessionState: SessionGraph
                if let activeState = input.activeState {
                    sessionState = activeState
                } else {
                    sessionState = await SessionGraphStore.shared.getActiveState(for: input.conversationID)
                }

                // Whether any answer content reached the UI: the cancel handler emits a placeholder only when the bubble would
                // otherwise be empty.
                var didEmitContent = false

                do {
                    logger.info("Planning capability initiated.")

                    // Fixed scope = the capability's own context: plan-generation LLM calls record as llmCall spans at capability level.
                    // Inner subtask executors build their own spy with a per-iteration scope, so nothing double-counts.
                    let spyModel = APISpyModel(inner: model, spanScope: LLMSpanScope(input.traceContext))
                    let executionTrace = input.traceContext

                    // --- Start Episode ---
                    sessionState.episodes.append(MemoryEpisode(primaryGoal: input.userInput, status: .active))
                    sessionState.workingMemory.removeValue(forKey: "current_focus")
                    await SessionGraphStore.shared.updateActiveState(conversationID: input.conversationID, state: sessionState)

                    continuation.yield(.thought("Planning: Decomposing task into subtasks..."))

                    // Anchor to the existing root span: an event on `newSpan()` would reference a span row never begun, fail the FK check
                    // at flush and be dropped from the trace.
                    onTraceUpdate(AgentTraceLog(
                        traceID: executionTrace.traceID,
                        spanID: executionTrace.spanID,
                        parentSpanID: executionTrace.parentSpanID,
                        stepNumber: 0,
                        state: .thinking(.planning),
                        content: "Decomposing task into subtasks..."
                    ))

                    await GlobalRateLimiter.shared.waitForCapacity(forKey: input.rateLimitKey, category: input.rateLimitCategory)

                    let envFacts = EnvironmentFacts(
                        osVersion: ProcessInfo.processInfo.operatingSystemVersionString,
                        shellType: "Zsh (Non-Interactive Mode)",
                        userName: NSUserName(),
                        homeDirectory: NSHomeDirectory(),
                        currentDate: EnvironmentFacts.clock().date,
                        currentTime: EnvironmentFacts.clock().time
                    )

                    // Read User Personal profile for planning context, workflow runs included: same read as `ReActAgentExecutor`,
                    // so a plan is never built without the guardrails the executing step honours.
                    let userProfile: String? = await MainActor.run {
                        guard UserDefaults.standard.bool(forKey: AppSettings.ciFeatureUserPersonalKey) else { return nil }
                        return UserPersonalService.shared.getProfileForInjection()
                    }

                    // Both plan calls (initial + post-clarification) share this shape;
                    // only the answered clarification differs.
                    func makePlanContext(_ clarification: ClarificationContext?) -> SemanticContext {
                        SemanticContext(
                            instructions: input.instructions,
                            environmentFacts: envFacts,
                            longTermMemory: input.longTermMemory,
                            recentHistory: input.recentHistory,
                            nativeHistoryTurns: input.nativeHistoryTurns,
                            originalQuery: input.userInput,
                            currentIteration: 0,
                            compiledScratchpad: "",
                            latestClarification: clarification,
                            negativeConstraints: Set(sessionState.negativeConstraints),
                            hallucinatedTools: [],
                            availableTools: input.tools,
                            userProfile: userProfile,
                            skillManifests: input.skillManifests,
                            promptLayerConfig: .agent,
                            workflowContext: nil
                        )
                    }

                    // One interaction memory for the whole planned run: the pre-plan clarification replays for identical `ask_user`
                    // re-asks inside any subtask (threaded via subtaskInput below).
                    let interactionMemory = input.interactionMemory ?? RunInteractionMemory()

                    // A stored preference this build will not honour must say so: profiles saved with parallel subtasks on exist,
                    // and nothing else explains why their subtasks now run sequentially.
                    if config.parallelSubtasks && !PlanningCapability.parallelSubtasksSupported {
                        logger.notice(
                            "[PLANNING] This profile has Parallel Subtasks stored as ON, but parallel "
                            + "execution is disabled in this build (PlanningCapability."
                            + "parallelSubtasksSupported). CONSEQUENCE: subtasks run SEQUENTIALLY. "
                            + "The stored preference is preserved, not rewritten."
                        )
                    }

                    let planGenerator = PlanGeneratorStrategy(planningConfig: config)
                    var subtasks: [SubTask]

                    // The MLX model-slot race is infrastructure, not content, so it never folds into the single-task fallback below.
                    // One 2s re-attempt (same bound as `modelSlotAction` and `TransportRetrier`), then the run fails honestly.
                    func generatePlanWithSlotRetry(
                        context: SemanticContext, allowClarification: Bool
                    ) async throws -> (outcome: PlanGenerationOutcome, usage: TokenUsage) {
                        do {
                            return try await planGenerator.generatePlan(
                                model: spyModel, context: context, allowClarification: allowClarification)
                        } catch let slotError as MLXService.ServiceError {
                            logger.warning("[PLANNING] Plan generation lost the MLX model slot (\(slotError.localizedDescription)) — re-attempting once in 2s. CONSEQUENCE: no fallback plan is fabricated for an infrastructure fault; a second loss fails the run honestly.")
                            try await Task.sleep(for: .seconds(2))
                            try Task.checkCancellation()
                            return try await planGenerator.generatePlan(
                                model: spyModel, context: context, allowClarification: allowClarification)
                        }
                    }

                    do {
                        // Round 1: the model may answer with a plan or, when the task is too vague, a single CLARIFY question. Suppressed in
                        // workflow mode (headless nodes) and when nobody can answer (scheduled/woken runs), which plan on assumptions.
                        let allowClarify = config.clarifyBeforePlanning && input.workflowContext == nil
                            && WorkflowRunAttendance.canReachAHuman
                        let planResult = try await generatePlanWithSlotRetry(
                            context: makePlanContext(nil), allowClarification: allowClarify
                        )
                        continuation.yield(.tokenUsage(planResult.usage))

                        switch planResult.outcome {
                        case .plan(let plan):
                            subtasks = plan

                        case .clarificationNeeded(let question):
                            logger.info("Planner requested clarification before planning.")
                            let operationID = UUID()
                            continuation.yield(.requestClarification(question: question, operationID: operationID))
                            let answer = await ExecutionSuspensionService.shared
                                .suspendForClarification(for: operationID, conversationID: input.conversationID)
                            // A Stop while suspended resumes nil via cancel(for:) — don't record
                            // that as a real "skip"; propagate to the cancel handler instead.
                            try Task.checkCancellation()

                            // Record the Q&A so an identical ask_user inside a subtask replays
                            // the answer instead of re-raising the banner (loop-safety contract).
                            await interactionMemory.recordAnswer(question: question, response: answer)

                            let answerText = answer ?? "System: The user skipped or did not respond."
                            continuation.yield(.thought(answer != nil
                                ? "Clarified before planning — \(question) → \(answerText)"
                                : "Clarification skipped — planning with reasonable assumptions."))

                            // Round 2 — the answer shapes the plan; no second question allowed.
                            await GlobalRateLimiter.shared.waitForCapacity(forKey: input.rateLimitKey, category: input.rateLimitCategory)
                            let clarified = ClarificationContext(query: question, response: answerText)
                            let secondResult = try await generatePlanWithSlotRetry(
                                context: makePlanContext(clarified), allowClarification: false
                            )
                            continuation.yield(.tokenUsage(secondResult.usage))
                            if case .plan(let plan) = secondResult.outcome {
                                subtasks = plan
                            } else {
                                // Unreachable (allowClarification: false never yields a question) —
                                // defensive parity with the parse-failure fallback below.
                                subtasks = [SubTask(id: "step_1", description: input.userInput)]
                            }
                        }

                        // Cap to configured max. Must be logged: silently discarding generated steps leaves requirements never attempted
                        // while the plan card and the completion report look normal.
                        if subtasks.count > config.maxSubtasks {
                            let generated = subtasks.count
                            let dropped = generated - config.maxSubtasks
                            subtasks = Array(subtasks.prefix(config.maxSubtasks))
                            logger.warning("""
                                [PLANNING] Plan truncated for conversation \
                                \(input.conversationID.uuidString.prefix(8)): the model generated \
                                \(generated) subtask(s) but Max Subtasks is \(config.maxSubtasks). \
                                CONSEQUENCE: \(dropped) step(s) were DISCARDED and the run will not \
                                attempt them — raise Max Subtasks if the task needs them.
                                """)
                        }
                    } catch is CancellationError {
                        // Stop must propagate, not fold into a single-task fallback that keeps running; rethrow to the outer cancel handler.
                        throw CancellationError()
                    } catch let infrastructureError where PlanningCapability.isInfrastructureFault(infrastructureError) {
                        // Infrastructure, not content: rethrow to the outer catch, which classifies, traces and finishes the run `.failed`.
                        // The typed set covers the whole provider family (cloud and Ollama faults too), not just MLX.
                        logger.error("[PLANNING] Plan generation failed with an INFRASTRUCTURE fault for conversation \(input.conversationID.uuidString.prefix(8)): \(infrastructureError.localizedDescription). CONSEQUENCE: the run FAILS with that message — no fabricated single-step plan, no false .planGenerated success. The task was never decomposed, so completing it undecomposed would report work that was never planned.")
                        throw infrastructureError
                    } catch {
                        // Content fault (unparseable plan output): the single-task fallback is a degraded mode and must be loud, since a
                        // plausible one-step plan with no warning would hide that planning failed.
                        logger.warning("[PLANNING] Plan generation failed for conversation \(input.conversationID.uuidString.prefix(8)): \(error.localizedDescription). CONSEQUENCE: the run continues as a SINGLE undecomposed task — the plan card's one step is a fallback, not a decision; a surfaced warning says so on the timeline.")
                        continuation.yield(.warning(
                            category: .midRunError,
                            message: String(localized: "Planning failed (\(error.localizedDescription)) — continuing as a single task without decomposition.")
                        ))
                        subtasks = [SubTask(id: "step_1", description: input.userInput)]
                    }

                    // Structured plan → UI plan card. The step list travels as data; the old
                    // numbered-list `.thought` duplicated what the card now renders.
                    continuation.yield(.planGenerated(subtasks: subtasks))
                    logger.info("Plan generated: \(subtasks.count) subtasks.")

                    // Plan approval required but nobody can review it: never auto-approved, so the run stops here instead of parking until
                    // its limit kills it. Same shape as an unattended tool confirmation: not executed.
                    if config.requiresPlanApproval && !subtasks.isEmpty && !WorkflowRunAttendance.canReachAHuman {
                        let reason = "Plan review required, but nobody can review it in this run (it is unattended) — the plan was NOT executed."
                        logger.notice("[HITL] Plan review REFUSED — unattended run. CONSEQUENCE: the run stops without executing the plan; turn off plan approval on this profile to let scheduled runs plan and act on their own.")
                        continuation.yield(.content(reason))
                        sessionState.closeActiveEpisode(outcome: .cancelled, message: reason)
                        await SessionGraphStore.shared.updateActiveState(conversationID: input.conversationID, state: sessionState)
                        onTraceUpdate(AgentTraceLog(
                            traceID: input.traceContext.traceID,
                            spanID: input.traceContext.spanID,
                            parentSpanID: input.traceContext.parentSpanID,
                            stepNumber: 0,
                            state: .thinking(.finalizing),
                            content: reason,
                            metadata: ["outcome": ExecutionOutcome.cancelled.rawValue]
                        ))
                        continuation.yield(.executionFinished(outcome: .cancelled, reason: reason))
                        continuation.finish()
                        return
                    }

                    if config.requiresPlanApproval && !subtasks.isEmpty {
                        let reviewOperationID = UUID()
                        continuation.yield(.requestPlanReview(subtasks: subtasks, operationID: reviewOperationID))
                        logger.info("Plan review requested. Suspending until user approves or rejects.")

                        guard let approvedPlan = await ExecutionSuspensionService.shared
                            .suspendForPlanReview(for: reviewOperationID, conversationID: input.conversationID, nodeID: input.workflowContext?.nodeID)
                        else {
                            // `nil` means both "the user rejected the plan" and "the park was torn down"; the outcome is `.cancelled` either way,
                            // but the persisted episode message and log line must not assert a rejection the user may never have made.
                            let wasCancelled = Task.isCancelled
                            let reason = wasCancelled ? "Plan review cancelled (run stopped)" : "Plan rejected by user"
                            logger.info("\(reason).")
                            continuation.yield(.content("Plan was cancelled. Let me know if you'd like a different approach."))
                            sessionState.closeActiveEpisode(outcome: .cancelled, message: reason)
                            await SessionGraphStore.shared.updateActiveState(conversationID: input.conversationID, state: sessionState)
                            // Honest terminal for the session summary — a rejected plan is
                            // CANCELLED 🚫, not FAIL ❌ (observed in the reject-path manual run).
                            onTraceUpdate(AgentTraceLog(
                                traceID: input.traceContext.traceID,
                                spanID: input.traceContext.spanID,
                                parentSpanID: input.traceContext.parentSpanID,
                                stepNumber: 0,
                                state: .thinking(.finalizing),
                                content: "\(reason).",
                                metadata: ["outcome": ExecutionOutcome.cancelled.rawValue]
                            ))
                            continuation.yield(.executionFinished(outcome: .cancelled, reason: reason))
                            continuation.finish()
                            return
                        }

                        subtasks = Self.sanitizeDependencies(approvedPlan)
                        // Review edits can add/remove/reword steps — ship the FINAL plan so the
                        // UI card replaces its step list before execution starts.
                        continuation.yield(.planApproved(subtasks: subtasks))
                        logger.info("Plan approved with \(subtasks.count) subtasks. Proceeding to execution.")
                    }

                    let levels = Self.computeExecutionLevels(subtasks: subtasks)
                    var subtaskResults: [String: String] = [:]
                    var allToolResults: [ToolOutput] = []  // [G4] Aggregate across subtasks
                    // Inner runs that finish cleanly but dishonestly: `.failed` without throwing, and `.completedWithWarnings`
                    // (circuit-breaker abort or tool failures). Both must reach the plan-level outcome, not just the `Error:` prefix check.
                    var hardFailedIDs: [String] = []
                    var degradedSubtasks: [(id: String, reason: String?)] = []

                    for (levelIndex, levelIDs) in levels.enumerated() {
                        try Task.checkCancellation()

                        let levelSubtasks = levelIDs.compactMap { id in subtasks.first(where: { $0.id == id }) }
                        logger.info("Executing level \(levelIndex + 1)/\(levels.count) (\(levelSubtasks.count) subtask(s)).")

                        if PlanningCapability.parallelSubtasksSupported && config.parallelSubtasks && levelSubtasks.count > 1 {
                            // Parallel execution: catch per-subtask errors so one failure doesn't discard completed siblings. Siblings at the same
                            // level don't see each other's results (independent by definition); seeding uses a snapshot of prior levels.
                            let priorResults = subtaskResults

                            await withTaskGroup(of: (String, String?, [ToolOutput], ExecutionOutcome?, String?).self) { group in
                                for subtask in levelSubtasks {
                                    group.addTask {
                                        do {
                                            let result = try await self.executeSubtask(
                                                subtask: subtask,
                                                allSubtasks: subtasks,
                                                priorResults: priorResults,
                                                input: input,
                                                model: model,
                                                interactionMemory: interactionMemory,
                                                continuation: continuation,
                                                onTraceUpdate: onTraceUpdate
                                            )
                                            return (subtask.id, result.output, result.toolResults, result.outcome, result.reason)
                                        } catch is CancellationError {
                                            return (subtask.id, nil, [], nil, nil)
                                        } catch {
                                            logger.error("Subtask '\(subtask.id)' failed: \(error.localizedDescription)")
                                            // Structured warning: a system signal (subtask threw), not model reasoning, so the UI renders it apart from thoughts
                                            // and consumers (negativeConstraints, episodic memory) get a machine-readable category.
                                            continuation.yield(.warning(
                                                category: .retry,
                                                message: "Subtask '\(subtask.id)' failed: \(error.localizedDescription)",
                                                relatedPath: subtask.id
                                            ))
                                            // A thrown subtask never reaches executeSubtask's completion
                                            // yield — close its plan-card row here so it doesn't spin forever.
                                            let failedIndex = (subtasks.firstIndex(where: { $0.id == subtask.id }) ?? 0) + 1
                                            continuation.yield(.subtaskCompleted(
                                                id: subtask.id, index: failedIndex, total: subtasks.count,
                                                summary: "Failed: \(error.localizedDescription)", outcome: .failed
                                            ))
                                            return (subtask.id, "Error: \(error.localizedDescription)", [], nil, nil)
                                        }
                                    }
                                }
                                for await (id, result, tools, outcome, reason) in group {
                                    if let result { subtaskResults[id] = result }
                                    allToolResults.append(contentsOf: tools)
                                    switch outcome {
                                    case .failed: hardFailedIDs.append(id)
                                    case .completedWithWarnings: degradedSubtasks.append((id: id, reason: reason))
                                    default: break
                                    }
                                }
                            }
                            try Task.checkCancellation()
                        } else {
                            // Sequential execution
                            for subtask in levelSubtasks {
                                try Task.checkCancellation()
                                do {
                                    let result = try await self.executeSubtask(
                                        subtask: subtask,
                                        allSubtasks: subtasks,
                                        priorResults: subtaskResults,
                                        input: input,
                                        model: model,
                                        interactionMemory: interactionMemory,
                                        continuation: continuation,
                                        onTraceUpdate: onTraceUpdate
                                    )
                                    subtaskResults[subtask.id] = result.output
                                    allToolResults.append(contentsOf: result.toolResults)
                                    switch result.outcome {
                                    case .failed: hardFailedIDs.append(subtask.id)
                                    case .completedWithWarnings: degradedSubtasks.append((id: subtask.id, reason: result.reason))
                                    default: break
                                    }
                                } catch is CancellationError {
                                    throw CancellationError()
                                } catch {
                                    logger.error("Subtask '\(subtask.id)' failed: \(error.localizedDescription)")
                                    continuation.yield(.warning(
                                        category: .retry,
                                        message: "Subtask '\(subtask.id)' failed: \(error.localizedDescription)",
                                        relatedPath: subtask.id
                                    ))
                                    // Close the plan-card row for the thrown subtask (see parallel branch).
                                    let failedIndex = (subtasks.firstIndex(where: { $0.id == subtask.id }) ?? 0) + 1
                                    continuation.yield(.subtaskCompleted(
                                        id: subtask.id, index: failedIndex, total: subtasks.count,
                                        summary: "Failed: \(error.localizedDescription)", outcome: .failed
                                    ))
                                    subtaskResults[subtask.id] = "Error: \(error.localizedDescription)"
                                }
                            }
                        }
                    }

                    continuation.yield(.thought("Composing final response..."))

                    // Composed (labeled + blank-line separated) rather than raw-joined:
                    // with synthesis opt-in, this text may reach the user verbatim.
                    let combinedResults = Self.composeSubtaskResults(subtasks: subtasks, results: subtaskResults)

                    // Partial-failure detection: thrown subtasks carry an "Error: " prefix; non-throwing `.failed` terminals are in
                    // hardFailedIDs (disjoint by construction). Computed before the summary so an all-failed run shows no raw error text.
                    let totalSubtasks = subtasks.count
                    let thrownFailures = subtaskResults.values.filter { $0.hasPrefix("Error:") }.count
                    let failedSubtasks = thrownFailures + hardFailedIDs.count
                    let allFailed = totalSubtasks > 0 && failedSubtasks == totalSubtasks

                    var synthesisSummary = ExecutionSummary(originalGoal: input.userInput)
                    // [G4] Aggregate subtask tool results so ResponseSynthesizer has full context.
                    for tool in allToolResults {
                        synthesisSummary.record(
                            toolCallId: tool.id.uuidString,
                            toolName: tool.toolName,
                            params: tool.params,
                            output: tool.output,
                            isSuccess: tool.isSuccess
                        )
                    }
                    if allFailed {
                        // Raw "Error: <localizedDescription>" strings are internal: routing them through failureReason (not finalAgentThought)
                        // keeps the conclusion-only fast path from echoing them and lets synthesis write a clean failure message.
                        synthesisSummary.markComplete(failureReason: combinedResults)
                    } else {
                        synthesisSummary.finalAgentThought = combinedResults.isEmpty ? nil : combinedResults
                        synthesisSummary.markComplete()
                    }

                    let response = await ResponseSynthesizer.synthesize(
                        summary: synthesisSummary,
                        personaInstructions: input.instructions,
                        originalQuery: input.userInput,
                        isNativeFlow: input.generatorStrategy is NativeStructuredGenerator,
                        synthesisOptedIn: input.responseSynthesisEnabled,
                        // Counts the synthesis LLM cost as a usage event, like plan-generation and subtask usages, so it is in the run's
                        // token/cost rollup.
                        onUsage: { continuation.yield(.tokenUsage($0)) }
                    )

                    // Honest plan-level terminal: any hard failure or degraded (forced-termination) subtask demotes the run to
                    // `.completedWithWarnings`.
                    let terminalOutcome: ExecutionOutcome
                    if allFailed {
                        terminalOutcome = .failed
                    } else if failedSubtasks > 0 || !degradedSubtasks.isEmpty {
                        terminalOutcome = .completedWithWarnings
                    } else {
                        terminalOutcome = .completed
                    }
                    var reasonParts: [String] = []
                    if failedSubtasks > 0 {
                        reasonParts.append("\(failedSubtasks) of \(totalSubtasks) subtasks failed")
                    }
                    for degraded in degradedSubtasks {
                        reasonParts.append("'\(degraded.id)' ended early\(degraded.reason.map { ": \($0)" } ?? "")")
                    }
                    let terminalReason: String? = reasonParts.isEmpty ? nil : reasonParts.joined(separator: "; ")

                    sessionState.closeActiveEpisode(outcome: terminalOutcome, message: response)
                    await SessionGraphStore.shared.updateActiveState(conversationID: input.conversationID, state: sessionState)

                    // Report the plan-level outcome on the root span so the session summary reflects the plan's verdict, not whichever
                    // inner run reported its finalizing event last.
                    onTraceUpdate(AgentTraceLog(
                        traceID: executionTrace.traceID,
                        spanID: executionTrace.spanID,
                        parentSpanID: executionTrace.parentSpanID,
                        stepNumber: subtasks.count,
                        state: .thinking(.finalizing),
                        content: "Plan execution complete: \(subtasks.count) subtask(s).",
                        metadata: ["outcome": terminalOutcome.rawValue]
                    ))

                    continuation.yield(.content(response))
                    didEmitContent = true
                    continuation.yield(.executionFinished(outcome: terminalOutcome, reason: terminalReason))
                    continuation.finish()

                } catch is CancellationError {
                    logger.notice("Planning capability cancelled.")
                    // Node-scoped when this run is a workflow node: the conversation-wide drain force-resolves every park in the
                    // conversation, including a sibling node's. Chat and code runs have no `workflowContext` and sweep conversation-wide.
                    if let nodeID = input.workflowContext?.nodeID {
                        await ExecutionSuspensionService.shared.cancelNode(nodeID, in: input.conversationID)
                    } else {
                        await ExecutionSuspensionService.shared.cancel(for: input.conversationID)
                    }
                    sessionState.cancelActiveEpisode()
                    await SessionGraphStore.shared.updateActiveState(conversationID: input.conversationID, state: sessionState)
                    continuation.yield(.thought("Cancelled by user."))
                    // Honest terminal for the session summary: CANCELLED 🚫, not FAIL ❌.
                    onTraceUpdate(AgentTraceLog(
                        traceID: input.traceContext.traceID,
                        spanID: input.traceContext.spanID,
                        parentSpanID: input.traceContext.parentSpanID,
                        stepNumber: 0,
                        state: .thinking(.finalizing),
                        content: "Cancelled by user.",
                        metadata: ["outcome": ExecutionOutcome.cancelled.rawValue]
                    ))
                    // Mirrors ReActAgentExecutor's cancel placeholder so a cancelled run doesn't leave an empty bubble (inner subtask
                    // content is accumulated, not forwarded). Guarded against double content.
                    if !didEmitContent {
                        continuation.yield(.content("*Operation stopped by user.*"))
                    }
                    continuation.yield(.executionFinished(outcome: .cancelled, reason: "User stopped the run"))
                    continuation.finish()
                } catch {
                    let classified = error.classify(
                        as: .planGenFailed,
                        origin: "PlanningCapability.fatalCatch",
                        message: "Planning capability fatal error: \(error.localizedDescription)"
                    )
                    logger.error(
                        "Planning capability fatal error: \(classified.message)",
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
                    continuation.yield(.executionFinished(outcome: .failed, reason: classified.message))
                    continuation.finish(throwing: error)
                }
            }

            continuation.onTermination = { @Sendable _ in task.cancel() }
        }
    }

    // MARK: - Subtask Execution via Inner Executor

    /// Executes one subtask with the inner executor, seeding its dependencies' results from `priorResults` (by subtask ID).
    /// `allSubtasks` is the full plan, searched for dependency descriptions. For parallel execution `priorResults` is a
    /// snapshot from prior levels; for sequential execution it holds everything accumulated so far.
    private func executeSubtask(
        subtask: SubTask,
        allSubtasks: [SubTask],
        priorResults: [String: String],
        input: AgentInput,
        model: any LLMProvider,
        interactionMemory: RunInteractionMemory,
        continuation: AsyncThrowingStream<AgentStreamEvent, Error>.Continuation,
        onTraceUpdate: @escaping @Sendable (AgentTraceLog) -> Void
    ) async throws -> (output: String, toolResults: [ToolOutput], outcome: ExecutionOutcome?, reason: String?) {

        let subtaskIndex = (allSubtasks.firstIndex(where: { $0.id == subtask.id }) ?? 0) + 1
        let subtaskStartedAt = Date()
        continuation.yield(.subtaskStarted(id: subtask.id, index: subtaskIndex, total: allSubtasks.count, description: subtask.description))

        // Persist a subtask span so the inner executor's iteration spans attach to a real parent row instead of orphaning under
        // the trace root. The success flag keeps the span status honest on throw/cancel exits.
        let subtaskSpan = input.traceContext.newSpan()
        await TraceRecorder.shared.beginSpan(context: subtaskSpan, name: "subtask:\(subtaskIndex)", kind: .subtask)
        var subtaskSucceeded = false
        defer {
            let endedAt = Date() // real end, captured before the hop (earliest-wins)
            let status: SpanStatus = subtaskSucceeded ? .completed : .error
            Task { await TraceRecorder.shared.endSpan(spanID: subtaskSpan.spanID, status: status, at: endedAt) }
        }

        // Optionally filter tools based on toolHints
        let filteredTools: [AgentTool]
        if config.subtaskToolFiltering, let hints = subtask.toolHints, !hints.isEmpty {
            let hintSet = Set(hints.map { $0.lowercased() })
            let matched = input.tools.filter { tool in
                hintSet.contains(tool.name.lowercased())
            }
            // If filter matches nothing, fall back to all tools
            if matched.isEmpty {
                logger.warning("Tool hints \(hints) for subtask '\(subtask.id)' matched no tools. Falling back to all \(input.tools.count) tools.")
            }
            filteredTools = matched.isEmpty ? input.tools : matched
        } else {
            filteredTools = input.tools
        }

        // Seed working memory with dependency results so dependent subtasks
        // have context from prior steps (e.g., file paths discovered earlier).
        var seededMemory = input.workingMemory
        if let deps = subtask.dependsOn, !deps.isEmpty {
            for depID in deps {
                guard let depResult = priorResults[depID] else { continue }
                let depDescription = allSubtasks.first(where: { $0.id == depID })?.description ?? depID
                seededMemory.recordObservation(
                    stepId: 0,
                    toolCallId: "dep_\(depID)",
                    toolName: "prior_subtask",
                    params: "",
                    result: "[\(depDescription)]: \(depResult)",
                    artifacts: []
                )
            }
            logger.info("Seeded \(deps.count) dependency result(s) into working memory for subtask '\(subtask.id)'.")
        }

        // Build subtask-scoped input by copy-derivation (AgentInput contract): everything not overridden, including future
        // fields, is inherited from the parent run.
        var subtaskInput = input
        subtaskInput.userInput = subtask.description
        subtaskInput.tools = filteredTools
        subtaskInput.workingMemory = seededMemory
        // Shared across ALL subtasks (and holding the pre-plan clarification):
        // a question answered once replays for identical re-asks anywhere in the run.
        subtaskInput.interactionMemory = interactionMemory
        subtaskInput.suppressEpisodeManagement = true
        // Subtask output is intermediate, so per-subtask synthesis is skipped: it would cost one load/gen/unload per subtask.
        subtaskInput.suppressLLMSynthesis = true
        subtaskInput.traceContext = subtaskSpan

        // Delegate to inner executor
        let stream = innerExecutor.execute(model: model, input: subtaskInput, onTraceUpdate: onTraceUpdate)

        var output = ""
        var toolResults: [ToolOutput] = []
        // Inner terminal signal: a circuit-breaker abort doesn't throw, the inner ReAct finishes with `.completedWithWarnings`
        // (or `.failed` on empty synthesis); this is the only way to tell a forced termination from a clean completion.
        var terminalOutcome: ExecutionOutcome? = nil
        var terminalReason: String? = nil
        for try await event in stream {
            switch event {
            case .content(let text):
                output += text
            case .thought(let thought, let id, _):
                // Forwarded verbatim (original id kept): attribution to this subtask is structural, since the stream bridge routes
                // events between subtaskStarted and subtaskCompleted into the plan card's step sub-timeline.
                continuation.yield(.thought(thought, id: id))
            case .reasoning(let text, let id, _):
                // The model's visible monologue, forwarded so planned runs keep their narrative in the UI.
                continuation.yield(.reasoning(text, id: id))
            case .toolCall(let name, let params, _, let stepId):
                // [G11] Forward tool invocation events so UI shows tool activity during subtasks.
                continuation.yield(.toolCall(name: name, params: params, stepId: stepId))
            case .toolSucceeded(let toolOutput, let durationMs, _):
                // [G4] Capture subtask tool results for synthesis aggregation.
                toolResults.append(toolOutput)
                continuation.yield(.toolSucceeded(toolOutput, durationMs: durationMs))
            case .toolFailed(let toolOutput, let category, let suggestion, _):
                toolResults.append(toolOutput)
                continuation.yield(.toolFailed(toolOutput, category: category, suggestion: suggestion))
            case .requestConfirmation(let toolName, let params, let operationID, let sourceNodeID, let sourceNodeName):
                // [G9] Forward HITL permission requests — user must see these during subtasks.
                continuation.yield(.requestConfirmation(toolName: toolName, params: params, operationID: operationID, sourceNodeID: sourceNodeID, sourceNodeName: sourceNodeName))
            case .requestClarification(let question, let operationID, let sourceNodeID, let options, let multiline, let sourceNodeName):
                // [G9] Forward HITL clarification requests.
                continuation.yield(.requestClarification(question: question, operationID: operationID, sourceNodeID: sourceNodeID, options: options, multiline: multiline, sourceNodeName: sourceNodeName))
            case .error(let msg):
                continuation.yield(.error(msg))
            case .warning(let cat, let msg, let relatedPath, _):
                // [G11] Forward warnings so UI surfaces memory-pressure / retry / parse-failure
                // signals during subtasks. Unprefixed — attribution is structural (plan card).
                continuation.yield(.warning(category: cat, message: msg, relatedPath: relatedPath))
            case .artifactProduced(let artifact):
                continuation.yield(.artifactProduced(artifact))
            case .tokenUsage(let usage):
                continuation.yield(.tokenUsage(usage))
            case .executionFinished(let outcome, let reason):
                // Not forwarded — the wrapper emits its own plan-level terminal.
                terminalOutcome = outcome
                terminalReason = reason
            default:
                break
            }
        }

        let summary = output.isEmpty
            ? "Completed (\(toolResults.count) tool call\(toolResults.count == 1 ? "" : "s"))"
            : String(output.prefix(150))
        let durationMs = Int(Date().timeIntervalSince(subtaskStartedAt) * 1000)
        continuation.yield(.subtaskCompleted(
            id: subtask.id, index: subtaskIndex, total: allSubtasks.count,
            summary: summary, outcome: terminalOutcome, durationMs: durationMs
        ))

        subtaskSucceeded = true
        return (output, toolResults, terminalOutcome, terminalReason)
    }

    // MARK: - Subtask Result Composition

    /// Composes the plan's user-facing answer from its subtask results: subtasks are labeled with their description and
    /// separated by a blank line, and a single-subtask plan is returned bare. Empty or whitespace-only results are dropped.
    /// An un-opted run returns this text verbatim, so it must stand on its own.
    static func composeSubtaskResults(subtasks: [SubTask], results: [String: String]) -> String {
        let ordered: [(subtask: SubTask, result: String)] = subtasks.compactMap { subtask in
            guard let raw = results[subtask.id] else { return nil }
            let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return nil }
            return (subtask, trimmed)
        }

        guard ordered.count > 1 else { return ordered.first?.result ?? "" }

        return ordered
            .map { "### \($0.subtask.description)\n\n\($0.result)" }
            .joined(separator: "\n\n")
    }

    // MARK: - Dependency Sanitization

    /// Strips orphaned `dependsOn` references after user edits: a dependency on an ID absent from the plan is silently
    /// removed to prevent stalls in level computation.
    static func sanitizeDependencies(_ subtasks: [SubTask]) -> [SubTask] {
        let validIDs = Set(subtasks.map(\.id))
        return subtasks.map { task in
            guard let deps = task.dependsOn else { return task }
            let cleaned = deps.filter { validIDs.contains($0) }
            var sanitized = task
            sanitized.dependsOn = cleaned.isEmpty ? nil : cleaned
            return sanitized
        }
    }

    // MARK: - Dependency Resolution

    /// Computes execution levels from subtask dependsOn fields.
    /// Level 0 = no dependencies, Level 1 = depends only on level 0 tasks, etc.
    /// Subtasks within the same level can run in parallel.
    static func computeExecutionLevels(subtasks: [SubTask]) -> [[String]] {
        let idSet = Set(subtasks.map(\.id))
        var levels: [[String]] = []
        var placed = Set<String>()

        while placed.count < subtasks.count {
            var currentLevel: [String] = []

            for task in subtasks where !placed.contains(task.id) {
                let deps = (task.dependsOn ?? []).filter { idSet.contains($0) }
                if deps.allSatisfy({ placed.contains($0) }) {
                    currentLevel.append(task.id)
                }
            }

            // Safety: if no progress, break to avoid infinite loop
            if currentLevel.isEmpty {
                // Place remaining tasks in final level
                let remaining = subtasks.filter { !placed.contains($0.id) }.map(\.id)
                if !remaining.isEmpty { levels.append(remaining) }
                break
            }

            levels.append(currentLevel)
            placed.formUnion(currentLevel)
        }

        return levels
    }
}
