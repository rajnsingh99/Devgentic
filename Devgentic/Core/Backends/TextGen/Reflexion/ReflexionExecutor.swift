//
//  ReflexionExecutor.swift
//  Devgentic
//
//  Reflexion architecture: wraps a ReAct-style inner loop with an outer self-reflection loop.
//  After each trial, a ReflectionEvaluator critiques the outcome. If unacceptable,
//  the critique is injected into the next trial's context for self-improvement.
//

import Foundation
import OSLog

private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "com.devgentic.app", category: "ReflexionExecutor")
private let logState = Logger(subsystem: Bundle.main.bundleIdentifier ?? "com.devgentic.app", category: "ReflexionState")

actor ReflexionExecutor: Executor {

    // MARK: - Properties

    nonisolated let architecture: AgentArchitecture = .reflexion
    nonisolated private let maxTrials: Int
    nonisolated private let maxInnerIterations: Int

    // MARK: - Initialization

    init(maxTrials: Int = 3, maxInnerIterations: Int = 10) {
        self.maxTrials = maxTrials
        self.maxInnerIterations = maxInnerIterations
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
                var accumulatedConstraints = Set(sessionState.negativeConstraints)

                do {
                    logger.info("Reflexion execution initiated.")

                    let spyModel = APISpyModel(inner: model)
                    let executionTrace = input.traceContext
                    let reflectionEvaluator = ReflectionEvaluator()
                    let toolMediator = ToolExecutionMediator()
                    let terminationEvaluator = EpisodeTerminationEvaluator()
                    var reflexionMemory = ReflexionMemoryStrategy()

                    // --- Start Episode ---
                    sessionState.episodes.append(MemoryEpisode(primaryGoal: input.userInput, status: "ACTIVE"))
                    sessionState.workingMemory.removeValue(forKey: "current_focus")
                    SessionGraphStore.shared.updateActiveState(conversationID: input.conversationID, state: sessionState)

                    let envFacts = EnvironmentFacts(
                        osVersion: ProcessInfo.processInfo.operatingSystemVersionString,
                        shellType: "Zsh (Non-Interactive Mode)",
                        userName: NSUserName(),
                        currentDate: Date().formatted(date: .numeric, time: .shortened)
                    )

                    var bestSummary: ExecutionSummary?
                    var globalStep = 0

                    // =====================================================================
                    // OUTER LOOP: TRIALS
                    // =====================================================================

                    trialLoop: for trial in 1...self.maxTrials {
                        try Task.checkCancellation()

                        let trialSpan = executionTrace.newSpan()
                        onTraceUpdate(AgentTraceLog(
                            traceID: trialSpan.traceID,
                            spanID: trialSpan.spanID,
                            parentSpanID: trialSpan.parentSpanID,
                            stepNumber: globalStep,
                            state: .thinking(.reasoning),
                            content: "Starting trial \(trial)/\(self.maxTrials)"
                        ))

                        if trial > 1 {
                            continuation.yield(.thought("Starting trial \(trial)/\(self.maxTrials) with reflection feedback..."))
                        }

                        var trialSummary = ExecutionSummary(originalGoal: input.userInput)
                        var circuitBreaker = CognitiveCircuitBreaker()
                        var retryStrategy = LLMRetryStrategy()
                        var innerIteration = 0
                        var latestClarification: String? = nil

                        // =============================================================
                        // INNER LOOP: ReAct-style execution
                        // =============================================================

                        innerLoop: while innerIteration < self.maxInnerIterations {
                            try Task.checkCancellation()
                            innerIteration += 1
                            globalStep += 1

                            // Rate limit
                            await GlobalRateLimiter.shared.wait(for: input.rateLimitCategory)

                            let iterationSpan = executionTrace.newSpan()

                            let context = SemanticContext(
                                instructions: input.instructions,
                                environmentFacts: envFacts,
                                longTermMemory: input.longTermMemory,
                                compressedStateGraph: sessionState.compressWithPointers(windowSize: 5),
                                recentHistory: input.recentHistory,
                                originalQuery: input.userInput,
                                currentIteration: innerIteration,
                                compiledScratchpad: reflexionMemory.compileForPrompt(),
                                latestClarification: latestClarification,
                                negativeConstraints: accumulatedConstraints,
                                hallucinatedTools: circuitBreaker.hallucinatedTools,
                                availableTools: input.tools
                            )

                            // Generate cognitive step
                            let step: ModernCognitiveStep
                            do {
                                step = try await input.generatorStrategy.generateCognitiveStep(
                                    model: spyModel,
                                    context: context,
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
                                    reflexionMemory.recordSystemAlert(msg: systemAlert)
                                    continuation.yield(.thought("⚠️ Parse error. Retrying (\(attemptCount)/\(maxAttempts))..."))
                                    continue innerLoop
                                case .modelReload(let message):
                                    continuation.yield(.thought(message))
                                    let reloaded = await MLXService.shared.reloadCurrentModel()
                                    if !reloaded {
                                        trialSummary.markComplete(failureReason: "Model unloaded and could not be reloaded.")
                                        break innerLoop
                                    }
                                    innerIteration -= 1
                                    continue innerLoop
                                case .abort(let reason):
                                    trialSummary.markComplete(failureReason: reason)
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
                            let termStatus = terminationEvaluator.evaluate(step: step, currentIteration: innerIteration, maxIterations: self.maxInnerIterations)
                            switch termStatus {
                            case .maxIterationsReached:
                                break
                            case .completed(let finalThought):
                                trialSummary.finalAgentThought = finalThought
                                break innerLoop
                            case .suspectedFormatFailure:
                                reflexionMemory.recordSystemAlert(msg: "Format failure: structured tool call expected.")
                                continue innerLoop
                            case .proceed:
                                break
                            }

                            if step.toolCalls.isEmpty {
                                trialSummary.finalAgentThought = step.reasoning
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
                                reflexionMemory.recordObservation(stepId: globalStep, toolCallId: obs.toolCallId, toolName: obs.toolName, result: obs.result)
                                trialSummary.record(toolCallId: obs.toolCallId, toolName: obs.toolName, params: obs.params, output: obs.output, isSuccess: obs.isSuccess)

                                let resultAction = circuitBreaker.recordToolResult(isSuccess: obs.isSuccess)
                                if case .abort(let reason) = resultAction {
                                    trialSummary.markComplete(failureReason: reason)
                                    break innerLoop
                                }
                                if !obs.isSuccess {
                                    circuitBreaker.recordHallucination(obs.toolName)
                                }
                            }

                            circuitBreaker.resetCountersOnSuccess()

                        } // End inner loop

                        // Mark trial complete if not already marked
                        if trialSummary.failureReason == nil {
                            trialSummary.markComplete()
                        }
                        bestSummary = trialSummary

                        // =============================================================
                        // REFLECTION PHASE
                        // =============================================================

                        // Skip reflection on the last trial
                        guard trial < self.maxTrials else { break trialLoop }

                        let reflectionSpan = executionTrace.newSpan()
                        onTraceUpdate(AgentTraceLog(
                            traceID: reflectionSpan.traceID,
                            spanID: reflectionSpan.spanID,
                            parentSpanID: reflectionSpan.parentSpanID,
                            stepNumber: globalStep,
                            state: .thinking(.reflecting),
                            content: "Evaluating trial \(trial) outcome..."
                        ))

                        continuation.yield(.thought("Reflecting on trial \(trial) outcome..."))

                        await GlobalRateLimiter.shared.wait(for: input.rateLimitCategory)

                        let reflection = try await reflectionEvaluator.evaluate(
                            summary: trialSummary,
                            originalGoal: input.userInput,
                            model: spyModel,
                            trial: trial
                        )

                        if reflection.isAcceptable {
                            logger.info("Trial \(trial) accepted by reflection evaluator.")
                            continuation.yield(.thought("Reflection: Trial \(trial) outcome is acceptable."))
                            break trialLoop
                        }

                        // Not acceptable — prepare for next trial
                        logger.info("Trial \(trial) rejected. Critique: \(reflection.critique)")
                        continuation.yield(.thought("Reflection: \(reflection.critique)"))

                        reflexionMemory.addReflection(
                            trial: trial,
                            critique: reflection.critique,
                            suggestedRevisions: reflection.suggestedRevisions
                        )
                        reflexionMemory.startNewTrial()

                        // Add failed approaches to constraints
                        accumulatedConstraints.insert("Trial \(trial) failed: \(reflection.critique)")

                    } // End trial loop

                    // =====================================================================
                    // SYNTHESIS
                    // =====================================================================

                    // --- UI Progress: Synthesis ---
                    continuation.yield(.thought("Composing final response…"))

                    let summary = bestSummary ?? ExecutionSummary(originalGoal: input.userInput)
                    let exitStatus: String
                    switch summary.completionStatus {
                    case .success, .partialSuccess:
                        exitStatus = "COMPLETED"
                    default:
                        exitStatus = "FAILED"
                    }

                    let response = await ResponseSynthesizer.synthesize(
                        summary: summary,
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
                        content: "Reflexion complete after \(reflexionMemory.currentTrial) trial(s)."
                    ))

                    continuation.yield(.content(response))
                    continuation.finish()

                } catch is CancellationError {
                    logger.notice("Reflexion cancelled.")
                    await ExecutionSuspensionService.shared.cancel(for: input.conversationID)
                    sessionState.cancelActiveEpisode()
                    SessionGraphStore.shared.updateActiveState(conversationID: input.conversationID, state: sessionState)
                    continuation.yield(.thought("Cancelled by user."))
                    continuation.finish()
                } catch {
                    logger.error("Reflexion fatal error: \(error.localizedDescription)")
                    await ExecutionSuspensionService.shared.cancel(for: input.conversationID)
                    continuation.finish(throwing: error)
                }
            }

            continuation.onTermination = { @Sendable _ in task.cancel() }
        }
    }
}
