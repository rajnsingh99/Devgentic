//
//  PlanningCapability.swift
//  Devgentic
//
//  Planning capability: decomposes a task into subtasks via LLM, then executes each
//  subtask using the wrapped inner executor. Supports parallel subtask execution
//  (via dependsOn) and per-subtask tool filtering (via toolHints).
//
//  Extracted from PlanExecuteExecutor.swift during the Agent Capabilities Migration.
//

import Foundation
import OSLog

private let logger = DGLogger(category: "PlanningCapability")

// MARK: - Capability Definition

struct PlanningCapability: ExecutorCapability, Sendable {
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
        // PlanningCapability seeds dependency results into workingMemory.
        // This only works with executors that consume AgentInput.workingMemory
        // (e.g., ReActAgentExecutor). If wired to a non-consuming executor,
        // seeded context is silently discarded.
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

                do {
                    logger.info("Planning capability initiated.")

                    let spyModel = APISpyModel(inner: model)
                    let executionTrace = input.traceContext

                    // --- Start Episode ---
                    sessionState.episodes.append(MemoryEpisode(primaryGoal: input.userInput, status: .active))
                    sessionState.workingMemory.removeValue(forKey: "current_focus")
                    await SessionGraphStore.shared.updateActiveState(conversationID: input.conversationID, state: sessionState)

                    // =====================================================================
                    // PHASE 1: PLANNING
                    // =====================================================================

                    continuation.yield(.thought("Planning: Decomposing task into subtasks..."))

                    onTraceUpdate(AgentTraceLog(
                        traceID: executionTrace.traceID,
                        spanID: executionTrace.newSpan().spanID,
                        parentSpanID: executionTrace.parentSpanID,
                        stepNumber: 0,
                        state: .thinking(.planning),
                        content: "Decomposing task into subtasks..."
                    ))

                    await GlobalRateLimiter.shared.wait(forKey: input.rateLimitKey, category: input.rateLimitCategory)

                    let envFacts = EnvironmentFacts(
                        osVersion: ProcessInfo.processInfo.operatingSystemVersionString,
                        shellType: "Zsh (Non-Interactive Mode)",
                        userName: NSUserName(),
                        currentDate: Date().formatted(date: .numeric, time: .shortened)
                    )

                    // Read User Personal profile for planning context.
                    // Suppressed in workflow mode — workflow nodes operate on task+input, not personal context.
                    let userProfile: String?
                    if input.workflowContext == nil {
                        userProfile = await MainActor.run {
                            guard UserDefaults.standard.bool(forKey: AppSettings.ciFeatureUserPersonalKey) else { return nil }
                            return UserPersonalService.shared.getProfileForInjection()
                        }
                    } else {
                        userProfile = nil
                    }

                    let planContext = SemanticContext(
                        instructions: input.instructions,
                        environmentFacts: envFacts,
                        longTermMemory: input.longTermMemory,
                        recentHistory: input.recentHistory,
                        nativeHistoryTurns: input.nativeHistoryTurns,
                        originalQuery: input.userInput,
                        currentIteration: 0,
                        compiledScratchpad: "",
                        latestClarification: nil,
                        negativeConstraints: Set(sessionState.negativeConstraints),
                        hallucinatedTools: [],
                        availableTools: input.tools,
                        userProfile: userProfile,
                        skillManifests: input.skillManifests,
                        taskDescription: nil,
                        promptLayerConfig: .agent,
                        workflowContext: nil
                    )

                    let planGenerator = PlanGeneratorStrategy(planningConfig: config)
                    var subtasks: [SubTask]

                    do {
                        subtasks = try await planGenerator.generatePlan(model: spyModel, context: planContext)
                        // Cap to configured max
                        if subtasks.count > config.maxSubtasks {
                            subtasks = Array(subtasks.prefix(config.maxSubtasks))
                        }
                    } catch {
                        logger.warning("Plan generation failed: \(error.localizedDescription). Using single-task fallback.")
                        subtasks = [SubTask(id: "step_1", description: input.userInput)]
                    }

                    let planSummary = subtasks.enumerated()
                        .map { "  \($0.offset + 1). \($0.element.description)" }
                        .joined(separator: "\n")
                    continuation.yield(.planGenerated(subtaskCount: subtasks.count))
                    continuation.yield(.thought("Plan generated with \(subtasks.count) steps:\n\(planSummary)"))
                    logger.info("Plan generated: \(subtasks.count) subtasks.")

                    // =====================================================================
                    // PHASE 1.5: PLAN REVIEW GATE (if enabled)
                    // =====================================================================

                    if config.requiresPlanApproval && !subtasks.isEmpty {
                        let reviewOperationID = UUID()
                        continuation.yield(.requestPlanReview(subtasks: subtasks, operationID: reviewOperationID))
                        logger.info("Plan review requested. Suspending until user approves or rejects.")

                        guard let approvedPlan = await ExecutionSuspensionService.shared
                            .suspendForPlanReview(for: reviewOperationID, conversationID: input.conversationID)
                        else {
                            // User rejected the plan or stream was cancelled
                            logger.info("Plan rejected by user.")
                            continuation.yield(.content("Plan was cancelled. Let me know if you'd like a different approach."))
                            sessionState.closeActiveEpisode(outcome: .cancelled, message: "Plan rejected by user")
                            await SessionGraphStore.shared.updateActiveState(conversationID: input.conversationID, state: sessionState)
                            continuation.yield(.executionFinished(outcome: .cancelled, reason: "Plan rejected by user"))
                            continuation.finish()
                            return
                        }

                        subtasks = Self.sanitizeDependencies(approvedPlan)
                        continuation.yield(.thought("Plan approved (\(subtasks.count) subtasks). Starting execution..."))
                        logger.info("Plan approved with \(subtasks.count) subtasks. Proceeding to execution.")
                    }

                    // =====================================================================
                    // PHASE 2: EXECUTION — compute dependency levels, run per level
                    // =====================================================================

                    let levels = Self.computeExecutionLevels(subtasks: subtasks)
                    var subtaskResults: [String: String] = [:]
                    var allToolResults: [ToolOutput] = []  // [G4] Aggregate across subtasks

                    for (levelIndex, levelIDs) in levels.enumerated() {
                        try Task.checkCancellation()

                        let levelSubtasks = levelIDs.compactMap { id in subtasks.first(where: { $0.id == id }) }

                        continuation.yield(.thought("Executing level \(levelIndex + 1)/\(levels.count) (\(levelSubtasks.count) subtask\(levelSubtasks.count == 1 ? "" : "s"))..."))

                        if config.parallelSubtasks && levelSubtasks.count > 1 {
                            // Parallel execution — catch per-subtask errors so one failure
                            // doesn't discard results from siblings that completed successfully.
                            // Snapshot results from prior levels for dependency seeding.
                            // Parallel siblings at the same level won't see each other's
                            // results (correct — they're independent by definition).
                            let priorResults = subtaskResults

                            await withTaskGroup(of: (String, String?, [ToolOutput]).self) { group in
                                for subtask in levelSubtasks {
                                    group.addTask {
                                        do {
                                            let result = try await self.executeSubtask(
                                                subtask: subtask,
                                                allSubtasks: subtasks,
                                                priorResults: priorResults,
                                                input: input,
                                                model: model,
                                                continuation: continuation,
                                                onTraceUpdate: onTraceUpdate
                                            )
                                            return (subtask.id, result.output, result.toolResults)
                                        } catch is CancellationError {
                                            return (subtask.id, nil, [])
                                        } catch {
                                            logger.error("Subtask '\(subtask.id)' failed: \(error.localizedDescription)")
                                            // Structured warning — this is a system signal (subtask threw)
                                            // not model reasoning. UI renders it distinctly from thoughts and
                                            // downstream consumers (negativeConstraints, episodic memory) see
                                            // a machine-readable category.
                                            continuation.yield(.warning(
                                                category: .retry,
                                                message: "Subtask '\(subtask.id)' failed: \(error.localizedDescription)",
                                                relatedPath: subtask.id
                                            ))
                                            return (subtask.id, "Error: \(error.localizedDescription)", [])
                                        }
                                    }
                                }
                                for await (id, result, tools) in group {
                                    if let result { subtaskResults[id] = result }
                                    allToolResults.append(contentsOf: tools)
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
                                        continuation: continuation,
                                        onTraceUpdate: onTraceUpdate
                                    )
                                    subtaskResults[subtask.id] = result.output
                                    allToolResults.append(contentsOf: result.toolResults)
                                } catch is CancellationError {
                                    throw CancellationError()
                                } catch {
                                    logger.error("Subtask '\(subtask.id)' failed: \(error.localizedDescription)")
                                    continuation.yield(.warning(
                                        category: .retry,
                                        message: "Subtask '\(subtask.id)' failed: \(error.localizedDescription)",
                                        relatedPath: subtask.id
                                    ))
                                    subtaskResults[subtask.id] = "Error: \(error.localizedDescription)"
                                }
                            }
                        }
                    }

