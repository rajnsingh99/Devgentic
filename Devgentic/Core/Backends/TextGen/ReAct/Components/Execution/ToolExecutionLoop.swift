//
//  ToolExecutionLoop.swift
//  Devgentic
//
//  Shared parallel tool execution logic extracted from ReActAgentExecutor.
//  Used by all agent architectures (ReAct, Plan & Execute, Reflexion, Supervisor).
//

import Foundation
import OSLog

private let logger = DGLogger(category: "ToolExecutionLoop")

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

    // Emit the per-iteration reasoning trace UPFRONT so `EvaluationLogger`'s
    // iteration counter increments on every iteration — including ones that
    // exit via `final_answer`. The previous placement of this emission was
    // after dedup, which the `final_answer` early-return below skipped, causing
    // the executor-span summary to report N-1 iterations on clean exits.
    // We use `toolCalls.count` here (pre-dedup) since dedup hasn't run yet;
    // the separate "Deduped X → Y" log line further down preserves the dedup
    // observability for diagnostics.
    onTraceUpdate(AgentTraceLog(
        traceID: iterationSpan.traceID,
        spanID: iterationSpan.spanID,
        parentSpanID: iterationSpan.parentSpanID,
        stepNumber: currentIteration,
        state: .thinking(.reasoning),
        content: "Analyzing \(toolCalls.count) tool(s)...",
        metadata: ["iteration": "\(currentIteration)"]
    ))

    // --- Terminal Signal Fast-Path: final_answer wins ---
    // If the model called `final_answer`, it's signalling task completion.
    // Drop every other call in this iteration — the agent MUST only emit one
    // action in the closing step (enforced via the prompt's termination_contract).
    // This also prevents deadlocks where the model calls a read-only tool alongside
    // final_answer and ends up blocking on unrelated dispatch.
    if let finalCall = toolCalls.first(where: { $0.name == "final_answer" }) {
        let droppedCount = toolCalls.count - 1
        if droppedCount > 0 {
            let droppedNames = toolCalls.filter { $0.name != "final_answer" }.map(\.name).joined(separator: ", ")
            logger.warning("⚠️ final_answer called alongside \(droppedCount) other tool(s): [\(droppedNames)]. Dropping siblings — final_answer wins.")
        }
        return [try buildFinalAnswerObservation(
            call: finalCall,
            currentIteration: currentIteration,
            iterationSpan: iterationSpan,
            continuation: continuation,
            onTraceUpdate: onTraceUpdate
        )]
    }

    // --- Deduplicate ---
    let uniqueToolCalls = deduplicateToolCalls(toolCalls)
    logger.info("Deduped \(toolCalls.count) → \(uniqueToolCalls.count) unique tools.")

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
        continuation.yield(.requestClarification(
            question: question,
            operationID: operationID,
            options: AskUserInterceptor.extractOptions(arguments),
            multiline: AskUserInterceptor.extractMultiline(arguments)
        ))

        let userResponse = await ExecutionSuspensionService.shared.suspendForClarification(for: operationID, conversationID: conversationID)
        let didAnswer = userResponse != nil
        let answerText = userResponse ?? "System: The user skipped or did not respond."

        // Resolve the timeline chip: send = success, skip/timeout = cancelled (soft failure, no constraint).
        let askOutput = ToolOutput(
            toolName: toolName,
            params: paramsString,
            output: didAnswer ? "User answered: \(answerText)" : "Skipped by user.",
            isSuccess: didAnswer
        )
        if didAnswer {
            continuation.yield(.toolSucceeded(askOutput))
        } else {
            continuation.yield(.toolFailed(askOutput, category: .cancelled))
        }

        return ToolObservation(
            stepId: currentIteration,
            toolCallId: toolCallId,
            toolName: toolName,
            result: "User Response: \(answerText)",
            summary: "User Response: \(answerText)",
            isSuccess: didAnswer,
            params: question,
            output: "User Response: \(answerText)",
            artifacts: [],
            failureCategory: didAnswer ? nil : .cancelled
        )
    }

    // [HITL/A3] Default to the agent's arguments; replaced by user edits if the confirmation was edited.
    var effectiveArguments = arguments
    var effectiveParams = paramsString

    // Dispatch (handles HITL)
    let dispatchOutcome = toolMediator.prepareDispatch(
        toolName: toolName,
        arguments: arguments,
        availableTools: availableTools
    )

    switch dispatchOutcome {
    case .requiresConfirmation(let ps):
        // [HITL/Bug2] If the user already chose "Always allow" for this tool earlier in THIS run, skip
        // the banner. The live tool set (with requiresConfirmation) was resolved at stream start, so the
        // persisted profile flip only kicks in next run — the session allowlist covers the current one.
        if await SessionToolApprovals.shared.isAllowed(toolName: toolName, conversationID: conversationID) {
            logger.info("[HITL] '\(toolName)' auto-approved via session allowlist (Always allow earlier this run) — skipping banner.")
        } else {
            let operationID = UUID()
            continuation.yield(.requestConfirmation(toolName: toolName, params: ps, operationID: operationID))

            let approved = await ExecutionSuspensionService.shared.suspend(for: operationID, conversationID: conversationID)
            if approved, let edited = await ExecutionSuspensionService.shared.consumeEditedArguments(for: operationID) {
                // [HITL/A3] The user corrected the arguments in the banner — run with those.
                effectiveArguments = edited
                effectiveParams = serializeToolParams(edited)
            }
            if !approved {
                let denialResult = ToolExecutionResult.userDenied(toolName: toolName)
                let denialOutput = ToolOutput(toolName: toolName, params: paramsString, output: denialResult.llmObservation, isSuccess: false)
                continuation.yield(.toolFailed(denialOutput, category: .userDenied))
                return ToolObservation(
                    stepId: currentIteration,
                    toolCallId: toolCallId,
                    toolName: toolName,
                    result: denialResult.llmObservation,
                    summary: denialResult.llmObservation,
                    isSuccess: false,
                    params: paramsString,
                    output: denialResult.llmObservation,
                    artifacts: [],
                    failureCategory: .userDenied
                )
            }
        }
    case .executed, .userDenied:
        break
    }

    // Delegation lifecycle: wrap call_agent dispatch with structured events so the
    // UI surfaces "spawned an agent" / "agent returned" distinct from a normal tool call.
    let isDelegation = toolName == "call_agent"
    if isDelegation {
        let task = effectiveArguments["task"]?.stringValue ?? "unknown task"
        continuation.yield(.delegationStarted(task: task))
    }

    let dispatchStart = Date()
    let result = await toolMediator.executePreparedTool(
        toolName: toolName,
        arguments: effectiveArguments,
        availableTools: availableTools,
        parentContext: iterationSpan
    )
    let durationMs = Int(Date().timeIntervalSince(dispatchStart) * 1000)

    if isDelegation {
        let summary = result.isSuccess
            ? String(result.llmObservation.prefix(150))
            : "Delegation failed: \(String(result.llmObservation.prefix(120)))"
        continuation.yield(.delegationCompleted(summary: summary))
    }

    // Emit structured success/failure — category drives negativeConstraints policy and UI affordance.
    let output = ToolOutput(toolName: toolName, params: effectiveParams, output: result.llmObservation, isSuccess: result.isSuccess)
    if let category = result.failureCategory {
        continuation.yield(.toolFailed(output, category: category))
    } else {
        continuation.yield(.toolSucceeded(output, durationMs: durationMs))
    }

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
        artifacts: result.artifacts,
        failureCategory: result.failureCategory
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
    /// Connector words a truncated question commonly dangles on. Weak local models sometimes stop
    /// generating mid-sentence — emitting a value like "Could you please clarify what you mean by "
    /// (valid JSON, just unfinished). We trim these so the stem can be re-terminated as a real question.
    private static let danglingConnectors: Set<String> = [
        "by", "the", "a", "an", "your", "my", "with", "for", "about",
        "of", "to", "in", "on", "at", "as", "and", "or", "that"
    ]

    static func extractQuestion(toolName: String, arguments: [String: JSONValue]) -> String? {
        guard toolName == "ask_user" else { return nil }
        return sanitizeQuestion(arguments["question"]?.stringValue ?? "")
    }

    /// Repairs an empty or visibly-unfinished clarification question so the user never sees a dead-end
    /// prompt (e.g. "Could you please clarify what you mean by "). The model — not our parser — produces
    /// these; we recover by trimming dangling connectors and re-terminating, or substituting a complete
    /// fallback when nothing usable remains.
    static func sanitizeQuestion(_ raw: String) -> String {
        let fallback = "Could you clarify your request so I can continue?"
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return fallback }

        // Already a well-formed prompt (ends in terminal punctuation) — leave it untouched.
        if let last = text.last, "?.!".contains(last) { return text }

        // No terminal punctuation: strip trailing dangling connector words ("...mean by" → "...mean").
        var repaired = false
        while let lastWord = text.split(separator: " ").last.map(String.init),
              danglingConnectors.contains(lastWord.lowercased()) {
            text = String(text.dropLast(lastWord.count)).trimmingCharacters(in: .whitespacesAndNewlines)
            repaired = true
            if text.isEmpty { break }
        }

        guard !text.isEmpty else { return fallback }
        // If we removed a dangling tail, the remaining stem is a question — terminate it.
        return repaired ? text + "?" : text
    }

    /// A5: optional one-tap answer choices the agent supplied (nil if none). Blank/whitespace
    /// entries are dropped so they don't render as dead, inert chips.
    static func extractOptions(_ arguments: [String: JSONValue]) -> [String]? {
        let opts = arguments["options"]?.arrayValue?
            .compactMap { $0.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty } ?? []
        return opts.isEmpty ? nil : opts
    }

    /// A5: whether the agent expects a long / multi-line answer. Coerces the loose encodings weak
    /// models emit — bool `true`, string `"1"`/`"true"`/`"yes"`, or a non-zero number — not just `.bool`.
    static func extractMultiline(_ arguments: [String: JSONValue]) -> Bool {
        guard let value = arguments["multiline"] else { return false }
        if let b = value.boolValue { return b }
        if let s = value.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
            return ["1", "true", "yes", "y"].contains(s)
        }
        if let i = value.intValue { return i != 0 }
        return false
    }
}

