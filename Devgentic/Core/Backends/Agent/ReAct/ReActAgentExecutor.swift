//
//  ReActAgentExecutor.swift
//  Devgentic
//
//  Created by Raj Singh on 28/01/26.
//  Updated: Phase 5 - Modular Orchestrator Refactoring
//

import Foundation
import OSLog

private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "com.devgentic.app", category: "ReActExecutor")
private let logState = Logger(subsystem: Bundle.main.bundleIdentifier ?? "com.devgentic.app", category: "State")
private let logToolExecution = Logger(subsystem: Bundle.main.bundleIdentifier ?? "com.devgentic.app", category: "ToolExecution")

// MARK: - Executor Implementation

/// A robust implementation of the ReAct (Reasoning + Acting) paradigm.
/// Features a Split-State architecture (RAM vs. Disk) and structured cognitive steps.
/// This acts as a pure Orchestrator, delegating state, safety, and execution to pluggable components.
actor ReActAgentExecutor: Executor {
    
    // MARK: - Properties
    
    nonisolated let architecture: AgentArchitecture = .reAct
    nonisolated private let maxIterations: Int
    
    // MARK: - Initialization
    
    init(maxIterations: Int = 15) {
        self.maxIterations = maxIterations
    }
    
    // MARK: - Execution Entry Point
    
    nonisolated func execute(
        model: any LLMProvider,
        input: AgentInput,
        onTraceUpdate: @escaping @Sendable (AgentTraceLog) -> Void
    ) -> AsyncThrowingStream<AgentStreamEvent, Error> {
        
        return AsyncThrowingStream<AgentStreamEvent, Error> { continuation in
            let task = Task {
                
                // --- Phase 2: State Component ---
                // Initialized here so it is accessible in the cancellation/catch blocks
                var stateMutator = EpisodeStateMutator(conversationID: input.conversationID, initialState: input.activeState)
                
                do {
                    logger.info("🚀 ReAct Execution Initiated. Model Instance: \(String(describing: model))")
                    
                    let spyModel = APISpyModel(inner: model, logger: logger)
                    
                    var currentIteration = 0
                    var latestClarification: String? = nil
                    var executionSummary = ExecutionSummary(originalGoal: input.userInput)
                    let executionTrace = input.traceContext
                    
                    // --- Load Pluggable Components (Phases 2-4) ---
                    var memoryStore = ObservationMemoryStore()
                    var circuitBreaker = CognitiveCircuitBreaker()
                    var retryStrategy = LLMRetryStrategy()
                    let toolMediator = ToolExecutionMediator()
                    let terminationEvaluator = EpisodeTerminationEvaluator()
                    
                    // --- Start Episode ---
                    stateMutator.startNewEpisode(goal: input.userInput)
                    
                    // MARK: - Cognitive Loop
                    cognitiveLoop: while currentIteration < self.maxIterations {
                        try Task.checkCancellation()
                        currentIteration += 1
                        
                        // --- Rate Limit Check ---
                        let projectedWait = await GlobalRateLimiter.shared.timeUntilNextToken(for: input.rateLimitCategory)
                        if projectedWait > 1.5 {
                            logger.warning("Rate limit approaching. Throttling for \(Int(projectedWait))s.")
                            let waitMsg = "Throttling for \(Int(projectedWait))s to respect \(input.rateLimitCategory) limits..."
                            continuation.yield(.thought(waitMsg))
                            onTraceUpdate(AgentTraceLog(
                                traceID: executionTrace.traceID,
                                spanID: executionTrace.newSpan().spanID,
                                parentSpanID: executionTrace.parentSpanID,
                                stepNumber: currentIteration,
                                state: .thinking,
                                content: waitMsg
                            ))
                        }
                        
                        await GlobalRateLimiter.shared.wait(for: input.rateLimitCategory)
                        
                        let iterationSpan = executionTrace.newSpan()
                        var iterationMetadata: [String: String] = ["iteration": "\(currentIteration)"]
                        
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
                            compressedStateGraph: stateMutator.currentState.compressForPrompt(),
                            recentHistory: input.recentHistory,
                            originalQuery: input.userInput,
                            currentIteration: currentIteration,
                            activeObservations: memoryStore.activeObservations,
                            latestClarification: latestClarification,
                            negativeConstraints: stateMutator.currentConstraints,
                            hallucinatedTools: circuitBreaker.hallucinatedTools,
                            availableTools: input.tools
                        )
                        
                        logState.debug("SemanticContext Assembled. Compressed Graph Length: \(context.compressedStateGraph.count) chars.")
                        
                        try Task.checkCancellation()

                        // --- Structured Generation ---
                        let step: LeanCognitiveStep
                        do {
                            logger.info("⚡️ Invoking Strategy.generate (Attempt: \(retryStrategy.consecutiveRetries + 1))")
                            step = try await input.generatorStrategy.generate(
                                model: spyModel,
                                context: context,
                                iteration: currentIteration
                            )
                            retryStrategy.resetParseFailures()
                            
                        } catch {
                            // --- Error Retry Handling (Phase 3 Component) ---
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
                                continuation.yield(.thought("⚠️ Error: Invalid JSON output. Retrying (\(attemptCount)/\(maxAttempts))..."))
                                await GlobalRateLimiter.shared.wait(for: input.rateLimitCategory)
                                continue cognitiveLoop
                                
                            case .abort(let reason):
                                stateMutator.forceCloseActiveEpisode(status: "FAILED", outcome: reason)
                                continuation.yield(.content(reason))
                                continuation.finish()
                                return
                            }
                        }
                        
                        // --- Pre-Execution Setup ---
                        memoryStore.resetObservationFlags()
                        continuation.yield(.thought(step.content))
                        
                        // --- Termination Evaluation (Phase 4 Component) ---
                        let termStatus = terminationEvaluator.evaluate(step: step, currentIteration: currentIteration, maxIterations: self.maxIterations)
                        switch termStatus {
                        case .maxIterationsReached:
                            break // Handled natively by the while-loop condition
                        case .completed(let finalThought):
                            executionSummary.finalAgentThought = finalThought
                            break cognitiveLoop
                        case .proceed:
                            break
                        }
                        
                        guard let toolName = step.toolName else { break cognitiveLoop }
                        let arguments = step.arguments ?? [:]

                        onTraceUpdate(AgentTraceLog(
                            traceID: iterationSpan.traceID,
                            spanID: iterationSpan.spanID,
                            parentSpanID: iterationSpan.parentSpanID,
                            stepNumber: currentIteration,
                            state: .thinking,
                            content: "Analyzing...",
                            metadata: iterationMetadata
                        ))
                        
                        iterationMetadata["tool_name"] = toolName

                        // --- Handle User Clarification ---
                        if toolName == "ask_user" {
                            let cbAction = circuitBreaker.evaluateAskUser()
                            switch cbAction {
                            case .abort(let reason):
                                executionSummary.markComplete(failureReason: reason)
                                let response = await ResponseSynthesizer.synthesize(summary: executionSummary, model: model, personaInstructions: input.instructions, originalQuery: input.userInput)
                                stateMutator.forceCloseActiveEpisode(status: "FAILED", outcome: response)
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

                            onTraceUpdate(AgentTraceLog(
                                traceID: iterationSpan.traceID,
                                spanID: iterationSpan.spanID,
                                parentSpanID: iterationSpan.parentSpanID,
                                stepNumber: currentIteration,
                                state: .requestingPermission,
                                content: "Waiting for user clarification: \(question)"
                            ))

                            let userResponse = await ExecutionSuspensionService.shared.suspendForClarification(for: input.conversationID)
                            let paramsStr = "{\"question\": \"\(question)\"}"

                            if let response = userResponse, !response.isEmpty {
                                let lower = response.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                                let terminalPhrases = ["stop", "cancel", "no", "leave it", "abort", "quit", "exit"]
                                let isTerminal = terminalPhrases.contains { lower == $0 || lower.hasPrefix($0) || lower.hasPrefix("no,") }
                                
                                if isTerminal {
                                    let msg = "Task cancelled as requested."
                                    executionSummary.record(toolName: "ask_user", params: paramsStr, output: "User aborted task.", isSuccess: false)
                                    executionSummary.markComplete(failureReason: "User manually cancelled the task.")
                                    stateMutator.forceCloseActiveEpisode(status: "CANCELLED", outcome: msg)
                                    continuation.yield(.content(msg))
                                    continuation.finish()
                                    return
                                }
                                
                                let isVague = response.count < 15
                                let clarifyAction = circuitBreaker.recordClarificationResponse(isVague: isVague)
                                
                                if case .intervene(let sysMsg) = clarifyAction {
                                    memoryStore.addSystemAlert(sysMsg, currentIteration: currentIteration)
                                    executionSummary.record(toolName: "ask_user", params: paramsStr, output: sysMsg, isSuccess: false)
                                    continuation.yield(.toolOutput(ToolOutput(toolName: "ask_user", output: sysMsg, isSuccess: false)))
                                } else {
                                    latestClarification = "You asked: \"\(question)\"\nUser responded: \"\(response)\""
                                    memoryStore.addObservation(
                                        toolName: "ask_user",
                                        shortObservation: "Observation (Step \(currentIteration)): [Question: \(question)] -> User Response: \(response)",
                                        heavyContent: nil,
                                        isRequired: true
                                    )
                                    executionSummary.record(toolName: "ask_user", params: paramsStr, output: response, isSuccess: true)
                                    continuation.yield(.toolOutput(ToolOutput(toolName: "ask_user", output: response, isSuccess: true)))
                                }
                            } else {
                                let observation = "User did not provide a response. Proceed with your best judgment/tool or return tool_name: null."
                                memoryStore.addSystemAlert(observation, currentIteration: currentIteration)
                                executionSummary.record(toolName: "ask_user", params: paramsStr, output: observation, isSuccess: false)
                                continuation.yield(.toolOutput(ToolOutput(toolName: "ask_user", output: observation, isSuccess: false)))
                            }
                            continue cognitiveLoop
                        }

                        // --- Handle Memory Hydration ---
                        if toolName == ScratchpadTool.name {
                            let hydrateAction = circuitBreaker.evaluateMemoryHydration()
                            if case .abort(let reason) = hydrateAction {
                                executionSummary.markComplete(failureReason: reason)
                                let response = await ResponseSynthesizer.synthesize(summary: executionSummary, model: model, personaInstructions: input.instructions, originalQuery: input.userInput)
                                stateMutator.forceCloseActiveEpisode(status: "FAILED", outcome: response)
                                continuation.yield(.content(response))
                                continuation.finish()
                                return
                            }
                            
                            let targetIds = ScratchpadTool.extractStepIDs(from: arguments)
                            let paramsStr = self.serializeParams(arguments)
                            
                            if targetIds.isEmpty {
                                let msg = "System Error: scratchpad_tool requires a 'step_ids' array of integers."
                                memoryStore.addSystemAlert(msg, currentIteration: currentIteration)
                                executionSummary.record(toolName: ScratchpadTool.name, params: paramsStr, output: msg, isSuccess: false)
                                continuation.yield(.toolOutput(ToolOutput(toolName: ScratchpadTool.name, output: msg, isSuccess: false)))
                            } else {
                                let result = memoryStore.hydrateObservations(targetIds: targetIds, currentIteration: currentIteration)
                                executionSummary.record(toolName: ScratchpadTool.name, params: paramsStr, output: result.msg, isSuccess: true)
                                continuation.yield(.toolOutput(ToolOutput(toolName: ScratchpadTool.name, output: result.msg, isSuccess: true)))
                            }
                            continue cognitiveLoop
                        }

                        // --- Validate Arguments ---
                        if let toolDef = input.tools.first(where: { $0.name == toolName }),
                           !toolDef.parameters.required.isEmpty,
                           arguments.isEmpty {
                            let requiredKeys = toolDef.parameters.required.joined(separator: ", ")
                            let msg = "System Error: Tool '\(toolName)' requires parameters [\(requiredKeys)] but received an empty arguments object {}. You MUST include an 'arguments' key in your JSON with the required parameters."
                            memoryStore.addSystemAlert(msg, currentIteration: currentIteration)
                            logger.warning("⚠️ Argument validation failed for '\(toolName)': empty arguments, requires [\(requiredKeys)]")
                            continuation.yield(.thought("⚠️ Missing required arguments for \(toolName). Retrying..."))
                            continue cognitiveLoop
                        }

                        // --- Ghost Protocol Check ---
                        if let path = self.extractPath(from: arguments), stateMutator.currentState.isPathForbidden(path) {
                            let violationMsg = "🚫 GHOST PROTOCOL: Access to '\(path)' is FORBIDDEN by Negative Constraints. Do not retry this path."
                            memoryStore.addSystemAlert(violationMsg, currentIteration: currentIteration)
                            continuation.yield(.thought(violationMsg))
                            continue cognitiveLoop
                        }

                        // --- Ensure Tool Exists ---
                        let allAvailableTools = input.tools.map { $0.name } + [ScratchpadTool.name, "ask_user"]
                        if !allAvailableTools.contains(toolName) {
                            let msg = "System Error: Tool '\(toolName)' does not exist. Choose a valid tool or return tool_name: null."
                            memoryStore.addSystemAlert(msg, currentIteration: currentIteration)
                            continuation.yield(.thought(msg))
                            continue cognitiveLoop
                        }

                        // --- HITL Preparation ---
                        let dispatchOutcome = toolMediator.prepareDispatch(toolName: toolName, arguments: arguments, availableTools: input.tools)
                        let paramsString: String
                        
                        switch dispatchOutcome {
                        case .requiresConfirmation(let ps):
                            paramsString = ps
                            continuation.yield(.requestConfirmation(toolName: toolName, params: paramsString))
                            onTraceUpdate(AgentTraceLog(
                                traceID: iterationSpan.traceID,
                                spanID: iterationSpan.spanID,
                                parentSpanID: iterationSpan.parentSpanID,
                                stepNumber: currentIteration,
                                state: .requestingPermission,
                                content: "Waiting for user approval: \(toolName)"
                            ))
                            
                            let approved = await ExecutionSuspensionService.shared.suspend(for: input.conversationID)
                            if !approved {
                                let denialResult = ToolExecutionResult.userDenied(toolName: toolName)
                                memoryStore.addSystemAlert(denialResult.llmObservation, currentIteration: currentIteration)
                                executionSummary.record(toolName: toolName, params: paramsString, output: denialResult.llmObservation, isSuccess: false)
                                continuation.yield(.toolOutput(ToolOutput(toolName: toolName, output: denialResult.llmObservation, isSuccess: false)))
                                continue cognitiveLoop
                            }
                        case .executed(_, let ps):
                            paramsString = ps
                        case .userDenied(_, let ps):
                            paramsString = ps
                        }
                        
                        // User allowed execution, reset clarification/idle counters
                        circuitBreaker.resetCountersOnSuccess()

                        // --- Circuit Breaker Tool Loop Check ---
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
                            content: "Executing \(toolName)...",
                            metadata: iterationMetadata
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
                        
                        // --- Process Execution Side-Effects ---
                        switch executionResult {
                        case .success, .userDenied:
                            break
                        case .hallucinated(let tName, _):
                            circuitBreaker.recordHallucination(tName)
                        case .timedOut, .semanticFailure, .systemError:
                            if let path = self.extractPath(from: arguments) {
                                stateMutator.addNegativeConstraint(path)
                            }
                            let violationMsg = "Tool '\(toolName)' failed. If this is due to an unsupported file format (e.g., binary .docx) or missing command, DO NOT ask the user for workarounds. Return tool_name: null immediately."
                            memoryStore.addSystemAlert(violationMsg, currentIteration: currentIteration)
                        }

                        // --- Verify Consecutive Failures ---
                        let resultAction = circuitBreaker.recordToolResult(isSuccess: isSuccess)
                        switch resultAction {
                        case .abort(let reason):
                            executionSummary.markComplete(failureReason: reason)
                            let response = await ResponseSynthesizer.synthesize(summary: executionSummary, model: model, personaInstructions: input.instructions, originalQuery: input.userInput)
                            stateMutator.forceCloseActiveEpisode(status: "FAILED", outcome: response)
                            continuation.yield(.content(response))
                            continuation.finish()
                            return
                        case .intervene(let msg):
                            memoryStore.addSystemAlert(msg, currentIteration: currentIteration)
                        case .proceed:
                            break
                        }
                        
                        continuation.yield(.toolOutput(ToolOutput(toolName: toolName, output: observation, isSuccess: isSuccess)))
                        iterationMetadata["tool_success"] = String(isSuccess)
                        onTraceUpdate(AgentTraceLog(
                            traceID: iterationSpan.traceID,
                            spanID: iterationSpan.spanID,
                            parentSpanID: iterationSpan.parentSpanID,
                            stepNumber: currentIteration,
                            state: .observing,
                            content: observation,
                            metadata: iterationMetadata
                        ))
                        
                        let isHeavy = observation.count > 300
                        let shortObs = isHeavy ? "Observation (Step \(currentIteration)): '\(toolName)' executed. [ scratchpad_tool $\((memoryStore.activeObservations.last?.stepId ?? 0) + 1) ]" : "Observation (Step \(currentIteration)): Tool '\(toolName)' returned: \(observation)"
                        
                        memoryStore.addObservation(
                            toolName: toolName,
                            shortObservation: shortObs,
                            heavyContent: isHeavy ? observation : nil,
                            isRequired: true
                        )
                        
                    } // End While Loop
                    
                    // --- Post-Loop Handoff ---
                    let exitStatus = (currentIteration >= self.maxIterations) ? "FAILED" : "COMPLETED"
                    
                    if exitStatus == "FAILED" {
                        executionSummary.markComplete(failureReason: "Reached maximum allowed steps (\(maxIterations)) without completion.")
                    } else {
                        executionSummary.markComplete()
                    }

                    let response = await ResponseSynthesizer.synthesize(
                        summary: executionSummary,
                        model: model,
                        personaInstructions: input.instructions,
                        originalQuery: input.userInput,
                        isNativeFlow: input.generatorStrategy is NativeStructuredGenerator
                    )
                    
                    stateMutator.forceCloseActiveEpisode(status: exitStatus, outcome: response)
                    
                    let finalSpan = input.traceContext.newSpan()
                    onTraceUpdate(AgentTraceLog(
                        traceID: finalSpan.traceID,
                        spanID: finalSpan.spanID,
                        parentSpanID: finalSpan.parentSpanID,
                        stepNumber: currentIteration,
                        state: .finalizing,
                        content: exitStatus == "COMPLETED" ? "Task completed successfully." : "Task failed or reached max iterations."
                    ))
                    
                    continuation.yield(.content(response))
                    continuation.finish()
                    
                } catch is CancellationError {
                    logger.notice("🚫 Execution Task Cancelled cleanly.")
                    await ExecutionSuspensionService.shared.cancel(for: input.conversationID)
                    stateMutator.markAsCancelled()
                    continuation.finish()
                } catch {
                    logger.error("ReAct Fatal Error: \(error.localizedDescription)")
                    await ExecutionSuspensionService.shared.cancel(for: input.conversationID)
                    continuation.finish(throwing: error)
                }
            }
            
            continuation.onTermination = { @Sendable _ in task.cancel() }
        }
    }
    
    // MARK: - Local Helpers
    
    nonisolated private func serializeParams(_ params: [String: AnyCodable]) -> String {
        if let data = try? JSONEncoder().encode(params), let str = String(data: data, encoding: .utf8) { return str }
        return "{}"
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

// MARK: - Internal Models

private struct APISpyModel: LLMProvider {
    let inner: any LLMProvider
    let logger: Logger

    func generate(messages: [[String: String]], tools: [[String: Any]]?, responseSchema: [String: Any]?) async throws -> String {
        return try await inner.generate(messages: messages, tools: tools, responseSchema: responseSchema)
    }

    func stream(messages: [[String: String]], tools: [[String: Any]]?) -> AsyncThrowingStream<String, Error> {
        return inner.stream(messages: messages, tools: tools)
    }
}