                    // =====================================================================
                    // PHASE 3: SYNTHESIS
                    // =====================================================================

                    continuation.yield(.thought("Composing final response..."))

                    let combinedResults = subtasks.compactMap { subtaskResults[$0.id] }.joined(separator: "\n")

                    var synthesisSummary = ExecutionSummary(originalGoal: input.userInput)
                    synthesisSummary.finalAgentThought = combinedResults.isEmpty ? nil : combinedResults
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
                    synthesisSummary.markComplete()

                    let response = await ResponseSynthesizer.synthesize(
                        summary: synthesisSummary,
                        personaInstructions: input.instructions,
                        originalQuery: input.userInput,
                        isNativeFlow: input.generatorStrategy is NativeStructuredGenerator,
                        forceSynthesis: input.responseSynthesisEnabled
                    )

                    // Partial-failure detection: if all subtasks errored, treat as .failed
                    // even though we still produced a synthesized response (honesty over polish).
                    // Errors are marked by the "Error: " prefix written at subtask catch sites above.
                    let totalSubtasks = subtasks.count
                    let failedSubtasks = subtaskResults.values.filter { $0.hasPrefix("Error:") }.count
                    let allFailed = totalSubtasks > 0 && failedSubtasks == totalSubtasks
                    let terminalOutcome: ExecutionOutcome = allFailed ? .failed : .completed
                    let terminalReason: String? = failedSubtasks > 0
                        ? "\(failedSubtasks) of \(totalSubtasks) subtasks failed"
                        : nil

