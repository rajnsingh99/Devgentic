//
//  ToolExecutionLoop.swift
//  Devgentic
//
//  Shared parallel tool execution logic extracted from ReActAgentExecutor.
//  Used by all agent architectures (ReAct, Plan & Execute, Reflexion, Supervisor).
//

import Foundation
import OSLog

private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "com.devgentic.app", category: "ToolExecutionLoop")

/// Deduplicates and executes a set of tool calls in parallel with HITL, ask_user interception,
/// tracing, and observation collection.
///
/// - Returns: An array of `ToolObservation` for each executed tool.
func executeToolCalls(
    toolCalls: [PendingToolCall],
    availableTools: [AgentTool],
    conversationID: UUID,
    currentIteration: Int,
    iterationSpan: TraceContext,
    toolMediator: ToolExecutionMediator,
    continuation: AsyncThrowingStream<AgentStreamEvent, Error>.Continuation,
    onTraceUpdate: @escaping @Sendable (AgentTraceLog) -> Void
) async throws -> [ToolObservation] {

    // --- Deduplicate ---
    var uniqueToolCalls: [PendingToolCall] = []
    var seenSignatures = Set<String>()

    for tool in toolCalls {
        let signature = "\(tool.name)|\(serializeToolParams(tool.arguments))"
        if !seenSignatures.contains(signature) {
            seenSignatures.insert(signature)
            uniqueToolCalls.append(tool)
        } else {
            logger.warning("⚠️ Dropped duplicate parallel tool call: \(tool.name)")
        }
    }

    logger.info("Deduped \(toolCalls.count) → \(uniqueToolCalls.count) unique tools.")

    onTraceUpdate(AgentTraceLog(
        traceID: iterationSpan.traceID,
        spanID: iterationSpan.spanID,
        parentSpanID: iterationSpan.parentSpanID,
        stepNumber: currentIteration,
        state: .thinking(.reasoning),
        content: "Analyzing \(uniqueToolCalls.count) tools...",
        metadata: ["iteration": "\(currentIteration)"]
    ))

    // --- Parallel Execution ---
    var observations: [ToolObservation] = []

    try await withThrowingTaskGroup(of: ToolObservation.self) { group in
        for tool in uniqueToolCalls {
            group.addTask {
                let toolName = tool.name
                let arguments = tool.arguments
                let paramsString = serializeToolParams(arguments)

                // Emit UI Event
                continuation.yield(.toolCall(name: toolName, params: paramsString))

                // Emit Trace Event
                onTraceUpdate(AgentTraceLog(
                    traceID: iterationSpan.traceID,
                    spanID: iterationSpan.spanID,
                    parentSpanID: iterationSpan.parentSpanID,
                    stepNumber: currentIteration,
                    state: .acting(.tool(name: toolName)),
                    content: "Executing '\(toolName)'...",
                    metadata: ["tool_name": toolName]
                ))

                // Intercept ask_user
                if toolName == "ask_user" {
                    let question = arguments["question"]?.stringValue ?? "Please provide clarification to proceed."
                    continuation.yield(.requestClarification(question: question))

                    let userResponse = await ExecutionSuspensionService.shared.suspendForClarification(for: conversationID)
                    let answerText = userResponse ?? "System: The user did not respond or the request timed out."

                    return ToolObservation(
                        stepId: currentIteration,
                        toolName: toolName,
                        result: "User Response: \(answerText)",
                        summary: "User Response: \(answerText)",
                        isSuccess: true,
                        params: "n/a",
                        output: "User Response: \(answerText)",
                        artifacts: []
                    )
                }

                // Dispatch (handles HITL)
                let dispatchOutcome = toolMediator.prepareDispatch(
                    toolName: toolName,
                    arguments: arguments,
                    availableTools: availableTools
                )

                switch dispatchOutcome {
                case .requiresConfirmation(let ps):
                    continuation.yield(.requestConfirmation(toolName: toolName, params: ps))
                    let approved = await ExecutionSuspensionService.shared.suspend(for: conversationID)
                    if !approved {
                        let denialResult = ToolExecutionResult.userDenied(toolName: toolName)
                        continuation.yield(.toolOutput(ToolOutput(toolName: toolName, output: denialResult.llmObservation, isSuccess: false)))
                        return ToolObservation(
                            stepId: currentIteration,
                            toolName: toolName,
                            result: denialResult.llmObservation,
                            summary: denialResult.llmObservation,
                            isSuccess: false,
                            params: paramsString,
                            output: denialResult.llmObservation,
                            artifacts: []
                        )
                    }
                case .executed, .userDenied:
                    break
                }

                let result = await toolMediator.executePreparedTool(
                    toolName: toolName,
                    arguments: arguments,
                    availableTools: availableTools,
                    parentContext: iterationSpan
                )

                // Emit UI Output
                continuation.yield(.toolOutput(ToolOutput(toolName: toolName, output: result.llmObservation, isSuccess: result.isSuccess)))

                // Emit media artifacts if produced
                for artifact in result.artifacts {
                    continuation.yield(.artifactProduced(artifact))
                }

                // Emit Trace Observation
                onTraceUpdate(AgentTraceLog(
                    traceID: iterationSpan.traceID,
                    spanID: iterationSpan.spanID,
                    parentSpanID: iterationSpan.parentSpanID,
                    stepNumber: currentIteration,
                    state: .thinking(.reflecting),
                    content: result.isSuccess ? "Tool '\(toolName)' succeeded." : "Tool '\(toolName)' failed.",
                    metadata: [
                        "tool_name": toolName,
                        "is_success": "\(result.isSuccess)",
                        "tool_params": paramsString,
                        "tool_output": result.llmObservation
                    ]
                ))

                return ToolObservation(
                    stepId: currentIteration,
                    toolName: toolName,
                    result: result.llmObservation,
                    summary: result.isSuccess ? "Tool '\(toolName)' executed successfully." : "Tool '\(toolName)' failed: \(result.llmObservation)",
                    isSuccess: result.isSuccess,
                    params: paramsString,
                    output: result.llmObservation,
                    artifacts: result.artifacts
                )
            }
        }

        for try await observation in group {
            observations.append(observation)
        }
    }

    let outcomesOverview = observations.map { "[\($0.toolName): \($0.summary)]" }.joined(separator: ", ")
    logger.debug("Executed \(observations.count) parallel outcomes: \(outcomesOverview)")

    return observations
}

// MARK: - Private Helpers

private func serializeToolParams(_ params: [String: JSONValue]) -> String {
    if let data = try? JSONEncoder().encode(params), let str = String(data: data, encoding: .utf8) { return str }
    return "{}"
}
