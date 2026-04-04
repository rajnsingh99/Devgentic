//
//  PlanningCapability.swift
//  Devgentic
//
//  Planning capability: decomposes a task into subtasks via LLM, then executes each
//  subtask using the wrapped inner executor. Supports parallel subtask execution
//  (via dependsOn) and per-subtask tool filtering (via toolHint).
//
//  Extracted from PlanExecuteExecutor.swift during the Agent Capabilities Migration.
//

import Foundation
import OSLog

private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "com.devgentic.app", category: "PlanningCapability")

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

    nonisolated let architecture: AgentArchitecture = .planAndExecute
    nonisolated private let innerExecutor: any Executor
    nonisolated private let config: PlanningCapabilityConfig

    init(innerExecutor: any Executor, config: PlanningCapabilityConfig) {
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

                var sessionState: SessionGraph = input.activeState
                    ?? SessionGraphStore.shared.getActiveState(for: input.conversationID)

                do {
                    logger.info("Planning capability initiated.")

                    let spyModel = APISpyModel(inner: model)
                    let executionTrace = input.traceContext

                    // --- Start Episode ---
                    sessionState.episodes.append(MemoryEpisode(primaryGoal: input.userInput, status: "ACTIVE"))
                    sessionState.workingMemory.removeValue(forKey: "current_focus")
                    SessionGraphStore.shared.updateActiveState(conversationID: input.conversationID, state: sessionState)

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

                    await GlobalRateLimiter.shared.wait(for: input.rateLimitCategory)

                    let envFacts = EnvironmentFacts(
                        osVersion: ProcessInfo.processInfo.operatingSystemVersionString,
                        shellType: "Zsh (Non-Interactive Mode)",
                        userName: NSUserName(),
                        currentDate: Date().formatted(date: .numeric, time: .shortened)
                    )

                    // Read User Personal profile for planning context
                    let userProfile: String? = await MainActor.run {
                        guard UserDefaults.standard.bool(forKey: AppSettings.ciFeatureUserPersonalKey) else { return nil }
                        return UserPersonalService.shared.getProfileForInjection()
                    }

                    let planContext = SemanticContext(
                        instructions: input.instructions,
                        environmentFacts: envFacts,
                        longTermMemory: input.longTermMemory,
                        recentHistory: input.recentHistory,
                        originalQuery: input.userInput,
                        currentIteration: 0,
                        compiledScratchpad: "",
                        latestClarification: nil,
                        negativeConstraints: Set(sessionState.negativeConstraints),
                        hallucinatedTools: [],
                        availableTools: input.tools,
                        userProfile: userProfile
                    )

                    let planGenerator = PlanGeneratorStrategy()
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
                            sessionState.closeActiveEpisode(status: "CANCELLED", outcome: "Plan rejected by user")
                            SessionGraphStore.shared.updateActiveState(conversationID: input.conversationID, state: sessionState)
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

                    for (levelIndex, levelIDs) in levels.enumerated() {
                        try Task.checkCancellation()

                        let levelSubtasks = levelIDs.compactMap { id in subtasks.first(where: { $0.id == id }) }

                        continuation.yield(.thought("Executing level \(levelIndex + 1)/\(levels.count) (\(levelSubtasks.count) subtask\(levelSubtasks.count == 1 ? "" : "s"))..."))

                        if config.parallelSubtasks && levelSubtasks.count > 1 {
                            // Parallel execution — catch per-subtask errors so one failure
                            // doesn't discard results from siblings that completed successfully.
                            await withTaskGroup(of: (String, String?).self) { group in
                                for subtask in levelSubtasks {
                                    group.addTask {
                                        do {
                                            let result = try await self.executeSubtask(
                                                subtask: subtask,
                                                input: input,
                                                model: model,
                                                continuation: continuation,
                                                onTraceUpdate: onTraceUpdate
                                            )
                                            return (subtask.id, result)
                                        } catch is CancellationError {
                                            return (subtask.id, nil)
                                        } catch {
                                            logger.error("Subtask '\(subtask.id)' failed: \(error.localizedDescription)")
                                            continuation.yield(.thought("  [\(subtask.id)] Failed: \(error.localizedDescription)"))
                                            return (subtask.id, "Error: \(error.localizedDescription)")
                                        }
                                    }
                                }
                                for await (id, result) in group {
                                    if let result { subtaskResults[id] = result }
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
                                        input: input,
                                        model: model,
                                        continuation: continuation,
                                        onTraceUpdate: onTraceUpdate
                                    )
                                    subtaskResults[subtask.id] = result
                                } catch is CancellationError {
                                    throw CancellationError()
                                } catch {
                                    logger.error("Subtask '\(subtask.id)' failed: \(error.localizedDescription)")
                                    continuation.yield(.thought("  [\(subtask.id)] Failed: \(error.localizedDescription)"))
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
                    synthesisSummary.markComplete()

                    let response = await ResponseSynthesizer.synthesize(
                        summary: synthesisSummary,
                        model: model,
                        personaInstructions: input.instructions,
                        originalQuery: input.userInput,
                        isNativeFlow: input.generatorStrategy is NativeStructuredGenerator
                    )

                    sessionState.closeActiveEpisode(status: "COMPLETED", outcome: response)
                    SessionGraphStore.shared.updateActiveState(conversationID: input.conversationID, state: sessionState)

                    continuation.yield(.content(response))
                    continuation.finish()

                } catch is CancellationError {
                    logger.notice("Planning capability cancelled.")
                    await ExecutionSuspensionService.shared.cancel(for: input.conversationID)
                    sessionState.cancelActiveEpisode()
                    SessionGraphStore.shared.updateActiveState(conversationID: input.conversationID, state: sessionState)
                    continuation.yield(.thought("Cancelled by user."))
                    continuation.finish()
                } catch {
                    logger.error("Planning capability fatal error: \(error.localizedDescription)")
                    await ExecutionSuspensionService.shared.cancel(for: input.conversationID)
                    continuation.finish(throwing: error)
                }
            }

            continuation.onTermination = { @Sendable _ in task.cancel() }
        }
    }

    // MARK: - Subtask Execution via Inner Executor

    private func executeSubtask(
        subtask: SubTask,
        input: AgentInput,
        model: any LLMProvider,
        continuation: AsyncThrowingStream<AgentStreamEvent, Error>.Continuation,
        onTraceUpdate: @escaping @Sendable (AgentTraceLog) -> Void
    ) async throws -> String {

        continuation.yield(.thought("Subtask: \(subtask.description)"))

        // Optionally filter tools based on toolHint
        let filteredTools: [AgentTool]
        if config.subtaskToolFiltering, let hint = subtask.toolHint, !hint.isEmpty {
            let hintLower = hint.lowercased()
            let matched = input.tools.filter { tool in
                tool.name.lowercased().contains(hintLower) ||
                tool.description.lowercased().contains(hintLower)
            }
            // If filter matches nothing, fall back to all tools
            if matched.isEmpty {
                logger.warning("Tool hint '\(hint)' for subtask '\(subtask.id)' matched no tools. Falling back to all \(input.tools.count) tools.")
            }
            filteredTools = matched.isEmpty ? input.tools : matched
        } else {
            filteredTools = input.tools
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
            workingMemory: input.workingMemory,
            rateLimitCategory: input.rateLimitCategory,
            instructions: input.instructions,
            retryPolicy: input.retryPolicy,
            errorRecovery: input.errorRecovery,
            traceContext: input.traceContext.newSpan()
        )

        // Delegate to inner executor
        let stream = innerExecutor.execute(model: model, input: subtaskInput, onTraceUpdate: onTraceUpdate)

        var output = ""
        for try await event in stream {
            switch event {
            case .content(let text):
                output += text
            case .thought(let thought):
                continuation.yield(.thought("  [\(subtask.id)] \(thought)"))
            case .artifactProduced(let artifact):
                continuation.yield(.artifactProduced(artifact))
            default:
                break
            }
        }

        return output
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
