//
//  PlanAndExecuteExecutor.swift
//  Devgentic
//
//  Created for Plan & Execute Architecture.
//  Two-phase executor: (1) Plan decomposition, (2) Sequential step execution with optional re-planning.
//

import Foundation
import OSLog

private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "com.devgentic.app", category: "PlanExecutor")
private let logToolExecution = Logger(subsystem: Bundle.main.bundleIdentifier ?? "com.devgentic.app", category: "ToolExecution")

// MARK: - Executor Implementation

/// A two-phase agent executor implementing the Plan & Execute paradigm.
/// Phase 1: Decomposes the user's goal into an ordered list of steps via LLM.
/// Phase 2: Executes each step sequentially using tool calls, with optional re-planning on failure.
actor PlanAndExecuteExecutor: Executor {

    // MARK: - Properties

    nonisolated let architecture: AgentArchitecture = .planAndExecute
    nonisolated private let maxIterationsPerStep: Int
    nonisolated private let maxReplans: Int

    // MARK: - Initialization

    init(maxIterationsPerStep: Int = 10, maxReplans: Int = 2) {
        self.maxIterationsPerStep = maxIterationsPerStep
        self.maxReplans = maxReplans
    }

    // MARK: - Execution Entry Point

    nonisolated func execute(
        model: any LLMProvider,
        input: AgentInput,
        onTraceUpdate: @escaping @Sendable (AgentTraceLog) -> Void
    ) -> AsyncThrowingStream<AgentStreamEvent, Error> {

        return AsyncThrowingStream<AgentStreamEvent, Error> { continuation in
            let task = Task {

                var stateMutator = PlanStateMutator(conversationID: input.conversationID)
                var executionSummary = ExecutionSummary(originalGoal: input.userInput)

                do {
                    logger.info("Plan & Execute Initiated.")

                    let executionTrace = input.traceContext

                    // --- Load Reusable Components ---
                    var circuitBreaker = CognitiveCircuitBreaker()
                    var retryStrategy = LLMRetryStrategy()
                    let toolMediator = ToolExecutionMediator()
                    let terminationEvaluator = PlanTerminationEvaluator()

                    // ================================================================
                    // PHASE 1: PLANNING
                    // ================================================================

                    continuation.yield(.thought("Analyzing request and creating a plan..."))

                    await GlobalRateLimiter.shared.wait(for: input.rateLimitCategory)

                    let planSteps = try await self.generatePlan(
                        model: model,
                        input: input,
                        retryStrategy: &retryStrategy,
                        continuation: continuation
                    )

                    stateMutator.initializePlan(goal: input.userInput, steps: planSteps)

                    let planSummary = planSteps.enumerated().map { "\($0.offset + 1). \($0.element.description)" }.joined(separator: "\n")
                    continuation.yield(.thought("Plan created:\n\(planSummary)"))

                    onTraceUpdate(AgentTraceLog(
                        traceID: executionTrace.traceID,
                        spanID: executionTrace.newSpan().spanID,
                        parentSpanID: executionTrace.parentSpanID,
                        stepNumber: 0,
                        state: .thinking,
                        content: "Plan created with \(planSteps.count) steps"
                    ))

                    // ================================================================
                    // PHASE 2: EXECUTION
                    // ================================================================

                    var currentStepIndex = 0

                    stepLoop: while currentStepIndex < stateMutator.currentPlan.steps.count {
                        try Task.checkCancellation()

                        let currentStep = stateMutator.currentPlan.steps[currentStepIndex]

                        // Skip non-pending steps (e.g., already completed in a re-plan)
                        guard currentStep.status == .pending else {
                            currentStepIndex += 1
                            continue stepLoop
                        }

                        stateMutator.markStepInProgress(currentStepIndex)
                        continuation.yield(.thought("Executing step \(currentStepIndex + 1): \(currentStep.description)"))

                        var stepObservations = StepObservationStore()
                        var iterationInStep = 0

                        // --- Inner execution loop for this step ---
                        innerLoop: while iterationInStep < self.maxIterationsPerStep {
                            try Task.checkCancellation()
                            iterationInStep += 1

                            await GlobalRateLimiter.shared.wait(for: input.rateLimitCategory)

                            let iterationSpan = executionTrace.newSpan()

                            // --- Build Context ---
                            let envFacts = EnvironmentFacts(
                                osVersion: ProcessInfo.processInfo.operatingSystemVersionString,
                                shellType: "Zsh (Non-Interactive Mode)",
                                userName: NSUserName(),
                                currentDate: Date().formatted(date: .numeric, time: .shortened)
                            )

                            let context = SemanticContext(
                                instructions: input.instructions,
                                environmentFacts: envFacts,
                                compressedStateGraph: stateMutator.currentPlan.compressForPrompt(),
                                recentHistory: input.recentHistory,
                                originalQuery: "PLAN STEP \(currentStepIndex + 1)/\(stateMutator.currentPlan.steps.count): \(currentStep.description)\n\nOriginal goal: \(input.userInput)",
                                currentIteration: iterationInStep,
                                activeObservations: stepObservations.activeObservations,
                                latestClarification: nil,
                                negativeConstraints: stateMutator.currentConstraints,
                                hallucinatedTools: circuitBreaker.hallucinatedTools,
                                availableTools: input.tools
                            )

                            // --- Structured Generation ---
                            let step: LeanCognitiveStep
                            do {
                                step = try await input.generatorStrategy.generate(
                                    model: model,
                                    context: context,
                                    iteration: iterationInStep
                                )
                                retryStrategy.resetParseFailures()
                            } catch {
                                let action = retryStrategy.handleError(error)
                                switch action {
                                case .throttle(let seconds, let message):
                                    await GlobalRateLimiter.shared.drainAndPenalize(category: input.rateLimitCategory, penaltySeconds: seconds)
                                    continuation.yield(.thought(message))
                                    try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
                                    iterationInStep -= 1
                                    continue innerLoop

                                case .networkRetry(let message):
                                    continuation.yield(.thought(message))
                                    iterationInStep -= 1
                                    continue innerLoop

                                case .parseRetry(let systemAlert, let attemptCount, let maxAttempts):
                                    stepObservations.addSystemAlert(systemAlert, stepIndex: currentStepIndex)
                                    continuation.yield(.thought("Error: Invalid JSON output. Retrying (\(attemptCount)/\(maxAttempts))..."))
                                    await GlobalRateLimiter.shared.wait(for: input.rateLimitCategory)
                                    continue innerLoop

                                case .abort(let reason):
                                    stateMutator.markStepFailed(currentStepIndex, reason: reason)
                                    executionSummary.markComplete(failureReason: reason)
                                    continuation.yield(.content(reason))
                                    continuation.finish()
                                    return
                                }
                            }

                            // --- Pre-Execution Setup ---
                            stepObservations.resetObservationFlags()
                            continuation.yield(.thought(step.content))

                            // --- Termination Evaluation ---
                            let termStatus = terminationEvaluator.evaluateStep(
                                step: step,
                                currentStepIndex: currentStepIndex,
                                totalSteps: stateMutator.currentPlan.steps.count,
                                iterationInStep: iterationInStep,
                                maxIterationsPerStep: self.maxIterationsPerStep
                            )

                            switch termStatus {
                            case .stepCompleted(let outcome):
                                stateMutator.markStepCompleted(currentStepIndex, outcome: outcome)
                                continuation.yield(.thought("Step \(currentStepIndex + 1) completed."))
                                break innerLoop

                            case .replanRequired(let failedStep, let reason):
                                stateMutator.markStepFailed(failedStep, reason: reason)
                                if stateMutator.currentPlan.replanCount < self.maxReplans {
                                    continuation.yield(.thought("Step failed. Re-planning remaining steps..."))
                                    let newSteps = try await self.replan(
                                        model: model,
                                        input: input,
                                        stateMutator: stateMutator,
                                        failedStepIndex: failedStep,
                                        failureReason: reason,
                                        retryStrategy: &retryStrategy,
                                        continuation: continuation
                                    )
                                    stateMutator.replacePlan(newSteps: newSteps)
                                } else {
                                    continuation.yield(.thought("Re-planning budget exhausted."))
                                }
                                break innerLoop

                            case .allStepsCompleted:
                                break stepLoop

                            case .budgetExhausted:
                                break stepLoop

                            case .proceed:
                                break
                            }

                            guard let toolName = step.toolName else { break innerLoop }
                            let arguments = step.arguments ?? [:]

                            // --- Handle ask_user ---
                            if toolName == "ask_user" {
                                let cbAction = circuitBreaker.evaluateAskUser()
                                switch cbAction {
                                case .abort(let reason):
                                    executionSummary.markComplete(failureReason: reason)
                                    let response = await ResponseSynthesizer.synthesize(summary: executionSummary, model: model, personaInstructions: input.instructions, originalQuery: input.userInput)
                                    continuation.yield(.content(response))
                                    continuation.finish()
                                    return
                                case .intervene(let systemMessage):
                                    stepObservations.addSystemAlert(systemMessage, stepIndex: currentStepIndex)
                                    continue innerLoop
                                case .proceed:
                                    break
                                }

                                let question: String
                                if let q = arguments["question"],
                                   let encoder = try? JSONEncoder().encode(q),
                                   let str = String(data: encoder, encoding: .utf8) {
                                    question = str.trimmingCharacters(in: CharacterSet(charactersIn: "\""))
                                } else {
                                    question = step.content
                                }

                                continuation.yield(.requestClarification(question: question))

                                let userResponse = await ExecutionSuspensionService.shared.suspendForClarification(for: input.conversationID)
                                let paramsStr = "{\"question\": \"\(question)\"}"

                                if let response = userResponse, !response.isEmpty {
                                    let lower = response.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                                    let terminalPhrases = ["stop", "cancel", "no", "leave it", "abort", "quit", "exit"]
                                    let isTerminal = terminalPhrases.contains { lower == $0 || lower.hasPrefix($0) || lower.hasPrefix("no,") }

                                    if isTerminal {
                                        executionSummary.record(toolName: "ask_user", params: paramsStr, output: "User aborted.", isSuccess: false)
                                        stateMutator.markAsCancelled()
                                        continuation.yield(.content("Task cancelled as requested."))
                                        continuation.finish()
                                        return
                                    }

                                    stepObservations.addObservation(
                                        toolName: "ask_user",
                                        shortObservation: "User responded: \(response)",
                                        heavyContent: nil,
                                        isRequired: true
                                    )
                                    executionSummary.record(toolName: "ask_user", params: paramsStr, output: response, isSuccess: true)
                                    continuation.yield(.toolOutput(ToolOutput(toolName: "ask_user", output: response, isSuccess: true)))
                                } else {
                                    stepObservations.addSystemAlert("User did not respond. Proceeding with best judgment.", stepIndex: currentStepIndex)
                                    executionSummary.record(toolName: "ask_user", params: paramsStr, output: "No response.", isSuccess: false)
                                }
                                continue innerLoop
                            }

                            // --- Validate Arguments ---
                            if let toolDef = input.tools.first(where: { $0.name == toolName }),
                               !toolDef.parameters.required.isEmpty,
                               arguments.isEmpty {
                                let msg = "Tool '\(toolName)' requires parameters but received empty arguments."
                                stepObservations.addSystemAlert(msg, stepIndex: currentStepIndex)
                                continue innerLoop
                            }

                            // --- Ghost Protocol Check ---
                            if let path = self.extractPath(from: arguments), stateMutator.currentPlan.isPathForbidden(path) {
                                let msg = "GHOST PROTOCOL: Access to '\(path)' is FORBIDDEN."
                                stepObservations.addSystemAlert(msg, stepIndex: currentStepIndex)
                                continuation.yield(.thought(msg))
                                continue innerLoop
                            }

                            // --- Tool Existence Check ---
                            let allAvailableTools = input.tools.map { $0.name } + ["ask_user"]
                            if !allAvailableTools.contains(toolName) {
                                let msg = "Tool '\(toolName)' does not exist."
                                stepObservations.addSystemAlert(msg, stepIndex: currentStepIndex)
                                continuation.yield(.thought(msg))
                                continue innerLoop
                            }

                            // --- HITL Preparation ---
                            let dispatchOutcome = toolMediator.prepareDispatch(toolName: toolName, arguments: arguments, availableTools: input.tools)
                            let paramsString: String

                            switch dispatchOutcome {
                            case .requiresConfirmation(let ps):
                                paramsString = ps
                                continuation.yield(.requestConfirmation(toolName: toolName, params: paramsString))
                                let approved = await ExecutionSuspensionService.shared.suspend(for: input.conversationID)
                                if !approved {
                                    let denialResult = ToolExecutionResult.userDenied(toolName: toolName)
                                    stepObservations.addSystemAlert(denialResult.llmObservation, stepIndex: currentStepIndex)
                                    executionSummary.record(toolName: toolName, params: paramsString, output: denialResult.llmObservation, isSuccess: false)
                                    continuation.yield(.toolOutput(ToolOutput(toolName: toolName, output: denialResult.llmObservation, isSuccess: false)))
                                    continue innerLoop
                                }
                            case .executed(_, let ps):
                                paramsString = ps
                            case .userDenied(_, let ps):
                                paramsString = ps
                            }

                            circuitBreaker.resetCountersOnSuccess()

                            // --- Circuit Breaker ---
                            let attemptAction = circuitBreaker.evaluateToolAttempt(toolName: toolName, paramsHash: paramsString.hashValue)
                            if case .intervene(let msg) = attemptAction {
                                stepObservations.addSystemAlert(msg, stepIndex: currentStepIndex)
                                continuation.yield(.thought(msg))
                                continue innerLoop
                            }

                            continuation.yield(.toolCall(name: toolName, params: paramsString))

                            onTraceUpdate(AgentTraceLog(
                                traceID: iterationSpan.traceID,
                                spanID: iterationSpan.spanID,
                                parentSpanID: iterationSpan.parentSpanID,
                                stepNumber: iterationInStep,
                                state: .acting,
                                content: "Step \(currentStepIndex + 1): Executing \(toolName)..."
                            ))

                            // --- Tool Execution ---
                            let executionResult = await toolMediator.executePreparedTool(
                                toolName: toolName,
                                arguments: arguments,
                                availableTools: input.tools,
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
                                if let path = self.extractPath(from: arguments) {
                                    stateMutator.addNegativeConstraint(path)
                                }
                                stepObservations.addSystemAlert("Tool '\(toolName)' failed.", stepIndex: currentStepIndex)
                            }

                            // --- Consecutive Failure Check ---
                            let resultAction = circuitBreaker.recordToolResult(isSuccess: isSuccess)
                            switch resultAction {
                            case .abort(let reason):
                                executionSummary.markComplete(failureReason: reason)
                                let response = await ResponseSynthesizer.synthesize(summary: executionSummary, model: model, personaInstructions: input.instructions, originalQuery: input.userInput)
                                stateMutator.markStepFailed(currentStepIndex, reason: reason)
                                continuation.yield(.content(response))
                                continuation.finish()
                                return
                            case .intervene(let msg):
                                stepObservations.addSystemAlert(msg, stepIndex: currentStepIndex)
                            case .proceed:
                                break
                            }

                            continuation.yield(.toolOutput(ToolOutput(toolName: toolName, output: observation, isSuccess: isSuccess)))

                            let isHeavy = observation.count > 300
                            let shortObs = isHeavy
                                ? "Observation (Step \(currentStepIndex + 1), Iter \(iterationInStep)): '\(toolName)' executed."
                                : "Observation (Step \(currentStepIndex + 1), Iter \(iterationInStep)): '\(toolName)' returned: \(observation)"

                            stepObservations.addObservation(
                                toolName: toolName,
                                shortObservation: shortObs,
                                heavyContent: isHeavy ? observation : nil,
                                isRequired: true
                            )

                        } // End inner loop

                        // If step didn't complete via termination, mark based on observations
                        if stateMutator.currentPlan.steps[currentStepIndex].status == .inProgress {
                            stateMutator.markStepCompleted(currentStepIndex, outcome: "Step completed after \(iterationInStep) iterations.")
                        }

                        stepObservations.clearForNextStep()
                        circuitBreaker.resetCountersOnSuccess()
                        currentStepIndex += 1
                    } // End step loop

                    // ================================================================
                    // POST-LOOP: Synthesize Response
                    // ================================================================

                    let allCompleted = stateMutator.currentPlan.steps.allSatisfy { $0.status == .completed || $0.status == .skipped }
                    if allCompleted {
                        executionSummary.markComplete()
                    } else {
                        executionSummary.markComplete(failureReason: "Not all plan steps completed.")
                    }

                    // Build final thought from step outcomes
                    let stepOutcomes = stateMutator.currentPlan.steps
                        .filter { $0.status == .completed }
                        .map { "Step \($0.index + 1): \($0.outcome ?? "Done")" }
                        .joined(separator: "\n")
                    executionSummary.finalAgentThought = stepOutcomes

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
                    logger.notice("Plan & Execute cancelled.")
                    await ExecutionSuspensionService.shared.cancel(for: input.conversationID)
                    stateMutator.markAsCancelled()
                    continuation.finish()
                } catch {
                    logger.error("Plan & Execute Fatal Error: \(error.localizedDescription)")
                    await ExecutionSuspensionService.shared.cancel(for: input.conversationID)
                    continuation.finish(throwing: error)
                }
            }

            continuation.onTermination = { @Sendable _ in task.cancel() }
        }
    }

    // MARK: - Planning LLM Call

    /// Calls the LLM to decompose the user's goal into a sequence of plan steps.
    private func generatePlan(
        model: any LLMProvider,
        input: AgentInput,
        retryStrategy: inout LLMRetryStrategy,
        continuation: AsyncThrowingStream<AgentStreamEvent, Error>.Continuation
    ) async throws -> [PlanStep] {

        let toolList = input.tools.map { "- \($0.name): \($0.description)" }.joined(separator: "\n")

        let planPrompt = """
        You are a planning agent. Decompose the user's request into a sequence of concrete, executable steps.
        Each step should be a single action that can be accomplished using the available tools.

        Available tools:
        \(toolList)

        User's request: "\(input.userInput)"

        Respond with a JSON array of step descriptions. Example:
        ["Read the file to understand its contents", "Modify the relevant section", "Write the updated file"]

        Output ONLY the JSON array, no other text.
        """

        let messages: [[String: String]] = [
            ["role": "system", "content": "You are a task decomposition planner. Output only a JSON array of step description strings."],
            ["role": "user", "content": planPrompt]
        ]

        let response = try await model.generate(messages: messages, tools: nil, responseSchema: nil)
        retryStrategy.resetParseFailures()

        // Parse the response into step descriptions
        let descriptions = self.parsePlanSteps(from: response)

        guard !descriptions.isEmpty else {
            // Fallback: treat the entire task as a single step
            return [PlanStep(index: 0, description: input.userInput)]
        }

        return descriptions.enumerated().map { idx, desc in
            PlanStep(index: idx, description: desc)
        }
    }

    // MARK: - Re-Planning LLM Call

    private func replan(
        model: any LLMProvider,
        input: AgentInput,
        stateMutator: PlanStateMutator,
        failedStepIndex: Int,
        failureReason: String,
        retryStrategy: inout LLMRetryStrategy,
        continuation: AsyncThrowingStream<AgentStreamEvent, Error>.Continuation
    ) async throws -> [PlanStep] {

        let completedSteps = stateMutator.currentPlan.steps
            .filter { $0.status == .completed }
            .map { "Step \($0.index + 1) (DONE): \($0.description) -> \($0.outcome ?? "completed")" }
            .joined(separator: "\n")

        let replanPrompt = """
        The original plan encountered a failure. Re-plan the remaining steps.

        Original goal: "\(input.userInput)"

        Completed steps:
        \(completedSteps.isEmpty ? "None" : completedSteps)

        Failed step \(failedStepIndex + 1): \(stateMutator.currentPlan.steps[failedStepIndex].description)
        Failure reason: \(failureReason)

        Create new steps to complete the remaining goal, avoiding the failed approach.
        Output ONLY a JSON array of step description strings.
        """

        let messages: [[String: String]] = [
            ["role": "system", "content": "You are a task re-planner. Output only a JSON array of step description strings."],
            ["role": "user", "content": replanPrompt]
        ]

        let response = try await model.generate(messages: messages, tools: nil, responseSchema: nil)

        let descriptions = self.parsePlanSteps(from: response)
        let startIndex = stateMutator.currentPlan.steps.count
        return descriptions.enumerated().map { idx, desc in
            PlanStep(index: startIndex + idx, description: desc)
        }
    }

    // MARK: - Helpers

    /// Parses a JSON array of strings from the LLM response.
    nonisolated private func parsePlanSteps(from response: String) -> [String] {
        let cleaned = response
            .replacingOccurrences(of: "```json", with: "")
            .replacingOccurrences(of: "```", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        guard let data = cleaned.data(using: .utf8),
              let array = try? JSONSerialization.jsonObject(with: data) as? [String] else {
            // Fallback: try to split by newlines with numbered prefixes
            let lines = response.components(separatedBy: .newlines)
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
                .map { line -> String in
                    // Strip "1. ", "2. ", "- ", etc.
                    var stripped = line
                    if let range = stripped.range(of: #"^\d+[\.\)]\s*"#, options: .regularExpression) {
                        stripped = String(stripped[range.upperBound...])
                    }
                    if stripped.hasPrefix("- ") { stripped = String(stripped.dropFirst(2)) }
                    return stripped
                }
                .filter { !$0.isEmpty }
            return lines
        }

        return array
    }

    nonisolated private func extractPath(from params: [String: AnyCodable]) -> String? {
        if let val = params["path"],
           let data = try? JSONEncoder().encode(val),
           let str = String(data: data, encoding: .utf8) {
            return str.trimmingCharacters(in: CharacterSet(charactersIn: "\""))
        }
        return nil
    }
}
