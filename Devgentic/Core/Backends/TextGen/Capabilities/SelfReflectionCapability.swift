// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
//
//  SelfReflectionCapability.swift
//  Devgentic
//
//  Created by Raj Singh.
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
        // Seeds prior trial output into `workingMemory`, so the inner executor must consume `AgentInput.workingMemory`:
        // `ReActAgentExecutor` directly, or a `PlanningExecutorWrapper` when both capabilities stack.
        assert(innerExecutor is ReActAgentExecutor || innerExecutor is PlanningExecutorWrapper,
               "SelfReflectionCapability requires an inner executor that consumes workingMemory (ReActAgentExecutor or PlanningExecutorWrapper).")
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

                // Whether any answer content reached the UI; the cancel handler emits a placeholder only when the bubble would be empty.
                var didEmitContent = false

                do {
                    logger.info("Self-reflection capability initiated (maxTrials: \(self.config.maxTrials)).")

                    // The evaluator's LLM calls record as `llmCall` spans in the capability's own scope;
                    // trial executors build their own spy.
                    let spyModel = APISpyModel(inner: model, spanScope: LLMSpanScope(input.traceContext))
                    let executionTrace = input.traceContext
                    let reflectionEvaluator = ReflectionEvaluator()
                    var reflexionMemory = ReflexionMemoryState()

                    // One interaction memory across all trials: a question answered in one trial replays for an identical re-ask
                    // in the next. A stacked inner Planning wrapper inherits it through the same field.
                    let interactionMemory = input.interactionMemory ?? RunInteractionMemory()

                    // --- Start Episode ---
                    sessionState.episodes.append(MemoryEpisode(primaryGoal: input.userInput, status: .active))
                    sessionState.workingMemory.removeValue(forKey: "current_focus")
                    await SessionGraphStore.shared.updateActiveState(conversationID: input.conversationID, state: sessionState)

                    var bestOutput: String = ""
                    var bestTrial: Int = 0    // trial `bestOutput` came from (what ships)
                    var trialsRun: Int = 0    // total trials executed (for honest trace count)

                    trialLoop: for trial in 1...self.config.maxTrials {
                        try Task.checkCancellation()

                        let trialSpan = executionTrace.newSpan()
                        // Persists the trial span so inner iteration spans attach to a real parent row.
                        // A RETRY verdict still counts as a completed trial.
                        await TraceRecorder.shared.beginSpan(context: trialSpan, name: "trial_\(trial)", kind: .subtask)
                        var trialSucceeded = false
                        defer {
                            let endedAt = Date() // real end, captured before the hop (earliest-wins)
                            let status: SpanStatus = trialSucceeded ? .completed : .error
                            Task { await TraceRecorder.shared.endSpan(spanID: trialSpan.spanID, status: status, at: endedAt) }
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

                        // Seeds working memory with the prior trial's output so the next trial does not re-discover what was found.
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

                        // Trial-scoped input by copy-derivation: every field not overridden is inherited from the parent run.
                        var trialInput = input
                        trialInput.activeState = SessionGraph(
                            sessionID: sessionState.sessionID,
                            episodes: sessionState.episodes,
                            negativeConstraints: Array(accumulatedConstraints),
                            workingMemory: sessionState.workingMemory
                        )
                        trialInput.workingMemory = seededMemory
                        trialInput.interactionMemory = interactionMemory
                        trialInput.instructions = trialInstructions.isEmpty ? nil : trialInstructions
                        trialInput.suppressEpisodeManagement = true
                        // Trial output is intermediate for the evaluator, which judges tool results, so per-trial synthesis is skipped.
                        trialInput.suppressLLMSynthesis = true
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
                                case .thought(let thought, let id, _):
                                    // Forwarded verbatim; the stream bridge routes trial events into the reflection card's attempt timeline.
                                    continuation.yield(.thought(thought, id: id))
                                case .reasoning(let text, let id, _):
                                    continuation.yield(.reasoning(text, id: id))
                                // Why: dropping `requestPlanReview` deadlocks the run, which suspends waiting for a banner the UI never saw
                                // Stacked capabilities: a Planning wrapper's plan and subtask events must pass through.
                                case .planGenerated, .planApproved, .requestPlanReview,
                                     .subtaskStarted, .subtaskCompleted:
                                    continuation.yield(event)
                                case .toolCall(let name, let params, _, let stepId):
                                    // [G11] Forward tool invocation events so UI shows tool activity during trials.
                                    continuation.yield(.toolCall(name: name, params: params, stepId: stepId))
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
                                case .requestConfirmation(let toolName, let params, let operationID, let sourceNodeID, let sourceNodeName):
                                    // [G8] Forward HITL permission requests — user must see these during trials.
                                    continuation.yield(.requestConfirmation(toolName: toolName, params: params, operationID: operationID, sourceNodeID: sourceNodeID, sourceNodeName: sourceNodeName))
                                case .requestClarification(let question, let operationID, let sourceNodeID, let options, let multiline, let sourceNodeName):
                                    // [G8] Forward HITL clarification requests.
                                    continuation.yield(.requestClarification(question: question, operationID: operationID, sourceNodeID: sourceNodeID, options: options, multiline: multiline, sourceNodeName: sourceNodeName))
                                case .error(let msg):
                                    continuation.yield(.error(msg))
                                case .warning(let cat, let msg, let relatedPath, _):
                                    // [G8] Forward warnings so UI surfaces memory-pressure / retry / parse-failure
                                    // signals during trials. Unprefixed — attribution is structural (reflection card).
                                    continuation.yield(.warning(category: cat, message: msg, relatedPath: relatedPath))
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
                            // A trial's stream error is logged and marked, and the loop continues with the next trial.
                            // A structured warning lets the UI distinguish it from narrative thoughts.
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
                        // Keeps the most recent non-empty output, and a failed trial never overwrites one that succeeded.
                        // A trial that throws mid-stream can leave `trialOutput` empty or partial.
                        if !trialOutput.isEmpty && (trialSucceeded || bestOutput.isEmpty) {
                            bestOutput = trialOutput
                            bestTrial = trial
                        }

                        // Skip reflection on the last trial
                        guard trial < self.config.maxTrials else { break trialLoop }

                        continuation.yield(.reflectionEvaluating(trial: trial))

                        await GlobalRateLimiter.shared.waitForCapacity(forKey: input.rateLimitKey, category: input.rateLimitCategory)
                        try Task.checkCancellation()  // [G7] Catch cancellation before reflection LLM call

                        let (evaluation, reflectionUsage) = try await reflectionEvaluator.evaluate(
                            summary: trialSummary,
                            originalGoal: input.userInput,
                            model: spyModel,
                            trial: trial
                        )
                        continuation.yield(.tokenUsage(reflectionUsage))

                        // Why: re-running the trial off an infrastructure fault repeats tool side effects and feeds a fabricated critique
                        // A failed evaluation LLM call is not a verdict: keep the trial's answer and stop reflecting.
                        guard case .verdict(let reflection) = evaluation else {
                            if case .inconclusive(let reason) = evaluation {
                                logger.warning("[REFLECTION] Trial \(trial) evaluation was INCONCLUSIVE (\(reason)). CONSEQUENCE: the trial's answer is kept without a verdict; remaining trials are skipped rather than spent re-running work nothing judged deficient.")
                                continuation.yield(.warning(
                                    category: .midRunError,
                                    message: "Self-reflection could not evaluate this answer (\(reason)) — keeping it as-is."
                                ))
                            }
                            break trialLoop
                        }

                        if reflection.isAcceptable {
                            logger.info("Trial \(trial) accepted by reflection evaluator.")
                            continuation.yield(.reflectionAccepted(trial: trial))
                            break trialLoop
                        }

                        // Not acceptable -- prepare for next trial. The full critique travels
                        // on the structured event; the reflection card renders it verbatim.
                        logger.info("Trial \(trial) rejected. Critique: \(reflection.critique)")
                        continuation.yield(.reflectionRetrying(trial: trial, critique: reflection.critique))

                        reflexionMemory.addReflection(
                            trial: trial,
                            critique: reflection.critique,
                            suggestedRevisions: reflection.suggestedRevisions
                        )
                        reflexionMemory.startNewTrial()

                        accumulatedConstraints.insert("Trial \(trial) failed: \(reflection.critique)")

                        // [G6] Backpressure before starting the next trial to avoid 429s
                        await GlobalRateLimiter.shared.waitForCapacity(forKey: input.rateLimitKey, category: input.rateLimitCategory)

                    } // End trial loop

                    let terminalOutcome: ExecutionOutcome = bestOutput.isEmpty ? .failed : .completed
                    sessionState.closeActiveEpisode(outcome: terminalOutcome, message: bestOutput)
                    await SessionGraphStore.shared.updateActiveState(conversationID: input.conversationID, state: sessionState)

                    // Why: an event on a never-begun span orphans and fails the foreign key at flush
                    // Anchors to the existing root span; the outcome metadata makes the session summary reflect the reflexion verdict.
                    onTraceUpdate(AgentTraceLog(
                        traceID: executionTrace.traceID,
                        spanID: executionTrace.spanID,
                        parentSpanID: executionTrace.parentSpanID,
                        stepNumber: trialsRun,
                        state: .thinking(.finalizing),
                        content: "Self-reflection complete after \(trialsRun) trial(s).",
                        metadata: ["outcome": terminalOutcome.rawValue]
                    ))

                    continuation.yield(.content(bestOutput))
                    didEmitContent = true
                    // Reuses `terminalOutcome`: an empty best output after all trials means the loop never produced acceptable content.
                    let terminalReason: String? = bestOutput.isEmpty
                        ? "All \(self.config.maxTrials) trials rejected by reflection evaluator"
                        : nil
                    continuation.yield(.executionFinished(outcome: terminalOutcome, reason: terminalReason))
                    continuation.finish()

                } catch is CancellationError {
                    logger.notice("Self-reflection cancelled.")
                    // Why: the conversation-wide drain resolves every park, including a sibling node's or a parent's
                    // Node-scoped when this run is a workflow node; chat and code runs keep the conversation-wide sweep.
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
                    // Mirrors `ReActAgentExecutor`'s cancel placeholder so a cancelled run leaves no empty bubble.
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
                    // Why: the conversation-wide drain resolves every park, including a sibling node's or a parent's
                    // Node-scoped when this run is a workflow node; chat and code runs keep the conversation-wide sweep.
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
}
