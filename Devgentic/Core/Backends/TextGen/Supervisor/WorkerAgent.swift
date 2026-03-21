//
//  WorkerAgent.swift
//  Devgentic
//
//  A lightweight inner executor that runs a mini ReAct loop for a single worker task.
//  NOT a full Executor — this is a struct with a single `execute` method called by SupervisorExecutor.
//

import Foundation
import OSLog

private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "com.devgentic.app", category: "WorkerAgent")

struct WorkerAgent: Sendable {

    let maxIterations: Int

    init(maxIterations: Int = 8) {
        self.maxIterations = maxIterations
    }

    func execute(
        task: WorkerTask,
        model: any LLMProvider,
        generator: any CognitiveGenerator,
        input: AgentInput,
        workerIndex: Int,
        totalWorkers: Int,
        continuation: AsyncThrowingStream<AgentStreamEvent, Error>.Continuation,
        onTraceUpdate: @escaping @Sendable (AgentTraceLog) -> Void
    ) async throws -> WorkerResult {

        logger.info("Worker [\(task.workerRole)] starting: \(task.instruction)")

        let executionTrace = input.traceContext
        var workerMemory = HighContextLinearMemory()
        var circuitBreaker = CognitiveCircuitBreaker()
        var retryStrategy = LLMRetryStrategy()
        let toolMediator = ToolExecutionMediator()
        let terminationEvaluator = EpisodeTerminationEvaluator()

        let envFacts = EnvironmentFacts(
            osVersion: ProcessInfo.processInfo.operatingSystemVersionString,
            shellType: "Zsh (Non-Interactive Mode)",
            userName: NSUserName(),
            currentDate: Date().formatted(date: .numeric, time: .shortened)
        )

        var toolsUsed: [String] = []
        var accumulatedOutput = ""
        var iteration = 0

        workerLoop: while iteration < maxIterations {
            try Task.checkCancellation()
            iteration += 1

            await GlobalRateLimiter.shared.wait(for: input.rateLimitCategory)

            let iterationSpan = executionTrace.newSpan()

            let context = SemanticContext(
                instructions: "You are a specialized \(task.workerRole) worker. Focus on completing your assigned task.",
                environmentFacts: envFacts,
                longTermMemory: input.longTermMemory,
                compressedStateGraph: "",
                recentHistory: nil,
                originalQuery: task.instruction,
                currentIteration: iteration,
                compiledScratchpad: workerMemory.compileForPrompt(),
                latestClarification: nil,
                negativeConstraints: [],
                hallucinatedTools: circuitBreaker.hallucinatedTools,
                availableTools: task.assignedTools
            )

            // Generate step
            let step: ModernCognitiveStep
            do {
                step = try await generator.generateCognitiveStep(
                    model: model,
                    context: context,
                    iteration: iteration
                )
                retryStrategy.resetParseFailures()
            } catch {
                let action = retryStrategy.handleError(error)
                switch action {
                case .throttle(let seconds, let message):
                    await GlobalRateLimiter.shared.drainAndPenalize(category: input.rateLimitCategory, penaltySeconds: seconds)
                    continuation.yield(.thought("[\(task.workerRole)] \(message)"))
                    try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
                    iteration -= 1
                    continue workerLoop
                case .networkRetry(let message):
                    continuation.yield(.thought("[\(task.workerRole)] \(message)"))
                    iteration -= 1
                    continue workerLoop
                case .parseRetry(let systemAlert, _, _):
                    workerMemory.recordSystemAlert(msg: systemAlert)
                    continue workerLoop
                case .modelReload(let message):
                    continuation.yield(.thought("[\(task.workerRole)] \(message)"))
                    let reloaded = await MLXService.shared.reloadCurrentModel()
                    if !reloaded {
                        return WorkerResult(
                            workerId: task.id,
                            workerRole: task.workerRole,
                            output: "Worker aborted: Model unloaded and could not be reloaded.",
                            isSuccess: false,
                            toolsUsed: toolsUsed
                        )
                    }
                    iteration -= 1
                    continue workerLoop
                case .abort(let reason):
                    return WorkerResult(
                        workerId: task.id,
                        workerRole: task.workerRole,
                        output: "Worker aborted: \(reason)",
                        isSuccess: false,
                        toolsUsed: toolsUsed
                    )
                }
            }

            // Yield worker thoughts (prefixed with role)
            if !step.reasoning.isEmpty {
                continuation.yield(.thought("[\(task.workerRole)] \(step.reasoning)"))
            }

            // Termination
            let termStatus = terminationEvaluator.evaluate(step: step, currentIteration: iteration, maxIterations: maxIterations)
            switch termStatus {
            case .completed(let finalThought):
                accumulatedOutput += finalThought
                break workerLoop
            case .maxIterationsReached:
                break
            case .suspectedFormatFailure:
                workerMemory.recordSystemAlert(msg: "Format failure in worker.")
                continue workerLoop
            case .proceed:
                break
            }

            if step.toolCalls.isEmpty {
                accumulatedOutput += step.reasoning
                break workerLoop
            }

            // Execute tools
            let observations = try await executeToolCalls(
                toolCalls: step.toolCalls,
                availableTools: task.assignedTools,
                conversationID: input.conversationID,
                currentIteration: iteration,
                iterationSpan: iterationSpan,
                toolMediator: toolMediator,
                continuation: continuation,
                onTraceUpdate: onTraceUpdate
            )

            for obs in observations {
                workerMemory.recordObservation(stepId: iteration, toolCallId: obs.toolCallId, toolName: obs.toolName, result: obs.result)
                toolsUsed.append(obs.toolName)
                accumulatedOutput += "\n[\(obs.toolName)]: \(obs.result)"

                let resultAction = circuitBreaker.recordToolResult(isSuccess: obs.isSuccess)
                if case .abort(let reason) = resultAction {
                    return WorkerResult(
                        workerId: task.id,
                        workerRole: task.workerRole,
                        output: "Worker aborted: \(reason)",
                        isSuccess: false,
                        toolsUsed: toolsUsed
                    )
                }
                if !obs.isSuccess {
                    circuitBreaker.recordHallucination(obs.toolName)
                }
            }

            circuitBreaker.resetCountersOnSuccess()

        } // End worker loop

        let isSuccess = !accumulatedOutput.isEmpty
        logger.info("Worker [\(task.workerRole)] completed. Success: \(isSuccess)")

        return WorkerResult(
            workerId: task.id,
            workerRole: task.workerRole,
            output: accumulatedOutput.isEmpty ? "Worker completed without producing output." : accumulatedOutput,
            isSuccess: isSuccess,
            toolsUsed: Array(Set(toolsUsed))
        )
    }
}
