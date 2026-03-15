//
//  SupervisorExecutor.swift
//  Devgentic
//
//  Supervisor architecture: a "Supervisor" LLM decomposes the task into worker assignments,
//  each worker runs a mini ReAct loop, and the supervisor aggregates results.
//  Supports up to 2 routing rounds for gap-filling.
//

import Foundation
import OSLog

private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "com.devgentic.app", category: "SupervisorExecutor")
private let logState = Logger(subsystem: Bundle.main.bundleIdentifier ?? "com.devgentic.app", category: "SupervisorState")

actor SupervisorExecutor: Executor {

    // MARK: - Properties

    nonisolated let architecture: AgentArchitecture = .supervisor
    nonisolated private let maxRoutingRounds: Int
    nonisolated private let maxWorkerIterations: Int

    // MARK: - Initialization

    init(maxRoutingRounds: Int = 2, maxWorkerIterations: Int = 8) {
        self.maxRoutingRounds = maxRoutingRounds
        self.maxWorkerIterations = maxWorkerIterations
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
                    logger.info("Supervisor execution initiated.")

                    let spyModel = APISpyModel(inner: model)
                    let executionTrace = input.traceContext
                    var executionSummary = ExecutionSummary(originalGoal: input.userInput)
                    var supervisorMemory = SupervisorMemoryStrategy()
                    let routingStrategy = SupervisorRoutingStrategy()
                    let workerAgent = WorkerAgent(maxIterations: self.maxWorkerIterations)

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

                    var allWorkerResults: [WorkerResult] = []
                    var globalStep = 0

                    // =====================================================================
                    // ROUTING ROUNDS
                    // =====================================================================

                    for round in 1...self.maxRoutingRounds {
                        try Task.checkCancellation()

                        // --- ROUTING PHASE ---
                        let routingSpan = executionTrace.newSpan()
                        supervisorMemory.setPhase("routing")

                        onTraceUpdate(AgentTraceLog(
                            traceID: routingSpan.traceID,
                            spanID: routingSpan.spanID,
                            parentSpanID: routingSpan.parentSpanID,
                            stepNumber: globalStep,
                            state: .thinking(.planning),
                            content: round == 1 ? "Routing task to workers..." : "Re-routing for gap-filling (round \(round))..."
                        ))

                        let routingQuery: String
                        if round == 1 {
                            routingQuery = input.userInput
                        } else {
                            // Build a re-routing query that includes previous worker results
                            let previousResults = allWorkerResults.map { "[\($0.workerRole)]: \($0.output.prefix(200))" }.joined(separator: "\n")
                            routingQuery = """
                            Original request: \(input.userInput)

                            Previous worker results:
                            \(previousResults)

                            Identify any gaps in the above results and create additional workers to fill them.
                            If the results are sufficient, create a single worker with role "none" and instruction "No additional work needed."
                            """
                        }

                        await GlobalRateLimiter.shared.wait(for: input.rateLimitCategory)

                        let routingContext = SemanticContext(
                            instructions: input.instructions,
                            environmentFacts: envFacts,
                            longTermMemory: input.longTermMemory,
                            compressedStateGraph: sessionState.compressWithPointers(windowSize: 5),
                            recentHistory: input.recentHistory,
                            originalQuery: routingQuery,
                            currentIteration: round,
                            compiledScratchpad: supervisorMemory.compileForPrompt(),
                            latestClarification: nil,
                            negativeConstraints: Set(sessionState.negativeConstraints),
                            hallucinatedTools: [],
                            availableTools: input.tools
                        )

                        let workerTasks: [WorkerTask]
                        do {
                            workerTasks = try await routingStrategy.route(
                                query: routingQuery,
                                availableTools: input.tools,
                                model: spyModel,
                                context: routingContext
                            )
                        } catch {
                            logger.warning("Routing failed: \(error.localizedDescription). Using single worker.")
                            break
                        }

                        // Check if re-routing returned "none" (no additional work)
                        if round > 1 && workerTasks.count == 1 && workerTasks[0].workerRole == "none" {
                            logger.info("Re-routing determined no additional workers needed.")
                            break
                        }

                        continuation.yield(.thought("Delegating to \(workerTasks.count) worker(s): \(workerTasks.map(\.workerRole).joined(separator: ", "))"))

                        // --- WORKER EXECUTION PHASE ---
                        supervisorMemory.setPhase("executing")

                        for (workerIndex, workerTask) in workerTasks.enumerated() {
                            try Task.checkCancellation()
                            globalStep += 1

                            let workerSpan = executionTrace.newSpan()
                            onTraceUpdate(AgentTraceLog(
                                traceID: workerSpan.traceID,
                                spanID: workerSpan.spanID,
                                parentSpanID: workerSpan.parentSpanID,
                                stepNumber: globalStep,
                                state: .acting(.subtask(current: workerIndex + 1, total: workerTasks.count)),
                                content: "Worker [\(workerTask.workerRole)]: \(workerTask.instruction)"
                            ))

                            continuation.yield(.thought("Worker \(workerIndex + 1)/\(workerTasks.count) [\(workerTask.workerRole)]: Starting..."))

                            let result = try await workerAgent.execute(
                                task: workerTask,
                                model: spyModel,
                                generator: input.generatorStrategy,
                                input: input,
                                workerIndex: workerIndex,
                                totalWorkers: workerTasks.count,
                                continuation: continuation,
                                onTraceUpdate: onTraceUpdate
                            )

                            allWorkerResults.append(result)
                            supervisorMemory.recordWorkerResult(
                                role: result.workerRole,
                                output: result.output,
                                isSuccess: result.isSuccess
                            )

                            // Record to execution summary
                            executionSummary.record(
                                toolName: "worker_\(result.workerRole)",
                                params: workerTask.instruction,
                                output: result.output,
                                isSuccess: result.isSuccess
                            )

                            let status = result.isSuccess ? "completed successfully" : "failed"
                            continuation.yield(.thought("Worker [\(result.workerRole)] \(status)."))
                        }

                        // Only do re-routing if round 1 and not all workers succeeded
                        let allSucceeded = workerTasks.indices.allSatisfy { i in
                            guard i < allWorkerResults.count else { return false }
                            return allWorkerResults[allWorkerResults.count - workerTasks.count + i].isSuccess
                        }

                        if allSucceeded || round >= self.maxRoutingRounds {
                            break
                        }

                    } // End routing rounds

                    // =====================================================================
                    // AGGREGATION PHASE
                    // =====================================================================

                    supervisorMemory.setPhase("aggregating")

                    let aggregationSpan = executionTrace.newSpan()
                    onTraceUpdate(AgentTraceLog(
                        traceID: aggregationSpan.traceID,
                        spanID: aggregationSpan.spanID,
                        parentSpanID: aggregationSpan.parentSpanID,
                        stepNumber: globalStep + 1,
                        state: .thinking(.finalizing),
                        content: "Aggregating worker results..."
                    ))

                    continuation.yield(.thought("Aggregating results from \(allWorkerResults.count) worker(s)..."))

                    await GlobalRateLimiter.shared.wait(for: input.rateLimitCategory)

                    // Synthesize via LLM aggregation
                    let workerOutputsSummary = allWorkerResults.enumerated().map { (i, result) in
                        let status = result.isSuccess ? "Success" : "Failed"
                        let truncated = result.output.count > 500 ? String(result.output.prefix(500)) + "..." : result.output
                        return "Worker \(i + 1) [\(result.workerRole)] (\(status)):\n\(truncated)"
                    }.joined(separator: "\n\n")

                    let aggregationMessages: [[String: String]] = [
                        ["role": "system", "content": """
                        You are synthesizing results from multiple specialized workers into a single coherent response.
                        Combine the relevant information from all workers into a clear, comprehensive answer.
                        Do NOT mention the workers or internal architecture — just answer the user's question naturally.
                        """],
                        ["role": "user", "content": """
                        Original request: \(input.userInput)

                        Worker results:
                        \(workerOutputsSummary)

                        Provide a unified response to the user's original request.
                        """]
                    ]

                    let aggregatedResponse: String
                    do {
                        aggregatedResponse = try await spyModel.generate(messages: aggregationMessages, tools: nil, responseSchema: nil)
                    } catch {
                        logger.warning("Aggregation LLM call failed. Using concatenated worker outputs.")
                        aggregatedResponse = allWorkerResults
                            .filter(\.isSuccess)
                            .map(\.output)
                            .joined(separator: "\n\n")
                    }

                    executionSummary.finalAgentThought = aggregatedResponse
                    executionSummary.markComplete()

                    let allSucceeded = allWorkerResults.allSatisfy(\.isSuccess)
                    let exitStatus = allSucceeded ? "COMPLETED" : "FAILED"

                    sessionState.closeActiveEpisode(status: exitStatus, outcome: aggregatedResponse)
                    SessionGraphStore.shared.updateActiveState(conversationID: input.conversationID, state: sessionState)

                    continuation.yield(.content(aggregatedResponse))
                    continuation.finish()

                } catch is CancellationError {
                    logger.notice("Supervisor cancelled.")
                    await ExecutionSuspensionService.shared.cancel(for: input.conversationID)
                    sessionState.cancelActiveEpisode()
                    SessionGraphStore.shared.updateActiveState(conversationID: input.conversationID, state: sessionState)
                    continuation.finish()
                } catch {
                    logger.error("Supervisor fatal error: \(error.localizedDescription)")
                    await ExecutionSuspensionService.shared.cancel(for: input.conversationID)
                    continuation.finish(throwing: error)
                }
            }

            continuation.onTermination = { @Sendable _ in task.cancel() }
        }
    }
}
