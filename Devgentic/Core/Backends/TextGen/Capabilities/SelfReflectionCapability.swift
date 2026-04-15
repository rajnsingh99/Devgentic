//
//  SelfReflectionCapability.swift
//  Devgentic
//
//  Self-reflection capability: runs the wrapped executor, evaluates the result,
//  and retries with accumulated critique if the outcome is unacceptable.
//
//  Extracted from ReflexionExecutor.swift during the Agent Capabilities Migration.
//

import Foundation
import OSLog

private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "com.devgentic.app", category: "SelfReflectionCapability")

// MARK: - Internal Memory (migrated from ReflexionMemoryState)

/// Tracks trial history and self-reflections across retries.
/// Scoped to SelfReflectionCapability — not shared outside.
private struct ReflexionMemoryState {
    var trials: [(trialNumber: Int, critique: String, suggestedRevisions: String?)] = []
    var currentTrial: Int = 1

    mutating func addReflection(trial: Int, critique: String, suggestedRevisions: String?) {
        trials.append((trialNumber: trial, critique: critique, suggestedRevisions: suggestedRevisions))
    }

    mutating func startNewTrial() {
        currentTrial += 1
    }

    func compileForPrompt() -> String {
        var lines: [String] = []

        if !trials.isEmpty {
            lines.append("## Previous Trial Reflections")
            for trial in trials {
                lines.append("### Trial \(trial.trialNumber) (REFLECTED)")
                lines.append("Critique: \(trial.critique)")
                if let revisions = trial.suggestedRevisions {
                    lines.append("Suggested: \(revisions)")
                }
                lines.append("")
            }
        }

        lines.append("### Trial \(currentTrial) (CURRENT)")
        return lines.joined(separator: "\n")
    }
}

// MARK: - Capability Definition

struct SelfReflectionCapability: ExecutorCapability, Sendable {
    let config: SelfReflectionConfig

    func wrap(_ executor: any Executor) -> any Executor {
        SelfReflectionExecutorWrapper(
            innerExecutor: executor,
            config: config
        )
    }
}

// MARK: - Executor Wrapper

