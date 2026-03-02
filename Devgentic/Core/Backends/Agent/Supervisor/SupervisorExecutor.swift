//
//  SupervisorExecutor.swift
//  Devgentic
//
//  Created for Supervisor Architecture.
//  A delegation-based executor that decomposes tasks and assigns them to workers.
//

import Foundation
import OSLog

private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "com.devgentic.app", category: "SupervisorExecutor")

// MARK: - Executor Implementation

/// A delegation-based agent executor implementing the Supervisor paradigm.
/// Phase 1: Decomposes the user's goal into worker assignments via LLM.
/// Phase 2: Executes each worker sequentially, each running a simplified ReAct loop.
/// Phase 3: Aggregates worker results into a unified response.
actor SupervisorExecutor: Executor {

    // MARK: - Properties

    nonisolated let architecture: AgentArchitecture = .supervisor
    nonisolated private let maxWorkers: Int
    nonisolated private let maxIterationsPerWorker: Int

    // MARK: - Initialization

    init(maxWorkers: Int = 5, maxIterationsPerWorker: Int = 10) {
        self.maxWorkers = maxWorkers
        self.maxIterationsPerWorker = maxIterationsPerWorker
    }

    // MARK: - Execution Entry Point

    nonisolated func execute(
        model: any LLMProvider,
        input: AgentInput,
        onTraceUpdate: @escaping @Sendable (AgentTraceLog) -> Void
    ) -> AsyncThrowingStream<AgentStreamEvent, Error> {

        return AsyncThrowingStream<AgentStreamEvent, Error> { continuation in
            let task = Task {

                var stateMutator = DelegationStateMutator(conversationID: input.conversationID)
                var executionSummary = ExecutionSummary(originalGoal: input.userInput)

                do {
                    logger.info("Supervisor Execution Initiated.")

                    let executionTrace = input.traceContext
                    var resultStore = WorkerResultStore()
                    let evaluator = SupervisorEvaluator()

                    // ================================================================
                    // PHASE 1: DECOMPOSITION
                    // ================================================================

                    continuation.yield(.thought("Analyzing request and delegating to workers..."))

                    await GlobalRateLimiter.shared.wait(for: input.rateLimitCategory)

                    let workerAssignments = try await self.decompose(
                        model: model,
                        input: input,
                        continuation: continuation
                    )

                    stateMutator.initializeDelegation(goal: input.userInput, workers: workerAssignments)

                    let delegationSummary = workerAssignments.map { "Worker \($0.workerIndex + 1): \($0.taskDescription) [tools: \($0.assignedTools.joined(separator: ", "))]" }.joined(separator: "\n")
                    continuation.yield(.thought("Delegation plan:\n\(delegationSummary)"))

                    stateMutator.addSupervisorNote("Delegated \(workerAssignments.count) workers.")

                    onTraceUpdate(AgentTraceLog(
                        traceID: executionTrace.traceID,
                        spanID: executionTrace.newSpan().spanID,
                        parentSpanID: executionTrace.parentSpanID,
                        stepNumber: 0,
                        state: .thinking,
                        content: "Delegated to \(workerAssignments.count) workers"
                    ))

                    // ================================================================
                    // PHASE 2: WORKER EXECUTION
                    // ================================================================

                    let workerExecutor = WorkerExecutor(maxIterations: self.maxIterationsPerWorker)

                    workerLoop: for workerIndex in 0..<stateMutator.currentGraph.workers.count {
                        try Task.checkCancellation()

                        let assignment = stateMutator.currentGraph.workers[workerIndex]
                        guard assignment.status == .pending else { continue }

                        // Evaluate progress before each worker
                        let decision = evaluator.evaluateProgress(
                            graph: stateMutator.currentGraph,
                            completedCount: stateMutator.currentGraph.completedCount,
                            totalCount: stateMutator.currentGraph.workers.count
                        )

                        switch decision {
                        case .allComplete:
                            break workerLoop
                        case .abort(let reason):
                            stateMutator.addSupervisorNote("Aborting: \(reason)")
                            executionSummary.markComplete(failureReason: reason)
                            break workerLoop
                        case .delegateNext, .reassign:
                            break // Continue with this worker
                        }

                        stateMutator.markWorkerRunning(workerIndex)
                        continuation.yield(.thought("Worker \(workerIndex + 1): \(assignment.taskDescription)"))

                        let workerSpan = executionTrace.newSpan()
                        onTraceUpdate(AgentTraceLog(
                            traceID: workerSpan.traceID,
                            spanID: workerSpan.spanID,
                            parentSpanID: workerSpan.parentSpanID,
                            stepNumber: workerIndex + 1,
                            state: .acting,
                            content: "Worker \(workerIndex + 1) executing..."
                        ))

                        do {
                            let (result, observations, workerSummary) = try await workerExecutor.execute(
                                model: model,
                                assignment: assignment,
                                allTools: input.tools,
                                generatorStrategy: input.generatorStrategy,
                                rateLimitCategory: input.rateLimitCategory,
                                conversationID: input.conversationID,
                                traceContext: workerSpan,
                                instructions: input.instructions,
                                recentHistory: input.recentHistory,
                                onEvent: { event in
                                    continuation.yield(event)
                                }
                            )

                            let isSuccess = workerSummary.completionStatus != .failed && workerSummary.completionStatus != .stalled

                            if isSuccess {
                                stateMutator.markWorkerCompleted(workerIndex, result: result)
                            } else {
                                stateMutator.markWorkerFailed(workerIndex, reason: result)
                            }

                            resultStore.recordResult(
                                workerIndex: workerIndex,
                                taskDescription: assignment.taskDescription,
                                result: result,
                                isSuccess: isSuccess
                            )

                            // Merge worker tool results into global summary
                            for toolResult in workerSummary.toolResults {
                                executionSummary.record(
                                    toolName: toolResult.toolName,
                                    params: toolResult.params,
                                    output: toolResult.output,
                                    isSuccess: toolResult.isSuccess
                                )
                            }

                            continuation.yield(.thought("Worker \(workerIndex + 1) \(isSuccess ? "completed" : "failed"): \(result.prefix(150))"))

                        } catch is CancellationError {
                            throw CancellationError()
                        } catch {
                            stateMutator.markWorkerFailed(workerIndex, reason: error.localizedDescription)
                            resultStore.recordResult(
                                workerIndex: workerIndex,
                                taskDescription: assignment.taskDescription,
                                result: error.localizedDescription,
                                isSuccess: false
                            )
                            continuation.yield(.thought("Worker \(workerIndex + 1) error: \(error.localizedDescription)"))
                        }
                    } // End worker loop

                    // ================================================================
                    // PHASE 3: AGGREGATION
                    // ================================================================

                    continuation.yield(.thought("Aggregating worker results..."))

                    await GlobalRateLimiter.shared.wait(for: input.rateLimitCategory)

                    let aggregatedResponse = try await self.aggregate(
                        model: model,
                        input: input,
                        results: resultStore.workerResults,
                        continuation: continuation
                    )

                    executionSummary.finalAgentThought = aggregatedResponse
                    executionSummary.markComplete()

                    let response = await ResponseSynthesizer.synthesize(
                        summary: executionSummary,
                        model: model,
                        personaInstructions: input.instructions,
                        originalQuery: input.userInput,
                        isNativeFlow: input.generatorStrategy is NativeStructuredGenerator
                    )

                    continuation.yield(.content(response))
                    continuation.finish()

                } catch is CancellationError {
                    logger.notice("Supervisor cancelled.")
                    await ExecutionSuspensionService.shared.cancel(for: input.conversationID)
                    stateMutator.markAsCancelled()
                    continuation.finish()
                } catch {
                    logger.error("Supervisor Fatal Error: \(error.localizedDescription)")
                    await ExecutionSuspensionService.shared.cancel(for: input.conversationID)
                    continuation.finish(throwing: error)
                }
            }

            continuation.onTermination = { @Sendable _ in task.cancel() }
        }
    }

    // MARK: - Decomposition LLM Call

    /// Calls the LLM to decompose the user's goal into worker assignments.
    private func decompose(
        model: any LLMProvider,
        input: AgentInput,
        continuation: AsyncThrowingStream<AgentStreamEvent, Error>.Continuation
    ) async throws -> [WorkerAssignment] {

        let toolList = input.tools.map { "- \($0.name): \($0.description)" }.joined(separator: "\n")

        let decomposePrompt = """
        You are a supervisor agent. Decompose the user's request into independent worker tasks.
        Each worker should handle a specific subtask and be assigned relevant tools.

        Available tools:
        \(toolList)

        User's request: "\(input.userInput)"

        Respond with a JSON array of worker objects. Example:
        [
            {"task": "Read the configuration file", "tools": ["read_file"]},
            {"task": "List the project directory", "tools": ["list_directory"]}
        ]

        Rules:
        - Each worker should be independent when possible
        - Assign only relevant tools to each worker
        - Maximum \(self.maxWorkers) workers
        - Output ONLY the JSON array
        """

        let messages: [[String: String]] = [
            ["role": "system", "content": "You are a task decomposition supervisor. Output only a JSON array of worker assignments."],
            ["role": "user", "content": decomposePrompt]
        ]

        let response = try await model.generate(messages: messages, tools: nil, responseSchema: nil)

        let assignments = self.parseWorkerAssignments(from: response, availableTools: input.tools)

        guard !assignments.isEmpty else {
            // Fallback: create a single worker with all tools
            return [WorkerAssignment(
                workerIndex: 0,
                taskDescription: input.userInput,
                assignedTools: input.tools.map { $0.name }
            )]
        }

        return assignments
    }

    // MARK: - Aggregation LLM Call

    /// Calls the LLM to aggregate worker results into a unified response.
    private func aggregate(
        model: any LLMProvider,
        input: AgentInput,
        results: [WorkerResult],
        continuation: AsyncThrowingStream<AgentStreamEvent, Error>.Continuation
    ) async throws -> String {

        let resultsSummary = results.map { r in
            let status = r.isSuccess ? "SUCCESS" : "FAILED"
            let truncated = r.result.count > 500 ? String(r.result.prefix(500)) + "..." : r.result
            return "Worker \(r.workerIndex + 1) [\(status)]: \(r.taskDescription)\nResult: \(truncated)"
        }.joined(separator: "\n\n")

        let aggregatePrompt = """
        You are a supervisor agent synthesizing worker results into a final answer.

        Original goal: "\(input.userInput)"

        Worker Results:
        \(resultsSummary)

        Provide a clear, unified response addressing the user's original request.
        Incorporate successful worker results and note any failures.
        """

        let messages: [[String: String]] = [
            ["role": "system", "content": "You are a result aggregator. Synthesize worker outputs into a clear, concise response."],
            ["role": "user", "content": aggregatePrompt]
        ]

        let response = try await model.generate(messages: messages, tools: nil, responseSchema: nil)
        return response.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - Parsing Helpers

    /// Parses the LLM's decomposition response into worker assignments.
    nonisolated private func parseWorkerAssignments(from response: String, availableTools: [AgentTool]) -> [WorkerAssignment] {
        let cleaned = response
            .replacingOccurrences(of: "```json", with: "")
            .replacingOccurrences(of: "```", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        guard let data = cleaned.data(using: .utf8),
              let array = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
            return []
        }

        let availableToolNames = Set(availableTools.map { $0.name })

        var assignments: [WorkerAssignment] = []
        for (index, item) in array.prefix(maxWorkers).enumerated() {
            let task = item["task"] as? String ?? "Unknown task"
            let tools = (item["tools"] as? [String] ?? []).filter { availableToolNames.contains($0) }

            assignments.append(WorkerAssignment(
                workerIndex: index,
                taskDescription: task,
                assignedTools: tools
            ))
        }

        return assignments
    }
}