// MARK: - final_answer Handling

/// Hard cap on final_answer length. 32K chars ≈ 8K tokens — well beyond any
/// reasonable user-facing response. Longer outputs indicate the model is
/// dumping raw tool output into `answer`, which should be summarized instead.
private let finalAnswerMaxChars = 32_000

/// Builds the terminal observation for a `final_answer` call. Validates the
/// payload; on invalid input returns a non-terminal failure observation so the
/// loop continues and the model can retry with a valid answer. On success,
/// returns a terminal observation that the executor breaks on.
private func buildFinalAnswerObservation(
    call: PendingToolCall,
    currentIteration: Int,
    iterationSpan: TraceContext,
    continuation: AsyncThrowingStream<AgentStreamEvent, Error>.Continuation,
    onTraceUpdate: @escaping @Sendable (AgentTraceLog) -> Void
) throws -> ToolObservation {

    let paramsString = serializeToolParams(call.arguments)

    // Accept common aliases models reach for when they forget the schema.
    let answerAliases = ["answer", "response", "content", "text", "message", "final_answer"]
    var rawAnswer: String = ""
    for key in answerAliases {
        if let value = call.arguments[key]?.stringValue, !value.isEmpty {
            rawAnswer = value
            break
        }
    }

    let trimmed = rawAnswer.trimmingCharacters(in: .whitespacesAndNewlines)

    // Emit standard UI events so the timeline shows the exit action.
    continuation.yield(.toolCall(name: "final_answer", params: paramsString))
    onTraceUpdate(AgentTraceLog(
        traceID: iterationSpan.traceID,
        spanID: iterationSpan.spanID,
        parentSpanID: iterationSpan.parentSpanID,
        stepNumber: currentIteration,
        state: .acting(.tool(name: "final_answer")),
        content: "Composing final answer...",
        metadata: ["tool_name": "final_answer"]
    ))

    // --- Validation: empty or whitespace ---
    // Don't terminate — return a non-terminal failure so the model retries.
    // This counts against maxIterations (per product decision #2).
    if trimmed.isEmpty {
        let errMsg = "ERROR: final_answer requires a non-empty 'answer' argument. Retry by calling final_answer again with your actual response content."
        let output = ToolOutput(toolName: "final_answer", params: paramsString, output: errMsg, isSuccess: false)
        continuation.yield(.toolFailed(output, category: .invalidArgs))
        logger.warning("final_answer called with empty answer — forcing retry.")
        return ToolObservation(
            stepId: currentIteration,
            toolCallId: call.id,
            toolName: "final_answer",
            result: errMsg,
            summary: "final_answer rejected: empty answer.",
            isSuccess: false,
            params: paramsString,
            output: errMsg,
            artifacts: [],
            isTerminalSignal: false,
            terminalKind: nil,
            failureCategory: .invalidArgs
        )
    }

    // --- Validation: over-long ---
    if trimmed.count > finalAnswerMaxChars {
        let errMsg = "ERROR: final_answer 'answer' exceeds \(finalAnswerMaxChars) chars (\(trimmed.count) received). Summarize instead of dumping raw tool output. Retry with a concise response."
        let output = ToolOutput(toolName: "final_answer", params: paramsString, output: errMsg, isSuccess: false)
        continuation.yield(.toolFailed(output, category: .invalidArgs))
        logger.warning("final_answer rejected — \(trimmed.count) chars exceeds cap of \(finalAnswerMaxChars).")
        return ToolObservation(
            stepId: currentIteration,
            toolCallId: call.id,
            toolName: "final_answer",
            result: errMsg,
            summary: "final_answer rejected: over cap.",
            isSuccess: false,
            params: paramsString,
            output: errMsg,
            artifacts: [],
            isTerminalSignal: false,
            terminalKind: nil,
            failureCategory: .invalidArgs
        )
    }

    // --- Success: terminal signal ---
    let successOutput = ToolOutput(
        toolName: "final_answer",
        params: paramsString,
        output: "Answer composed (\(trimmed.count) chars).",
        isSuccess: true
    )
    continuation.yield(.toolSucceeded(successOutput, durationMs: 0))
    onTraceUpdate(AgentTraceLog(
        traceID: iterationSpan.traceID,
        spanID: iterationSpan.spanID,
        parentSpanID: iterationSpan.parentSpanID,
        stepNumber: currentIteration,
        state: .thinking(.finalizing),
        content: "Final answer received — terminating loop.",
        metadata: ["tool_name": "final_answer", "answer_chars": "\(trimmed.count)"]
    ))

    logger.info("🏁 final_answer received (\(trimmed.count) chars). Loop will terminate.")

    return ToolObservation(
        stepId: currentIteration,
        toolCallId: call.id,
        toolName: "final_answer",
        result: trimmed,
        summary: "Final answer composed.",
        isSuccess: true,
        params: paramsString,
        output: trimmed,
        artifacts: [],
        isTerminalSignal: true,
        terminalKind: .finalAnswer
    )
}