actor SelfReflectionExecutorWrapper: Executor {

    nonisolated let executorLabel: String = "Reflexion → ReAct"
    nonisolated private let innerExecutor: any Executor
    nonisolated private let config: SelfReflectionConfig

    init(innerExecutor: any Executor, config: SelfReflectionConfig) {
        // SelfReflectionCapability seeds prior trial output into workingMemory.
        // This only works with executors that consume AgentInput.workingMemory.
        assert(innerExecutor is ReActAgentExecutor,
               "SelfReflectionCapability requires an inner executor that consumes workingMemory (e.g., ReActAgentExecutor).")
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
                var accumulatedConstraints = Set(sessionState.negativeConstraints)

                do {
                    logger.info("Self-reflection capability initiated (maxTrials: \(self.config.maxTrials)).")

                    let spyModel = APISpyModel(inner: model)
                    let executionTrace = input.traceContext
                    let reflectionEvaluator = ReflectionEvaluator()
                    var reflexionMemory = ReflexionMemoryState()

                    // --- Start Episode ---
                    sessionState.episodes.append(MemoryEpisode(primaryGoal: input.userInput, status: "ACTIVE"))
                    sessionState.workingMemory.removeValue(forKey: "current_focus")
                    await SessionGraphStore.shared.updateActiveState(conversationID: input.conversationID, state: sessionState)

                    var bestOutput: String = ""
                    var bestTrial: Int = 0

                    // =====================================================================
                    // OUTER LOOP: TRIALS
                    // =====================================================================

                    for trial in 1...self.config.maxTrials {
                        try Task.checkCancellation()

                        let trialSpan = executionTrace.newSpan()
                        onTraceUpdate(AgentTraceLog(
                            traceID: trialSpan.traceID,
                            spanID: trialSpan.spanID,
                            parentSpanID: trialSpan.parentSpanID,
                            stepNumber: trial,
                            state: .thinking(.reasoning),
                            content: "Starting trial \(trial)/\(self.config.maxTrials)"
                        ))

                        if trial > 1 {
                            continuation.yield(.thought("Starting trial \(trial)/\(self.config.maxTrials) with reflection feedback..."))
                        }

                        // Build trial-scoped input with accumulated critique
                        let trialInstructions: String
                        if reflexionMemory.currentTrial > 1 {
                            let reflectionContext = reflexionMemory.compileForPrompt()
                            trialInstructions = [input.instructions, reflectionContext]
                                .compactMap { $0 }
                                .joined(separator: "\n\n")
                        } else {
                            trialInstructions = input.instructions ?? ""
                        }

                        // Seed working memory with the prior trial's output so the
                        // next trial doesn't re-discover what was already found.
                        // Combined with the critique in instructions, the model gets
                        // both "what went wrong" and "what was already discovered".
                        var seededMemory = input.workingMemory
                        if trial > 1 && !bestOutput.isEmpty {
                            seededMemory.recordObservation(
                                stepId: 0,
                                toolCallId: "trial_\(trial - 1)",
                                toolName: "prior_trial",
                                result: "[Trial \(trial - 1) output]: \(bestOutput)",
                                artifacts: []
                            )
                            logger.info("Seeded trial \(trial) working memory with trial \(trial - 1) output (\(bestOutput.count) chars).")
                        }

                        let trialInput = AgentInput(
                            userInput: input.userInput,
                            chatHistory: input.chatHistory,
                            conversationID: input.conversationID,
                            tools: input.tools,
                            longTermMemory: input.longTermMemory,
                            activeState: SessionGraph(
                                sessionID: sessionState.sessionID,
                                episodes: sessionState.episodes,
                                negativeConstraints: Array(accumulatedConstraints),
                                workingMemory: sessionState.workingMemory
                            ),
                            recentHistory: input.recentHistory,
                            generatorStrategy: input.generatorStrategy,
                            workingMemory: seededMemory,
                            rateLimitKey: input.rateLimitKey,
                            rateLimitCategory: input.rateLimitCategory,
                            instructions: trialInstructions.isEmpty ? nil : trialInstructions,
                            skillManifests: input.skillManifests,
                            skillFolderPath: input.skillFolderPath,
                            retryPolicy: input.retryPolicy,
                            errorRecovery: input.errorRecovery,
                            responseSynthesisEnabled: input.responseSynthesisEnabled,
                            nativeHistoryTurns: input.nativeHistoryTurns,
                            suppressEpisodeManagement: true,
                            traceContext: trialSpan
                        )

                        // Delegate to inner executor for this trial
                        let stream = innerExecutor.execute(model: model, input: trialInput, onTraceUpdate: onTraceUpdate)

                        var trialOutput = ""
                        var trialSummary = ExecutionSummary(originalGoal: input.userInput)

                        do {
                            for try await event in stream {
                                switch event {
                                case .content(let text):
                                    trialOutput += text
                                case .thought(let thought, _, _):
                                    continuation.yield(.thought("[Trial \(trial)] \(thought)"))
                                case .toolCall(let name, let params, _):
                                    // [G11] Forward tool invocation events so UI shows tool activity during trials.
                                    continuation.yield(.toolCall(name: name, params: params))
                                case .toolOutput(let output, _):
                                    // [G1] Capture tool results so ReflectionEvaluator has full context.
                                    trialSummary.record(
                                        toolCallId: output.id.uuidString,
                                        toolName: output.toolName,
                                        params: output.params,
                                        output: output.output,
                                        isSuccess: output.isSuccess
                                    )
                                    continuation.yield(.toolOutput(output))
                                case .requestConfirmation(let toolName, let params, let operationID, let sourceNodeID):
                                    // [G8] Forward HITL permission requests — user must see these during trials.
                                    continuation.yield(.requestConfirmation(toolName: toolName, params: params, operationID: operationID, sourceNodeID: sourceNodeID))
                                case .requestClarification(let question, let operationID, let sourceNodeID):
                                    // [G8] Forward HITL clarification requests.
                                    continuation.yield(.requestClarification(question: question, operationID: operationID, sourceNodeID: sourceNodeID))
                                case .error(let msg):
                                    continuation.yield(.error(msg))
                                case .artifactProduced(let artifact):
                                    continuation.yield(.artifactProduced(artifact))
                                case .tokenUsage(let usage):
                                    continuation.yield(.tokenUsage(usage))
                                default:
                                    break
                                }
                            }
                            trialSummary.finalAgentThought = trialOutput
                            trialSummary.markComplete()
                        } catch is CancellationError {
                            throw CancellationError()
                        } catch {
                            // [G10] Trial-level error recovery: log failure, mark summary,
                            // and continue to next trial instead of aborting the entire loop.
                            logger.error("Trial \(trial) stream error: \(error.localizedDescription)")
                            continuation.yield(.thought("[Trial \(trial)] Error: \(error.localizedDescription)"))
                            trialSummary.finalAgentThought = trialOutput
                            trialSummary.markComplete(failureReason: error.localizedDescription)
                        }

                        bestOutput = trialOutput
                        bestTrial = trial

                        // =============================================================
                        // REFLECTION PHASE
                        // =============================================================

                        // Skip reflection on the last trial
                        guard trial < self.config.maxTrials else { break }

                        continuation.yield(.thought("Reflecting on trial \(trial) outcome..."))

                        await GlobalRateLimiter.shared.wait(forKey: input.rateLimitKey, category: input.rateLimitCategory)
                        try Task.checkCancellation()  // [G7] Catch cancellation before reflection LLM call

                        let reflection = try await reflectionEvaluator.evaluate(
                            summary: trialSummary,
                            originalGoal: input.userInput,
                            model: spyModel,
                            trial: trial
                        )

                        if reflection.isAcceptable {
                            logger.info("Trial \(trial) accepted by reflection evaluator.")
                            continuation.yield(.thought("Reflection: Trial \(trial) outcome is acceptable."))
                            break
                        }

                        // Not acceptable -- prepare for next trial
                        logger.info("Trial \(trial) rejected. Critique: \(reflection.critique)")
                        continuation.yield(.thought("Reflection: \(reflection.critique)"))

                        reflexionMemory.addReflection(
                            trial: trial,
                            critique: reflection.critique,
                            suggestedRevisions: reflection.suggestedRevisions
                        )
                        reflexionMemory.startNewTrial()

                        accumulatedConstraints.insert("Trial \(trial) failed: \(reflection.critique)")

                        // [G6] Backpressure before starting the next trial to avoid 429s
                        await GlobalRateLimiter.shared.wait(forKey: input.rateLimitKey, category: input.rateLimitCategory)

                    } // End trial loop

                    // =====================================================================
                    // FINAL OUTPUT
                    // =====================================================================

                    let exitStatus = bestOutput.isEmpty ? "FAILED" : "COMPLETED"
                    sessionState.closeActiveEpisode(status: exitStatus, outcome: bestOutput)
                    await SessionGraphStore.shared.updateActiveState(conversationID: input.conversationID, state: sessionState)

                    onTraceUpdate(AgentTraceLog(
                        traceID: executionTrace.traceID,
                        spanID: executionTrace.newSpan().spanID,
                        parentSpanID: executionTrace.parentSpanID,
                        stepNumber: bestTrial,
                        state: .thinking(.finalizing),
                        content: "Self-reflection complete after \(bestTrial) trial(s)."
                    ))

                    continuation.yield(.content(bestOutput))
                    continuation.finish()

                } catch is CancellationError {
                    logger.notice("Self-reflection cancelled.")
                    await ExecutionSuspensionService.shared.cancel(for: input.conversationID)
                    sessionState.cancelActiveEpisode()
                    await SessionGraphStore.shared.updateActiveState(conversationID: input.conversationID, state: sessionState)
                    continuation.yield(.thought("Cancelled by user."))
                    continuation.finish()
                } catch {
                    logger.error("Self-reflection fatal error: \(error.localizedDescription)")
                    await ExecutionSuspensionService.shared.cancel(for: input.conversationID)
                    continuation.finish(throwing: error)
                }
            }

            continuation.onTermination = { @Sendable _ in task.cancel() }
        }
    }
}
