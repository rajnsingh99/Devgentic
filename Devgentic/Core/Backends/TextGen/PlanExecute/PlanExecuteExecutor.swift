//
//  PlanExecuteExecutor.swift
//  Devgentic
//
//  Plan & Execute architecture: formulates a plan first, then executes each subtask sequentially.
//  Phase 1: LLM decomposes the user query into ordered SubTasks.
//  Phase 2: Each subtask runs a mini ReAct loop (up to maxSubtaskIterations).
//  Phase 3: Results are synthesized into a final response.
//

import Foundation
import OSLog

private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "com.devgentic.app", category: "PlanExecuteExecutor")
private let logState = Logger(subsystem: Bundle.main.bundleIdentifier ?? "com.devgentic.app", category: "PlanState")

actor PlanExecuteExecutor: Executor {

    // MARK: - Properties

    nonisolated let architecture: AgentArchitecture = .planAndExecute
    nonisolated private let maxSubtaskIterations: Int
    nonisolated private let maxPlanningRetries: Int

    // MARK: - Initialization

    init(maxSubtaskIterations: Int = 5, maxPlanningRetries: Int = 2) {
        self.maxSubtaskIterations = maxSubtaskIterations
        self.maxPlanningRetries = maxPlanningRetries
    }

    // MARK: - Execution

    nonisolated func execute(
        model: any LLMProvider,
        input: AgentInput,
        onTraceUpdate: @escaping @Sendable (AgentTraceLog) -> Void
    ) -> AsyncThrowingStream<AgentStreamEvent, Error> {

        return AsyncThrowingStream(AgentStreamEvent.self) { continuation in
            let task = Task {

                var sessionState: SessionGraph = input.activeState ?? SessionGraphStore.shared.getActiveState(for: input.conversationID)

                do {
                    logger.info("Plan & Execute initiated.")

                    let spyModel = APISpyModel(inner: model)
                    let executionTrace = input.traceContext
                    var executionSummary = ExecutionSummary(originalGoal: input.userInput)
                    var circuitBreaker = CognitiveCircuitBreaker()
                    var retryStrategy = LLMRetryStrategy()
                    let toolMediator = ToolExecutionMediator()
                    let subtaskEvaluator = PlanTerminationEvaluator()
                    var planMemory = PlanMemoryStrategy()

                    // --- Start Episode ---
                    sessionState.episodes.append(MemoryEpisode(primaryGoal: input.userInput, status: "ACTIVE"))
                    sessionState.workingMemory.removeValue(forKey: "current_focus")
                    SessionGraphStore.shared.updateActiveState(conversationID: input.conversationID, state: sessionState)

                    // =====================================================================
                    // PHASE 1: PLANNING
                    // =====================================================================

                    let planningSpan = executionTrace.newSpan()
                    onTraceUpdate(AgentTraceLog(
                        traceID: planningSpan.traceID,
                        spanID: planningSpan.spanID,
                        parentSpanID: planningSpan.parentSpanID,
                        stepNumber: 0,
                        state: .thinking(.planning),
                        content: "Decomposing task into subtasks..."
                    ))

                    continuation.yield(.thought("Planning: Decomposing task into subtasks..."))

                    await GlobalRateLimiter.shared.wait(for: input.rateLimitCategory)

                    let envFacts = EnvironmentFacts(
                        osVersion: ProcessInfo.processInfo.operatingSystemVersionString,
                        shellType: "Zsh (Non-Interactive Mode)",
                        userName: NSUserName(),
                        currentDate: Date().formatted(date: .numeric, time: .shortened)
                    )

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
                        availableTools: input.tools
                    )

                    let planGenerator = PlanGeneratorStrategy()
                    var subtasks: [SubTask]

                    do {
                        subtasks = try await planGenerator.generatePlan(model: spyModel, context: planContext)
                    } catch {
                        // Fallback: single task
                        logger.warning("Plan generation failed: \(error.localizedDescription). Using single-task fallback.")
                        subtasks = [SubTask(id: "step_1", description: input.userInput)]
                    }

                    planMemory.loadPlan(subtasks)
                    let planSummary = subtasks.enumerated().map { "  \($0.offset + 1). \($0.element.description)" }.joined(separator: "\n")
                    continuation.yield(.thought("Plan generated with \(subtasks.count) steps:\n\(planSummary)"))
                    logger.info("Plan generated: \(subtasks.count) subtasks.")

                    // =====================================================================
                    // PHASE 2: EXECUTION (loop over subtasks)
                    // =====================================================================

                    var globalStep = 0

                    for subtaskIndex in subtasks.indices {
                        try Task.checkCancellation()

                        let subtask = subtasks[subtaskIndex]
                        planMemory.markSubtask(at: subtaskIndex, status: .inProgress)
                        planMemory.clearCurrentStepObservations()

                        let subtaskSpan = executionTrace.newSpan()
                        onTraceUpdate(AgentTraceLog(
                            traceID: subtaskSpan.traceID,
                            spanID: subtaskSpan.spanID,
                            parentSpanID: subtaskSpan.parentSpanID,
                            stepNumber: subtaskIndex + 1,
                            state: .acting(.subtask(current: subtaskIndex + 1, total: subtasks.count)),
                            content: "Executing subtask: \(subtask.description)"
                        ))

                        continuation.yield(.thought("Step \(subtaskIndex + 1)/\(subtasks.count): \(subtask.description)"))

                        // --- Inner ReAct loop for this subtask ---
                        var innerIteration = 0
                        var subtaskCompleted = false

                        innerLoop: while innerIteration < self.maxSubtaskIterations {
                            try Task.checkCancellation()
                            innerIteration += 1
                            globalStep += 1

                            await GlobalRateLimiter.shared.wait(for: input.rateLimitCategory)

                            let iterationSpan = executionTrace.newSpan()

                            let stepContext = SemanticContext(
                                instructions: input.instructions,
                                environmentFacts: envFacts,
                                longTermMemory: input.longTermMemory,
                                recentHistory: input.recentHistory,
                                originalQuery: subtask.description,
                                currentIteration: innerIteration,
                                compiledScratchpad: planMemory.compileForPrompt(),
                                latestClarification: nil,
                                negativeConstraints: Set(sessionState.negativeConstraints),
                                hallucinatedTools: circuitBreaker.hallucinatedTools,
                                availableTools: input.tools
                            )

                            // Generate cognitive step
                            let step: ModernCognitiveStep
                            do {
                                step = try await input.generatorStrategy.generateCognitiveStep(
                                    model: spyModel,
                                    context: stepContext,
                                    iteration: innerIteration
                                )
                                retryStrategy.resetParseFailures()
                            } catch {
                                let action = retryStrategy.handleError(error)
                                switch action {
                                case .throttle(let seconds, let message):
                                    await GlobalRateLimiter.shared.drainAndPenalize(category: input.rateLimitCategory, penaltySeconds: seconds)
                                    continuation.yield(.thought(message))
                                    try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
                                    innerIteration -= 1
                                    continue innerLoop
                                case .networkRetry(let message):
                                    continuation.yield(.thought(message))
                                    innerIteration -= 1
                                    continue innerLoop
                                case .parseRetry(let systemAlert, let attemptCount, let maxAttempts):
                                    planMemory.recordSystemAlert(msg: systemAlert)
                                    continuation.yield(.thought("⚠️ Parse error. Retrying (\(attemptCount)/\(maxAttempts))..."))
                                    continue innerLoop
                                case .modelReload(let message):
                                    continuation.yield(.thought(message))
                                    let reloaded = await MLXService.shared.reloadCurrentModel()
                                    if !reloaded {
                                        planMemory.markSubtask(at: subtaskIndex, status: .failed, result: "Model unloaded and could not be reloaded.")
                                        break innerLoop
                                    }
                                    innerIteration -= 1
                                    continue innerLoop
                                case .abort(let reason):
                                    planMemory.markSubtask(at: subtaskIndex, status: .failed, result: reason)
                                    break innerLoop
                                }
                            }

                            // Yield thoughts
                            if let thought = step.thought, !thought.isEmpty {
                                continuation.yield(.thought(thought))
                            }
                            if !step.reasoning.isEmpty && step.reasoning != step.thought {
                                continuation.yield(.thought(step.reasoning))
                            }

                            // Termination check
                            let termStatus = subtaskEvaluator.evaluate(step: step, currentIteration: innerIteration, maxIterations: self.maxSubtaskIterations)
                            switch termStatus {
                            case .maxIterationsReached:
                                break
                            case .completed(let finalThought):
                                planMemory.markSubtask(at: subtaskIndex, status: .completed, result: finalThought)
                                subtaskCompleted = true
                                break innerLoop
                            case .suspectedFormatFailure:
                                planMemory.recordSystemAlert(msg: "Format failure: model described tool usage in prose without structured calls.")
                                continue innerLoop
                            case .proceed:
                                break
                            }

                            if step.toolCalls.isEmpty {
                                planMemory.markSubtask(at: subtaskIndex, status: .completed, result: step.reasoning)
                                subtaskCompleted = true
                                break innerLoop
                            }

                            // Execute tools
                            let observations = try await executeToolCalls(
                                toolCalls: step.toolCalls,
                                availableTools: input.tools,
                                conversationID: input.conversationID,
                                currentIteration: globalStep,
                                iterationSpan: iterationSpan,
                                toolMediator: toolMediator,
                                continuation: continuation,
                                onTraceUpdate: onTraceUpdate
                            )

                            // Record observations
                            for obs in observations {
                                planMemory.recordObservation(stepId: globalStep, toolCallId: obs.toolCallId, toolName: obs.toolName, result: obs.result)
                                executionSummary.record(toolCallId: obs.toolCallId, toolName: obs.toolName, params: obs.params, output: obs.output, isSuccess: obs.isSuccess)

                                let resultAction = circuitBreaker.recordToolResult(isSuccess: obs.isSuccess)
                                if case .abort(let reason) = resultAction {
                                    planMemory.markSubtask(at: subtaskIndex, status: .failed, result: reason)
                                    break innerLoop
                                }
                                if !obs.isSuccess {
                                    circuitBreaker.recordHallucination(obs.toolName)
                                }
                            }

                            // Repetitive action loop detection
                            let repetitiveAction = circuitBreaker.evaluateRepetitiveActions(observations)
                            if case .abort(let reason) = repetitiveAction {
                                planMemory.markSubtask(at: subtaskIndex, status: .failed, result: reason)
                                break innerLoop
                            }

                            circuitBreaker.resetCountersOnSuccess()

                        } // End inner loop

                        if !subtaskCompleted {
                            planMemory.markSubtask(at: subtaskIndex, status: .failed, result: "Exhausted iteration budget.")
                        }

                    } // End subtask loop

                    // =====================================================================
                    // PHASE 3: SYNTHESIS
                    // =====================================================================

                    let allCompleted = planMemory.subtasks.allSatisfy { $0.status == .completed }
                    let exitStatus = allCompleted ? "COMPLETED" : "FAILED"

                    if !allCompleted {
                        let failedSteps = planMemory.subtasks.filter { $0.status == .failed }.map(\.description).joined(separator: ", ")
                        executionSummary.markComplete(failureReason: "Failed subtasks: \(failedSteps)")
                    } else {
                        executionSummary.markComplete()
                    }

                    // --- UI Progress: Synthesis ---
                    continuation.yield(.thought("Composing final response…"))

                    // Use the plan summary as the final thought for native flows
                    let planResult = planMemory.subtasks
                        .filter { $0.status == .completed }
                        .compactMap(\.result)
                        .joined(separator: "\n")
                    executionSummary.finalAgentThought = planResult.isEmpty ? nil : planResult

                    let response = await ResponseSynthesizer.synthesize(
                        summary: executionSummary,
                        model: model,
                        personaInstructions: input.instructions,
                        originalQuery: input.userInput,
                        isNativeFlow: input.generatorStrategy is NativeStructuredGenerator
                    )

                    sessionState.closeActiveEpisode(status: exitStatus, outcome: response)
                    SessionGraphStore.shared.updateActiveState(conversationID: input.conversationID, state: sessionState)

                    onTraceUpdate(AgentTraceLog(
                        traceID: executionTrace.newSpan().traceID,
                        spanID: executionTrace.newSpan().spanID,
                        parentSpanID: executionTrace.parentSpanID,
                        stepNumber: globalStep,
                        state: .thinking(.finalizing),
                        content: exitStatus == "COMPLETED" ? "All subtasks completed." : "Plan execution finished with failures."
                    ))

                    logger.info("--- 🏁 PLAN & EXECUTE COMPLETE 🏁 ---")
                    logger.info("Model: \(model.modelName)")
                    logger.info("Final Synthesized Response: \(response)")
                    logger.info("---------------------------------------")

                    continuation.yield(.content(response))
                    continuation.finish()

                } catch is CancellationError {
                    logger.notice("Plan & Execute cancelled.")
                    await ExecutionSuspensionService.shared.cancel(for: input.conversationID)
                    sessionState.cancelActiveEpisode()
                    SessionGraphStore.shared.updateActiveState(conversationID: input.conversationID, state: sessionState)
                    continuation.yield(.thought("Cancelled by user."))
                    continuation.finish()
                } catch {
                    logger.error("Plan & Execute fatal error: \(error.localizedDescription)")
                    await ExecutionSuspensionService.shared.cancel(for: input.conversationID)
                    continuation.finish(throwing: error)
                }
            }

            continuation.onTermination = { @Sendable _ in task.cancel() }
        }
    }
}
