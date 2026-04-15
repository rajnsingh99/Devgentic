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

/// Deduplicates and executes a set of tool calls with HITL, ask_user interception,
/// tracing, and observation collection.
///
/// **Execution Strategy:**
/// - Autonomous tools (no user interaction required) run in parallel via TaskGroup.
/// - Interactive tools (`ask_user` or `requiresConfirmation`) run sequentially AFTER
///   autonomous tools complete, ensuring only one UI suspension banner is active at a time.
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
    let uniqueToolCalls = deduplicateToolCalls(toolCalls)
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

    // --- Partition: Interactive vs Autonomous ---
    // Interactive tools require human input (ask_user or HITL confirmation).
    // They must run sequentially to avoid UI deadlock (only one banner can show at a time).
    let toolLookup = Dictionary(uniqueKeysWithValues: availableTools.map { ($0.name, $0) })

    var autonomousTools: [PendingToolCall] = []
    var interactiveTools: [PendingToolCall] = []

    for tool in uniqueToolCalls {
        let isAskUser = tool.name == "ask_user"
        let requiresConfirmation = toolLookup[tool.name]?.requiresConfirmation ?? false

        if isAskUser || requiresConfirmation {
            interactiveTools.append(tool)
        } else {
            autonomousTools.append(tool)
        }
    }

    if !interactiveTools.isEmpty {
        logger.info("Partitioned tools: \(autonomousTools.count) autonomous (parallel), \(interactiveTools.count) interactive (sequential).")
    }

    var observations: [ToolObservation] = []

    // --- Phase 1: Run Autonomous Tools in Parallel ---
    if !autonomousTools.isEmpty {
        try await withThrowingTaskGroup(of: ToolObservation.self) { group in
            for tool in autonomousTools {
                group.addTask {
                    try await executeSingleTool(
                        tool: tool,
                        availableTools: availableTools,
                        conversationID: conversationID,
                        currentIteration: currentIteration,
                        iterationSpan: iterationSpan,
                        toolMediator: toolMediator,
                        continuation: continuation,
                        onTraceUpdate: onTraceUpdate
                    )
                }
            }

            for try await observation in group {
                observations.append(observation)
            }
        }
    }

    // --- Phase 2: Run Interactive Tools Sequentially ---
    // This ensures only ONE suspension banner is active at a time,
    // preventing the deadlock where the UI can't show two interactions simultaneously.
    for tool in interactiveTools {
        try Task.checkCancellation()

        let observation = try await executeSingleTool(
            tool: tool,
            availableTools: availableTools,
            conversationID: conversationID,
            currentIteration: currentIteration,
            iterationSpan: iterationSpan,
            toolMediator: toolMediator,
            continuation: continuation,
            onTraceUpdate: onTraceUpdate
        )
        observations.append(observation)
    }

    let outcomesOverview = observations.map { "[\($0.toolName): \($0.summary)]" }.joined(separator: ", ")
    logger.debug("Executed \(observations.count) parallel outcomes: \(outcomesOverview)")

    return observations
}

// MARK: - Single Tool Execution

