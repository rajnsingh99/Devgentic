//
//  WorkerExecutor.swift
//  Devgentic
//
//  Created for Supervisor Architecture.
//  A lightweight inner executor that handles a single worker's task.
//

import Foundation
import OSLog

private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "com.devgentic.app", category: "WorkerExecutor")

/// A lightweight inner executor for a single worker assignment.
/// Runs a simplified ReAct-like loop scoped to the worker's assigned tools.
/// Unlike the full ReActAgentExecutor, this does not manage persistent state or episodes.
struct WorkerExecutor: Sendable {

    let maxIterations: Int

    init(maxIterations: Int = 10) {
        self.maxIterations = maxIterations
    }

    // MARK: - Worker Execution

    /// Execute the worker's task using the assigned tools.
    /// - Returns: A tuple of (result string, observations collected during execution).
    func execute(
        model: any LLMProvider,
        assignment: WorkerAssignment,
        allTools: [AgentTool],
        generatorStrategy: any CognitiveGenerator,
        rateLimitCategory: RateLimitCategory,
        conversationID: UUID,
        traceContext: TraceContext,
        instructions: String?,
        recentHistory: String?,
        onEvent: @Sendable (AgentStreamEvent) -> Void
    ) async throws -> (result: String, observations: [CognitiveObservation], summary: ExecutionSummary) {

        // Scope tools to the worker's assignment
        let scopedTools: [AgentTool]
        if assignment.assignedTools.isEmpty {
            scopedTools = allTools // If no specific tools assigned, give all
        } else {
            scopedTools = allTools.filter { assignment.assignedTools.contains($0.name) }
        }

        var observations: [CognitiveObservation] = []
        var observationIdCounter = 1
        var circuitBreaker = CognitiveCircuitBreaker()
        var retryStrategy = LLMRetryStrategy()
        let toolMediator = ToolExecutionMediator()
        var executionSummary = ExecutionSummary(originalGoal: assignment.taskDescription)
        var currentIteration = 0
        var finalThought: String? = nil

        logger.info("Worker \(assignment.workerIndex) starting: \(assignment.taskDescription)")

        // --- Worker Cognitive Loop ---
        cognitiveLoop: while currentIteration < maxIterations {
            try Task.checkCancellation()
            currentIteration += 1

            await GlobalRateLimiter.shared.wait(for: rateLimitCategory)

            let iterationSpan = traceContext.newSpan()

            // Build context scoped to this worker
            let envFacts = EnvironmentFacts(
                osVersion: ProcessInfo.processInfo.operatingSystemVersionString,
                shellType: "Zsh (Non-Interactive Mode)",
                userName: NSUserName(),
                currentDate: Date().formatted(date: .numeric, time: .shortened)
            )

            let activeObs = observations.filter { $0.isRequired }

            let context = SemanticContext(
                instructions: instructions,
                environmentFacts: envFacts,
                compressedStateGraph: "{}",
                recentHistory: recentHistory,
                originalQuery: "WORKER TASK: \(assignment.taskDescription)",
                currentIteration: currentIteration,
                activeObservations: activeObs,
                latestClarification: nil,
                negativeConstraints: [],
                hallucinatedTools: circuitBreaker.hallucinatedTools,
                availableTools: scopedTools
            )

            // --- Generation ---
            let step: LeanCognitiveStep
            do {
                step = try await generatorStrategy.generate(
                    model: model,
                    context: context,
                    iteration: currentIteration
                )
                retryStrategy.resetParseFailures()
            } catch {
                let action = retryStrategy.handleError(error)
                switch action {
                case .throttle(let seconds, let message):
                    await GlobalRateLimiter.shared.drainAndPenalize(category: rateLimitCategory, penaltySeconds: seconds)
                    onEvent(.thought(message))
                    try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
                    currentIteration -= 1
                    continue cognitiveLoop
                case .networkRetry(let message):
                    onEvent(.thought(message))
                    currentIteration -= 1
                    continue cognitiveLoop
                case .parseRetry(let systemAlert, _, _):
                    let alert = CognitiveObservation(stepId: observationIdCounter, toolName: "system", shortObservation: systemAlert, heavyContent: nil, isRequired: true)
                    observations.append(alert)
                    observationIdCounter += 1
                    continue cognitiveLoop
                case .abort(let reason):
                    executionSummary.markComplete(failureReason: reason)
                    return (reason, observations, executionSummary)
                }
            }

            // Evict old observations
            for i in observations.indices {
                if observations[i].isRequired && i < observations.count - 1 {
                    observations[i].isRequired = false
                }
            }

            onEvent(.thought(step.content))

            // --- Termination Check ---
            let toolName = step.toolName?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? ""
            if toolName.isEmpty || toolName == "null" || toolName == "none" {
                finalThought = step.content
                break cognitiveLoop
            }

            guard let toolName = step.toolName else {
                finalThought = step.content
                break cognitiveLoop
            }
            let arguments = step.arguments ?? [:]

            // --- Tool Existence Check ---
            let allAvailableTools = scopedTools.map { $0.name } + ["ask_user"]
            if !allAvailableTools.contains(toolName) {
                let msg = "Worker: Tool '\(toolName)' not available."
                let alert = CognitiveObservation(stepId: observationIdCounter, toolName: "system", shortObservation: msg, heavyContent: nil, isRequired: true)
                observations.append(alert)
                observationIdCounter += 1
                circuitBreaker.recordHallucination(toolName)
                continue cognitiveLoop
            }

            // --- Validate Arguments ---
            if let toolDef = scopedTools.first(where: { $0.name == toolName }),
               !toolDef.parameters.required.isEmpty,
               arguments.isEmpty {
                let msg = "Tool '\(toolName)' requires parameters but received empty arguments."
                let alert = CognitiveObservation(stepId: observationIdCounter, toolName: "system", shortObservation: msg, heavyContent: nil, isRequired: true)
                observations.append(alert)
                observationIdCounter += 1
                continue cognitiveLoop
            }

            // --- Circuit Breaker ---
            let paramsString = serializeParams(arguments)
            let attemptAction = circuitBreaker.evaluateToolAttempt(toolName: toolName, paramsHash: paramsString.hashValue)
            if case .intervene(let msg) = attemptAction {
                let alert = CognitiveObservation(stepId: observationIdCounter, toolName: "system", shortObservation: msg, heavyContent: nil, isRequired: true)
                observations.append(alert)
                observationIdCounter += 1
                continue cognitiveLoop
            }

            onEvent(.toolCall(name: toolName, params: paramsString))

            // --- Tool Execution (no HITL for workers — supervisor handles decisions) ---
            let executionResult = await toolMediator.executePreparedTool(
                toolName: toolName,
                arguments: arguments,
                availableTools: scopedTools,
                parentContext: iterationSpan
            )

            let observation = executionResult.llmObservation
            let isSuccess = executionResult.isSuccess

            executionSummary.record(toolName: toolName, params: paramsString, output: observation, isSuccess: isSuccess)

            // --- Side Effects ---
            switch executionResult {
            case .success, .userDenied:
                break
            case .hallucinated(let tName, _):
                circuitBreaker.recordHallucination(tName)
            case .timedOut, .semanticFailure, .systemError:
                let alert = CognitiveObservation(stepId: observationIdCounter, toolName: "system", shortObservation: "Tool '\(toolName)' failed.", heavyContent: nil, isRequired: true)
                observations.append(alert)
                observationIdCounter += 1
            }

            // --- Consecutive Failure Check ---
            let resultAction = circuitBreaker.recordToolResult(isSuccess: isSuccess)
            if case .abort(let reason) = resultAction {
                executionSummary.markComplete(failureReason: reason)
                return (reason, observations, executionSummary)
            }

            onEvent(.toolOutput(ToolOutput(toolName: toolName, output: observation, isSuccess: isSuccess)))

            let isHeavy = observation.count > 300
            let shortObs = isHeavy
                ? "Worker \(assignment.workerIndex) Obs \(currentIteration): '\(toolName)' executed."
                : "Worker \(assignment.workerIndex) Obs \(currentIteration): '\(toolName)' returned: \(observation)"

            let obs = CognitiveObservation(
                stepId: observationIdCounter,
                toolName: toolName,
                shortObservation: shortObs,
                heavyContent: isHeavy ? observation : nil,
                isRequired: true
            )
            observations.append(obs)
            observationIdCounter += 1

        } // End cognitive loop

        let result = finalThought ?? "Worker completed after \(currentIteration) iterations."
        executionSummary.finalAgentThought = result
        executionSummary.markComplete()
        return (result, observations, executionSummary)
    }

    // MARK: - Helpers

    private func serializeParams(_ params: [String: AnyCodable]) -> String {
        if let data = try? JSONEncoder().encode(params), let str = String(data: data, encoding: .utf8) { return str }
        return "{}"
    }
}