                    sessionState.closeActiveEpisode(outcome: terminalOutcome, message: response)
                    await SessionGraphStore.shared.updateActiveState(conversationID: input.conversationID, state: sessionState)

                    continuation.yield(.content(response))
                    continuation.yield(.executionFinished(outcome: terminalOutcome, reason: terminalReason))
                    continuation.finish()

                } catch is CancellationError {
                    logger.notice("Planning capability cancelled.")
                    await ExecutionSuspensionService.shared.cancel(for: input.conversationID)
                    sessionState.cancelActiveEpisode()
                    await SessionGraphStore.shared.updateActiveState(conversationID: input.conversationID, state: sessionState)
                    continuation.yield(.thought("Cancelled by user."))
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
                    await ExecutionSuspensionService.shared.cancel(for: input.conversationID)
                    continuation.yield(.executionFinished(outcome: .failed, reason: classified.message))
                    continuation.finish(throwing: error)
                }
            }

            continuation.onTermination = { @Sendable _ in task.cancel() }
        }
    }

    // MARK: - Subtask Execution via Inner Executor

    /// - Parameters:
    ///   - subtask: The subtask to execute.
    ///   - allSubtasks: The full plan (used to look up dependency descriptions).
    ///   - priorResults: Results from already-completed subtasks (keyed by subtask ID).
    ///     For parallel execution this is a snapshot from prior levels; for sequential
    ///     execution it includes all results accumulated so far.
    private func executeSubtask(
        subtask: SubTask,
        allSubtasks: [SubTask],
        priorResults: [String: String],
        input: AgentInput,
        model: any LLMProvider,
        continuation: AsyncThrowingStream<AgentStreamEvent, Error>.Continuation,
        onTraceUpdate: @escaping @Sendable (AgentTraceLog) -> Void
    ) async throws -> (output: String, toolResults: [ToolOutput]) {

        let subtaskIndex = (allSubtasks.firstIndex(where: { $0.id == subtask.id }) ?? 0) + 1
        continuation.yield(.subtaskStarted(index: subtaskIndex, total: allSubtasks.count, description: subtask.description))
        continuation.yield(.thought("Subtask: \(subtask.description)"))

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

        // Build subtask-scoped input
        let subtaskInput = AgentInput(
            userInput: subtask.description,
            chatHistory: input.chatHistory,
            conversationID: input.conversationID,
            tools: filteredTools,
            longTermMemory: input.longTermMemory,
            activeState: input.activeState,
            recentHistory: input.recentHistory,
            generatorStrategy: input.generatorStrategy,
            workingMemory: seededMemory,
            rateLimitKey: input.rateLimitKey,
            rateLimitCategory: input.rateLimitCategory,
            instructions: input.instructions,
            skillManifests: input.skillManifests,
            skillFolderPath: input.skillFolderPath,
            retryPolicy: input.retryPolicy,
            errorRecovery: input.errorRecovery,
            responseSynthesisEnabled: input.responseSynthesisEnabled,
            nativeHistoryTurns: input.nativeHistoryTurns,
            suppressEpisodeManagement: true,
            traceContext: input.traceContext.newSpan()
        )

        // Delegate to inner executor
        let stream = innerExecutor.execute(model: model, input: subtaskInput, onTraceUpdate: onTraceUpdate)

        var output = ""
        var toolResults: [ToolOutput] = []
        for try await event in stream {
            switch event {
            case .content(let text):
                output += text
            case .thought(let thought, _, _):
                continuation.yield(.thought("  [\(subtask.id)] \(thought)"))
            case .toolCall(let name, let params, _):
                // [G11] Forward tool invocation events so UI shows tool activity during subtasks.
                continuation.yield(.toolCall(name: name, params: params))
            case .toolSucceeded(let toolOutput, let durationMs, _):
                // [G4] Capture subtask tool results for synthesis aggregation.
                toolResults.append(toolOutput)
                continuation.yield(.toolSucceeded(toolOutput, durationMs: durationMs))
            case .toolFailed(let toolOutput, let category, let suggestion, _):
                toolResults.append(toolOutput)
                continuation.yield(.toolFailed(toolOutput, category: category, suggestion: suggestion))
            case .requestConfirmation(let toolName, let params, let operationID, let sourceNodeID):
                // [G9] Forward HITL permission requests — user must see these during subtasks.
                continuation.yield(.requestConfirmation(toolName: toolName, params: params, operationID: operationID, sourceNodeID: sourceNodeID))
            case .requestClarification(let question, let operationID, let sourceNodeID):
                // [G9] Forward HITL clarification requests.
                continuation.yield(.requestClarification(question: question, operationID: operationID, sourceNodeID: sourceNodeID))
            case .error(let msg):
                continuation.yield(.error(msg))
            case .warning(let cat, let msg, let relatedPath, _):
                // [G11] Forward warnings so UI surfaces memory-pressure / retry / parse-failure signals during subtasks.
                continuation.yield(.warning(category: cat, message: "[\(subtask.id)] \(msg)", relatedPath: relatedPath))
            case .artifactProduced(let artifact):
                continuation.yield(.artifactProduced(artifact))
            case .tokenUsage(let usage):
                continuation.yield(.tokenUsage(usage))
            default:
                break
            }
        }

        let summary = output.isEmpty
            ? "Completed (\(toolResults.count) tool call\(toolResults.count == 1 ? "" : "s"))"
            : String(output.prefix(150))
        continuation.yield(.subtaskCompleted(index: subtaskIndex, total: allSubtasks.count, summary: summary))

        return (output, toolResults)
    }

    // MARK: - Dependency Sanitization

    /// Strips orphaned `dependsOn` references after user edits.
    /// If a subtask depends on an ID that no longer exists in the plan,
    /// that dependency is silently removed to prevent stalls in level computation.
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