/// Executes a single tool call with full event emission, ask_user interception,
/// HITL permission gating, tracing, and observation construction.
private func executeSingleTool(
    tool: PendingToolCall,
    availableTools: [AgentTool],
    conversationID: UUID,
    currentIteration: Int,
    iterationSpan: TraceContext,
    toolMediator: ToolExecutionMediator,
    continuation: AsyncThrowingStream<AgentStreamEvent, Error>.Continuation,
    onTraceUpdate: @escaping @Sendable (AgentTraceLog) -> Void
) async throws -> ToolObservation {

    let toolCallId = tool.id
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
    if let question = AskUserInterceptor.extractQuestion(toolName: toolName, arguments: arguments) {
        let operationID = UUID()
        continuation.yield(.requestClarification(question: question, operationID: operationID))

        let userResponse = await ExecutionSuspensionService.shared.suspendForClarification(for: operationID, conversationID: conversationID)
        let didAnswer = userResponse != nil
        let answerText = userResponse ?? "System: The user skipped or did not respond."

        // Resolve the timeline chip: send = success, skip/timeout = failure
        continuation.yield(.toolOutput(ToolOutput(
            toolName: toolName,
            params: paramsString,
            output: didAnswer ? "User answered: \(answerText)" : "Skipped by user.",
            isSuccess: didAnswer
        )))

        return ToolObservation(
            stepId: currentIteration,
            toolCallId: toolCallId,
            toolName: toolName,
            result: "User Response: \(answerText)",
            summary: "User Response: \(answerText)",
            isSuccess: didAnswer,
            params: question,
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
        let operationID = UUID()
        continuation.yield(.requestConfirmation(toolName: toolName, params: ps, operationID: operationID))

        let approved = await ExecutionSuspensionService.shared.suspend(for: operationID, conversationID: conversationID)
        if !approved {
            let denialResult = ToolExecutionResult.userDenied(toolName: toolName)
            continuation.yield(.toolOutput(ToolOutput(toolName: toolName, params: paramsString, output: denialResult.llmObservation, isSuccess: false)))
            return ToolObservation(
                stepId: currentIteration,
                toolCallId: toolCallId,
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
    continuation.yield(.toolOutput(ToolOutput(toolName: toolName, params: paramsString, output: result.llmObservation, isSuccess: result.isSuccess)))

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
        toolCallId: toolCallId,
        toolName: toolName,
        result: result.llmObservation,
        summary: result.isSuccess ? "Tool '\(toolName)' executed successfully." : "Tool '\(toolName)' failed: \(result.llmObservation)",
        isSuccess: result.isSuccess,
        params: paramsString,
        output: result.llmObservation,
        artifacts: result.artifacts
    )
}

// MARK: - Testable Helpers

func deduplicateToolCalls(_ toolCalls: [PendingToolCall]) -> [PendingToolCall] {
    // Phase 1: Exact dedup — remove calls with identical name + serialized params.
    var exactUnique: [PendingToolCall] = []
    var seen = Set<String>()
    for tool in toolCalls {
        let signature = "\(tool.name)|\(serializeToolParams(tool.arguments))"
        if !seen.contains(signature) {
            seen.insert(signature)
            exactUnique.append(tool)
        }
    }

    // Phase 2: Semantic dedup — for destructive/write operations targeting the same
    // file path, keep only the LAST call (most recent intent). This prevents the
    // model from flooding the HITL queue with near-identical write_file calls that
    // differ only in whitespace (e.g., "\nHello" vs "\nHello\n" vs "Hello\n").
    let destructiveTools: Set<String> = ["write_file", "delete_file", "move_file", "copy_file"]
    var pathLastIndex: [String: Int] = [:]  // "tool|path" → last index in exactUnique

    for (index, tool) in exactUnique.enumerated() {
        guard destructiveTools.contains(tool.name) else { continue }
        let normalized = normalizePathArguments(tool.arguments)
        guard let pathValue = normalized["path"] ?? normalized["source"] ?? normalized["destination"],
              case .string(let path) = pathValue else { continue }
        let key = "\(tool.name)|\(path)"
        pathLastIndex[key] = index
    }

    // If no destructive duplicates found, skip Phase 2
    guard !pathLastIndex.isEmpty else { return exactUnique }

    // Build set of indices to drop (earlier calls to same tool+path)
    var indicesToKeep = Set(exactUnique.indices)
    var seenPaths: [String: [Int]] = [:]

    for (index, tool) in exactUnique.enumerated() {
        guard destructiveTools.contains(tool.name) else { continue }
        let normalized = normalizePathArguments(tool.arguments)
        guard let pathValue = normalized["path"] ?? normalized["source"] ?? normalized["destination"],
              case .string(let path) = pathValue else { continue }
        let key = "\(tool.name)|\(path)"
        seenPaths[key, default: []].append(index)
    }

    for (_, indices) in seenPaths where indices.count > 1 {
        // Keep only the last one, drop earlier calls
        for i in indices.dropLast() {
            indicesToKeep.remove(i)
        }
    }

    if indicesToKeep.count < exactUnique.count {
        let dropped = exactUnique.count - indicesToKeep.count
        logger.info("🔀 Semantic dedup: collapsed \(dropped) earlier write(s) to same path, keeping last intent.")
    }

    return exactUnique.enumerated().compactMap { indicesToKeep.contains($0.offset) ? $0.element : nil }
}

func serializeToolParams(_ params: [String: JSONValue]) -> String {
    let normalized = normalizePathArguments(params)
    if let data = try? JSONEncoder().encode(normalized), let str = String(data: data, encoding: .utf8) { return str }
    return "{}"
}

/// Normalizes filesystem path arguments to canonical form so that
/// `/Users/alice/Acme/` and `/Users/alice/Acme` produce identical
/// signatures for deduplication and circuit-breaker fingerprinting.
///
/// Handles: trailing slashes, tilde expansion, `.` / `..` segments, doubled slashes.
func normalizePathArguments(_ params: [String: JSONValue]) -> [String: JSONValue] {
    params.mapValues { value in
        guard case .string(let str) = value,
              str.hasPrefix("/") || str.hasPrefix("~") || str.hasPrefix("./") else {
            return value
        }
        var normalized = str
        // Strip trailing slash (unless root "/")
        if normalized.count > 1 && normalized.hasSuffix("/") {
            normalized = String(normalized.dropLast())
        }
        // Expand tilde
        normalized = (normalized as NSString).expandingTildeInPath
        // Resolve . and .. components, collapse double slashes
        normalized = (normalized as NSString).standardizingPath
        return .string(normalized)
    }
}

struct AskUserInterceptor {
    static func extractQuestion(toolName: String, arguments: [String: JSONValue]) -> String? {
        guard toolName == "ask_user" else { return nil }
        return arguments["question"]?.stringValue ?? "Please provide clarification to proceed."
    }
}
