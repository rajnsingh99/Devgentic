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

    nonisolated let architecture: AgentArchitecture = .reflexion
    nonisolated private let innerExecutor: any Executor
    nonisolated private let config: SelfReflectionConfig

    init(innerExecutor: any Executor, config: SelfReflectionConfig) {
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
                    SessionGraphStore.shared.updateActiveState(conversationID: input.conversationID, state: sessionState)

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
                            workingMemory: input.workingMemory,
                            rateLimitCategory: input.rateLimitCategory,
                            instructions: trialInstructions.isEmpty ? nil : trialInstructions,
                            retryPolicy: input.retryPolicy,
                            errorRecovery: input.errorRecovery,
                            traceContext: trialSpan
                        )

                        // Delegate to inner executor for this trial
                        let stream = innerExecutor.execute(model: model, input: trialInput, onTraceUpdate: onTraceUpdate)

                        var trialOutput = ""
                        var trialSummary = ExecutionSummary(originalGoal: input.userInput)

                        for try await event in stream {
                            switch event {
                            case .content(let text):
                                trialOutput += text
                            case .thought(let thought):
                                continuation.yield(.thought("[Trial \(trial)] \(thought)"))
                            case .artifactProduced(let artifact):
                                continuation.yield(.artifactProduced(artifact))
                            default:
                                break
                            }
                        }

                        trialSummary.finalAgentThought = trialOutput
                        trialSummary.markComplete()

                        bestOutput = trialOutput
                        bestTrial = trial

                        // =============================================================
                        // REFLECTION PHASE
                        // =============================================================

                        // Skip reflection on the last trial
                        guard trial < self.config.maxTrials else { break }

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

                    } // End trial loop

                    // =====================================================================
                    // FINAL OUTPUT
                    // =====================================================================

                    let exitStatus = bestOutput.isEmpty ? "FAILED" : "COMPLETED"
                    sessionState.closeActiveEpisode(status: exitStatus, outcome: bestOutput)
                    SessionGraphStore.shared.updateActiveState(conversationID: input.conversationID, state: sessionState)

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
                    SessionGraphStore.shared.updateActiveState(conversationID: input.conversationID, state: sessionState)
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
