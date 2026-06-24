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

private let logger = DGLogger(category: "SelfReflectionCapability")

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

                // #23: whether any answer content reached the UI. The cancel handler emits a
                // placeholder only when the bubble would otherwise be empty (defensive — today
                // trial content is accumulated, not forwarded, and the final answer is yielded
                // only after the loop, immediately before finishing).
                var didEmitContent = false

                do {
                    logger.info("Self-reflection capability initiated (maxTrials: \(self.config.maxTrials)).")

                    let spyModel = APISpyModel(inner: model)
                    let executionTrace = input.traceContext
                    let reflectionEvaluator = ReflectionEvaluator()
                    var reflexionMemory = ReflexionMemoryState()

                    // --- Start Episode ---
                    sessionState.episodes.append(MemoryEpisode(primaryGoal: input.userInput, status: .active))
                    sessionState.workingMemory.removeValue(forKey: "current_focus")
                    await SessionGraphStore.shared.updateActiveState(conversationID: input.conversationID, state: sessionState)

                    var bestOutput: String = ""
                    var bestTrial: Int = 0    // trial `bestOutput` came from (what ships)
                    var trialsRun: Int = 0    // total trials executed (for honest trace count)

                    // =====================================================================
                    // OUTER LOOP: TRIALS
                    // =====================================================================

                    for trial in 1...self.config.maxTrials {
                        try Task.checkCancellation()

                        let trialSpan = executionTrace.newSpan()
                        // Persist the trial span so the inner executor's iteration spans
                        // attach to a real parent row instead of orphaning (Gap #10). The
                        // success flag keeps the status honest when the trial's stream
                        // throws or is cancelled (audit #9); a RETRY verdict still counts
                        // as a completed trial — the trial ran, the evaluator just wasn't
                        // satisfied.
                        await TraceRecorder.shared.beginSpan(context: trialSpan, name: "trial_\(trial)", kind: .subtask)
                        var trialSucceeded = false
                        defer {
                            let status: SpanStatus = trialSucceeded ? .completed : .error
                            Task { await TraceRecorder.shared.endSpan(spanID: trialSpan.spanID, status: status) }
                        }
                        onTraceUpdate(AgentTraceLog(
                            traceID: trialSpan.traceID,
                            spanID: trialSpan.spanID,
                            parentSpanID: trialSpan.parentSpanID,
                            stepNumber: trial,
                            state: .thinking(.reasoning),
                            content: "Starting trial \(trial)/\(self.config.maxTrials)"
                        ))

                        continuation.yield(.reflectionTrialStarted(trial: trial, maxTrials: self.config.maxTrials))
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
                        // Seed with the best output so far (which may be from an earlier trial
                        // than trial-1 if the immediately-prior trial failed — #18 A1).
                        if trial > 1 && !bestOutput.isEmpty {
                            seededMemory.recordObservation(
                                stepId: 0,
                                toolCallId: "trial_\(bestTrial)",
                                toolName: "prior_trial",
                                params: "",
                                result: "[Trial \(bestTrial) output]: \(bestOutput)",
                                artifacts: []
                            )
                            logger.info("Seeded trial \(trial) working memory with trial \(bestTrial) output (\(bestOutput.count) chars).")
                        }

                        // Trial-scoped input by copy-derivation (AgentInput contract):
                        // everything not overridden — userPayload images, modelTier,
                        // workflowContext, and any future field — is inherited from the
                        // parent run automatically.
                        var trialInput = input
                        trialInput.activeState = SessionGraph(
                            sessionID: sessionState.sessionID,
                            episodes: sessionState.episodes,
                            negativeConstraints: Array(accumulatedConstraints),
                            workingMemory: sessionState.workingMemory
                        )
                        trialInput.workingMemory = seededMemory
                        trialInput.instructions = trialInstructions.isEmpty ? nil : trialInstructions
                        trialInput.suppressEpisodeManagement = true
                        trialInput.traceContext = trialSpan

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
                                case .toolSucceeded(let output, let durationMs, _):
                                    // [G1] Capture tool results so ReflectionEvaluator has full context.
                                    trialSummary.record(
                                        toolCallId: output.id.uuidString,
                                        toolName: output.toolName,
                                        params: output.params,
                                        output: output.output,
                                        isSuccess: true
                                    )
                                    continuation.yield(.toolSucceeded(output, durationMs: durationMs))
                                case .toolFailed(let output, let category, let suggestion, _):
                                    trialSummary.record(
                                        toolCallId: output.id.uuidString,
                                        toolName: output.toolName,
                                        params: output.params,
                                        output: output.output,
                                        isSuccess: false
                                    )
                                    continuation.yield(.toolFailed(output, category: category, suggestion: suggestion))
                                case .requestConfirmation(let toolName, let params, let operationID, let sourceNodeID):
                                    // [G8] Forward HITL permission requests — user must see these during trials.
                                    continuation.yield(.requestConfirmation(toolName: toolName, params: params, operationID: operationID, sourceNodeID: sourceNodeID))
                                case .requestClarification(let question, let operationID, let sourceNodeID, let options, let multiline):
                                    // [G8] Forward HITL clarification requests.
                                    continuation.yield(.requestClarification(question: question, operationID: operationID, sourceNodeID: sourceNodeID, options: options, multiline: multiline))
                                case .error(let msg):
                                    continuation.yield(.error(msg))
                                case .warning(let cat, let msg, let relatedPath, _):
                                    // [G8] Forward warnings so UI surfaces memory-pressure / retry / parse-failure signals during trials.
                                    continuation.yield(.warning(category: cat, message: "[Trial \(trial)] \(msg)", relatedPath: relatedPath))
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
                            trialSucceeded = true
                        } catch is CancellationError {
                            throw CancellationError()
                        } catch {
                            // [G10] Trial-level error recovery: log failure, mark summary,
                            // and continue to next trial instead of aborting the entire loop.
                            // Structured warning so the UI marks the trial failure distinctly
                            // from narrative thoughts and downstream consumers see a category.
                            logger.error("Trial \(trial) stream error: \(error.localizedDescription)")
                            continuation.yield(.warning(
                                category: .retry,
                                message: "Trial \(trial) failed: \(error.localizedDescription)",
                                relatedPath: "trial_\(trial)"
                            ))
                            trialSummary.finalAgentThought = trialOutput
                            trialSummary.markComplete(failureReason: error.localizedDescription)
                        }

                        trialsRun = trial
                        // #18 (A1): don't let an empty or failed later trial clobber a good
                        // earlier result. Keep the most recent NON-EMPTY output, and never let
                        // a failed trial overwrite one that already succeeded (a trial can throw
                        // mid-stream and leave trialOutput empty/partial — :250-265). True
                        // best-SCORING selection across multiple non-empty trials is A2 (deferred:
                        // needs a numeric score on the evaluator verdict).
                        if !trialOutput.isEmpty && (trialSucceeded || bestOutput.isEmpty) {
                            bestOutput = trialOutput
                            bestTrial = trial
                        }

                        // =============================================================
                        // REFLECTION PHASE
                        // =============================================================

                        // Skip reflection on the last trial
                        guard trial < self.config.maxTrials else { break }

                        continuation.yield(.reflectionEvaluating(trial: trial))
                        continuation.yield(.thought("Reflecting on trial \(trial) outcome..."))

                        await GlobalRateLimiter.shared.wait(forKey: input.rateLimitKey, category: input.rateLimitCategory)
                        try Task.checkCancellation()  // [G7] Catch cancellation before reflection LLM call

                        let (reflection, reflectionUsage) = try await reflectionEvaluator.evaluate(
                            summary: trialSummary,
                            originalGoal: input.userInput,
                            model: spyModel,
                            trial: trial
                        )
                        continuation.yield(.tokenUsage(reflectionUsage))

                        if reflection.isAcceptable {
                            logger.info("Trial \(trial) accepted by reflection evaluator.")
                            continuation.yield(.reflectionAccepted(trial: trial))
                            continuation.yield(.thought("Reflection: Trial \(trial) outcome is acceptable."))
                            break
                        }

                        // Not acceptable -- prepare for next trial
                        logger.info("Trial \(trial) rejected. Critique: \(reflection.critique)")
                        continuation.yield(.reflectionRetrying(trial: trial, critique: reflection.critique))
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

                    let terminalOutcome: ExecutionOutcome = bestOutput.isEmpty ? .failed : .completed
                    sessionState.closeActiveEpisode(outcome: terminalOutcome, message: bestOutput)
                    await SessionGraphStore.shared.updateActiveState(conversationID: input.conversationID, state: sessionState)

                    onTraceUpdate(AgentTraceLog(
                        traceID: executionTrace.traceID,
                        spanID: executionTrace.newSpan().spanID,
                        parentSpanID: executionTrace.parentSpanID,
                        stepNumber: trialsRun,
                        state: .thinking(.finalizing),
                        content: "Self-reflection complete after \(trialsRun) trial(s)."
                    ))

                    continuation.yield(.content(bestOutput))
                    didEmitContent = true
                    // Reuse `terminalOutcome` computed earlier for the episode close —
                    // empty best output after exhausting all trials means the reflection
                    // loop never produced acceptable content; that's `.failed`.
                    let terminalReason: String? = bestOutput.isEmpty
                        ? "All \(self.config.maxTrials) trials rejected by reflection evaluator"
                        : nil
                    continuation.yield(.executionFinished(outcome: terminalOutcome, reason: terminalReason))
                    continuation.finish()

                } catch is CancellationError {
                    logger.notice("Self-reflection cancelled.")
                    await ExecutionSuspensionService.shared.cancel(for: input.conversationID)
                    sessionState.cancelActiveEpisode()
                    await SessionGraphStore.shared.updateActiveState(conversationID: input.conversationID, state: sessionState)
                    continuation.yield(.thought("Cancelled by user."))
                    // #23: mirror ReActAgentExecutor's cancel placeholder so a cancelled
                    // Reflexion run doesn't leave an empty bubble (trial content is accumulated,
                    // not forwarded, so on a wrapper-level cancel nothing has reached the UI).
                    // Guarded against double content.
                    if !didEmitContent {
                        continuation.yield(.content("*Operation stopped by user.*"))
                    }
                    continuation.yield(.executionFinished(outcome: .cancelled, reason: "User stopped the run"))
                    continuation.finish()
                } catch {
                    let classified = error.classify(
                        as: .reflectionExhausted,
                        origin: "SelfReflectionCapability.fatalCatch",
                        message: "Self-reflection fatal error: \(error.localizedDescription)"
                    )
                    logger.error(
                        "Self-reflection fatal error: \(classified.message)",
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
}
