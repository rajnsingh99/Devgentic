//
//  ReflexionExecutor.swift
//  Devgentic
//
//  Created for Reflexion Architecture.
//  Execute-Reflect-Retry loop with self-improving behavior across trials.
//

import Foundation
import OSLog

private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "com.devgentic.app", category: "ReflexionExecutor")
private let logToolExecution = Logger(subsystem: Bundle.main.bundleIdentifier ?? "com.devgentic.app", category: "ToolExecution")

// MARK: - Executor Implementation

/// An agent executor implementing the Reflexion paradigm.
/// Wraps a ReAct-like inner execution loop with an outer reflection layer.
/// After each trial, the LLM evaluates result quality and provides reflection insights.
/// If unsatisfactory, the agent retries with accumulated reflections as additional context.
actor ReflexionExecutor: Executor {

    // MARK: - Properties

    nonisolated let architecture: AgentArchitecture = .reflexion
    nonisolated private let maxTrials: Int
    nonisolated private let maxIterationsPerTrial: Int

    // MARK: - Initialization

    init(maxTrials: Int = 3, maxIterationsPerTrial: Int = 15) {
        self.maxTrials = maxTrials
        self.maxIterationsPerTrial = maxIterationsPerTrial
    }

    // MARK: - Execution Entry Point

    nonisolated func execute(
        model: any LLMProvider,
        input: AgentInput,
        onTraceUpdate: @escaping @Sendable (AgentTraceLog) -> Void
    ) -> AsyncThrowingStream<AgentStreamEvent, Error> {

        return AsyncThrowingStream<AgentStreamEvent, Error> { continuation in
            let task = Task {

                var stateMutator = TrialStateMutator(conversationID: input.conversationID)
                var executionSummary = ExecutionSummary(originalGoal: input.userInput)

                do {
                    logger.info("Reflexion Execution Initiated. Max trials: \(self.maxTrials)")

                    let executionTrace = input.traceContext
                    var memoryStore = ReflectionMemoryStore()
                    let reflectionEvaluator = ReflectionEvaluator()

                    var bestOutcome: String? = nil

                    // ================================================================
                    // OUTER LOOP: TRIALS
                    // ================================================================

                    trialLoop: for trialNumber in 1...self.maxTrials {
                        try Task.checkCancellation()

                        stateMutator.startNewTrial(goal: input.userInput)
                        memoryStore.clearObservationsForNewTrial()

                        var circuitBreaker = CognitiveCircuitBreaker()
                        var retryStrategy = LLMRetryStrategy()
                        let toolMediator = ToolExecutionMediator()

                        var trialSummary = ExecutionSummary(originalGoal: input.userInput)
                        var latestClarification: String? = nil
                        var currentIteration = 0

                        let reflectionContext = memoryStore.reflections.isEmpty
                            ? ""
                            : "\n\n## REFLECTIONS FROM PAST TRIALS\n" + memoryStore.reflections.enumerated().map { "Trial \($0.offset + 1): \($0.element)" }.joined(separator: "\n")

                        if trialNumber > 1 {
                            continuation.yield(.thought("Trial \(trialNumber)/\(self.maxTrials): Retrying with reflection insights..."))
                        } else {
                            continuation.yield(.thought("Trial \(trialNumber)/\(self.maxTrials): Executing task..."))
                        }

                        // ================================================================
                        // INNER LOOP: ReAct-like Execution
                        // ================================================================

                        cognitiveLoop: while currentIteration < self.maxIterationsPerTrial {
                            try Task.checkCancellation()
                            currentIteration += 1

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
                                instructions: (input.instructions ?? "") + reflectionContext,
                                environmentFacts: envFacts,
                                compressedStateGraph: stateMutator.currentGraph.compressForPrompt(),
                                recentHistory: input.recentHistory,
                                originalQuery: input.userInput,
                                currentIteration: currentIteration,
                                activeObservations: memoryStore.activeObservations,
                                latestClarification: latestClarification,
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
                                    iteration: currentIteration
                                )
                                retryStrategy.resetParseFailures()
                            } catch {
                                let action = retryStrategy.handleError(error)
                                switch action {
                                case .throttle(let seconds, let message):
                                    await GlobalRateLimiter.shared.drainAndPenalize(category: input.rateLimitCategory, penaltySeconds: seconds)
                                    continuation.yield(.thought(message))
                                    try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
                                    currentIteration -= 1
                                    continue cognitiveLoop

                                case .networkRetry(let message):
                                    continuation.yield(.thought(message))
                                    currentIteration -= 1
                                    continue cognitiveLoop

                                case .parseRetry(let systemAlert, let attemptCount, let maxAttempts):
                                    memoryStore.addSystemAlert(systemAlert, currentIteration: currentIteration)
                                    continuation.yield(.thought("Error: Invalid JSON. Retrying (\(attemptCount)/\(maxAttempts))..."))
                                    await GlobalRateLimiter.shared.wait(for: input.rateLimitCategory)
                                    continue cognitiveLoop

                                case .abort(let reason):
                                    stateMutator.closeTrial(outcome: reason, reflection: "Aborted due to error.", verdict: .fail)
                                    executionSummary.markComplete(failureReason: reason)
                                    continuation.yield(.content(reason))
                                    continuation.finish()
                                    return
                                }
                            }

                            // --- Pre-Execution ---
                            memoryStore.resetObservationFlags()
                            continuation.yield(.thought(step.content))

                            // --- Termination Check ---
                            let toolName = step.toolName?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? ""
                            if toolName.isEmpty || toolName == "null" || toolName == "none" {
                                trialSummary.finalAgentThought = step.content
                                break cognitiveLoop
                            }

                            if currentIteration >= self.maxIterationsPerTrial {
                                break cognitiveLoop
                            }

                            guard let toolName = step.toolName else { break cognitiveLoop }
                            let arguments = step.arguments ?? [:]

                            // --- Handle ask_user ---
                            if toolName == "ask_user" {
                                let cbAction = circuitBreaker.evaluateAskUser()
                                switch cbAction {
                                case .abort(let reason):
                                    trialSummary.markComplete(failureReason: reason)
                                    let response = await ResponseSynthesizer.synthesize(summary: trialSummary, model: model, personaInstructions: input.instructions, originalQuery: input.userInput)
                                    continuation.yield(.content(response))
                                    continuation.finish()
                                    return
                                case .intervene(let systemMessage):
                                    memoryStore.addSystemAlert(systemMessage, currentIteration: currentIteration)
                                    continue cognitiveLoop
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
                                        trialSummary.record(toolName: "ask_user", params: paramsStr, output: "User aborted.", isSuccess: false)
                                        stateMutator.markAsCancelled()
                                        continuation.yield(.content("Task cancelled as requested."))
                                        continuation.finish()
                                        return
                                    }

                                    latestClarification = "You asked: \"\(question)\"\nUser responded: \"\(response)\""
                                    memoryStore.addObservation(toolName: "ask_user", shortObservation: "User responded: \(response)", heavyContent: nil, isRequired: true)
                                    trialSummary.record(toolName: "ask_user", params: paramsStr, output: response, isSuccess: true)
                                    continuation.yield(.toolOutput(ToolOutput(toolName: "ask_user", output: response, isSuccess: true)))
                                } else {
                                    memoryStore.addSystemAlert("User did not respond.", currentIteration: currentIteration)
                                    trialSummary.record(toolName: "ask_user", params: paramsStr, output: "No response.", isSuccess: false)
                                }
                                continue cognitiveLoop
                            }

                            // --- Validate Arguments ---
                            if let toolDef = input.tools.first(where: { $0.name == toolName }),
                               !toolDef.parameters.required.isEmpty,
                               arguments.isEmpty {
                                let msg = "Tool '\(toolName)' requires parameters but received empty arguments."
                                memoryStore.addSystemAlert(msg, currentIteration: currentIteration)
                                continue cognitiveLoop
                            }

                            // --- Ghost Protocol Check ---
                            if let path = self.extractPath(from: arguments), stateMutator.currentGraph.isPathForbidden(path) {
                                let msg = "GHOST PROTOCOL: Access to '\(path)' is FORBIDDEN."
                                memoryStore.addSystemAlert(msg, currentIteration: currentIteration)
                                continuation.yield(.thought(msg))
                                continue cognitiveLoop
                            }

                            // --- Tool Existence Check ---
                            let allAvailableTools = input.tools.map { $0.name } + ["ask_user"]
                            if !allAvailableTools.contains(toolName) {
                                let msg = "Tool '\(toolName)' does not exist."
                                memoryStore.addSystemAlert(msg, currentIteration: currentIteration)
                                circuitBreaker.recordHallucination(toolName)
                                continue cognitiveLoop
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
                                    memoryStore.addSystemAlert(denialResult.llmObservation, currentIteration: currentIteration)
                                    trialSummary.record(toolName: toolName, params: paramsString, output: denialResult.llmObservation, isSuccess: false)
                                    continuation.yield(.toolOutput(ToolOutput(toolName: toolName, output: denialResult.llmObservation, isSuccess: false)))
                                    continue cognitiveLoop
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
                                memoryStore.addSystemAlert(msg, currentIteration: currentIteration)
                                continuation.yield(.thought(msg))
                                continue cognitiveLoop
                            }

                            continuation.yield(.toolCall(name: toolName, params: paramsString))

                            onTraceUpdate(AgentTraceLog(
                                traceID: iterationSpan.traceID,
                                spanID: iterationSpan.spanID,
                                parentSpanID: iterationSpan.parentSpanID,
                                stepNumber: currentIteration,
                                state: .acting,
                                content: "Trial \(trialNumber): Executing \(toolName)..."
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

                            trialSummary.record(toolName: toolName, params: paramsString, output: observation, isSuccess: isSuccess)

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
                                memoryStore.addSystemAlert("Tool '\(toolName)' failed.", currentIteration: currentIteration)
                            }

                            // --- Consecutive Failure Check ---
                            let resultAction = circuitBreaker.recordToolResult(isSuccess: isSuccess)
                            switch resultAction {
                            case .abort(let reason):
                                trialSummary.markComplete(failureReason: reason)
                                let response = await ResponseSynthesizer.synthesize(summary: trialSummary, model: model, personaInstructions: input.instructions, originalQuery: input.userInput)
                                stateMutator.closeTrial(outcome: response, reflection: "Aborted: \(reason)", verdict: .fail)
                                continuation.yield(.content(response))
                                continuation.finish()
                                return
                            case .intervene(let msg):
                                memoryStore.addSystemAlert(msg, currentIteration: currentIteration)
                            case .proceed:
                                break
                            }

                            continuation.yield(.toolOutput(ToolOutput(toolName: toolName, output: observation, isSuccess: isSuccess)))

                            let isHeavy = observation.count > 300
                            let shortObs = isHeavy
                                ? "Observation (Trial \(trialNumber), Iter \(currentIteration)): '\(toolName)' executed."
                                : "Observation (Trial \(trialNumber), Iter \(currentIteration)): '\(toolName)' returned: \(observation)"

                            memoryStore.addObservation(
                                toolName: toolName,
                                shortObservation: shortObs,
                                heavyContent: isHeavy ? observation : nil,
                                isRequired: true
                            )

                        } // End inner cognitive loop

                        // ================================================================
                        // REFLECTION PHASE
                        // ================================================================

                        let trialOutcome = trialSummary.finalAgentThought ?? "Trial completed without explicit conclusion."
                        bestOutcome = trialOutcome

                        trialSummary.markComplete()

                        continuation.yield(.thought("Reflecting on trial \(trialNumber) result..."))

                        let reflectionOutcome = try await reflectionEvaluator.evaluate(
                            goal: input.userInput,
                            trialOutcome: trialOutcome,
                            observations: memoryStore.activeObservations,
                            trialNumber: trialNumber,
                            maxTrials: self.maxTrials,
                            model: model,
                            rateLimitCategory: input.rateLimitCategory
                        )

                        switch reflectionOutcome {
                        case .approved(let finalAnswer):
                            stateMutator.closeTrial(outcome: trialOutcome, reflection: "Approved.", verdict: .pass)
                            executionSummary.finalAgentThought = finalAnswer
                            executionSummary.markComplete()
                            continuation.yield(.thought("Reflection: Result approved."))
                            break trialLoop

                        case .retry(let reflection):
                            stateMutator.closeTrial(outcome: trialOutcome, reflection: reflection, verdict: .fail)
                            memoryStore.addReflection(reflection)
                            executionSummary = trialSummary // Track latest trial
                            continuation.yield(.thought("Reflection: \(reflection)\nRetrying..."))
                            continue trialLoop

                        case .budgetExhausted(let best):
                            stateMutator.closeTrial(outcome: trialOutcome, reflection: "Budget exhausted.", verdict: .partial)
                            executionSummary.finalAgentThought = best
                            executionSummary.markComplete()
                            continuation.yield(.thought("Trial budget exhausted. Using best result."))
                            break trialLoop
                        }

                    } // End trial loop

                    // ================================================================
                    // POST-LOOP: Synthesize Response
                    // ================================================================

                    if executionSummary.finalAgentThought == nil {
                        executionSummary.finalAgentThought = bestOutcome
                        executionSummary.markComplete()
                    }

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
                    logger.notice("Reflexion cancelled.")
                    await ExecutionSuspensionService.shared.cancel(for: input.conversationID)
                    stateMutator.markAsCancelled()
                    continuation.finish()
                } catch {
                    logger.error("Reflexion Fatal Error: \(error.localizedDescription)")
                    await ExecutionSuspensionService.shared.cancel(for: input.conversationID)
                    continuation.finish(throwing: error)
                }
            }

            continuation.onTermination = { @Sendable _ in task.cancel() }
        }
    }

    // MARK: - Helpers

    nonisolated private func extractPath(from params: [String: AnyCodable]) -> String? {
        if let val = params["path"],
           let data = try? JSONEncoder().encode(val),
           let str = String(data: data, encoding: .utf8) {
            return str.trimmingCharacters(in: CharacterSet(charactersIn: "\""))
        }
        return nil
    }
}
