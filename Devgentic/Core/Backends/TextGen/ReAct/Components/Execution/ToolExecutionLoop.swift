// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
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
    interactionMemory: RunInteractionMemory,
    continuation: AsyncThrowingStream<AgentStreamEvent, Error>.Continuation,
    /// Workflow node this run belongs to, or nil for chat/code. Scopes the "Allow for this chat"
    /// allowlist so a grant in one node does not answer for another — see `SessionToolApprovals`.
    approvalNodeID: UUID? = nil,
    /// [WF-SE6/SE11] The workflow node's EXPLICIT unattended-approval setting; false for
    /// chat/code and for nodes without it. Only consulted when the run is unattended.
    unattendedAutoApprove: Bool = false,
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
                        interactionMemory: interactionMemory,
                        continuation: continuation,
                        approvalNodeID: approvalNodeID,
                        unattendedAutoApprove: unattendedAutoApprove,
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
            interactionMemory: interactionMemory,
            continuation: continuation,
            approvalNodeID: approvalNodeID,
            unattendedAutoApprove: unattendedAutoApprove,
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
    interactionMemory: RunInteractionMemory,
    continuation: AsyncThrowingStream<AgentStreamEvent, Error>.Continuation,
    /// Workflow node this run belongs to, or nil for chat/code — scopes the approval allowlist.
    approvalNodeID: UUID?,
    /// [WF-SE6/SE11] see the outer overload.
    unattendedAutoApprove: Bool,
    onTraceUpdate: @escaping @Sendable (AgentTraceLog) -> Void
) async throws -> ToolObservation {

    let toolCallId = tool.id
    let toolName = tool.name
    let arguments = tool.arguments
    let paramsString = serializeToolParams(arguments)

    // Emit UI Event
    continuation.yield(.toolCall(name: toolName, params: paramsString, stepId: currentIteration))

    // Emit Trace Event
    onTraceUpdate(AgentTraceLog(
        traceID: iterationSpan.traceID,
        spanID: iterationSpan.spanID,
        parentSpanID: iterationSpan.parentSpanID,
        stepNumber: currentIteration,
        state: .acting(.tool(name: toolName)),
        content: "Executing '\(toolName)'...",
        // `tool_params` rides along like the result record below already does (:~430) — the
        // .toolCall span event used to carry only the NAME, so the report could show that a
        // tool ran but not what it was asked to do until the result landed.
        metadata: ["tool_name": toolName, "tool_params": paramsString]
    ))

    // Intercept ask_user
    if let question = AskUserInterceptor.extractQuestion(toolName: toolName, arguments: arguments) {
        // [Loop Safety] Identical re-ask → replay the earlier response instead of re-raising
        // the banner. A human's answer (or skip) stands for the run. The replayed observation
        // is byte-identical to the original, so a stuck ask-loop becomes deterministic and the
        // repetition fingerprint's normal warn → stop ladder governs it.
        if let stored = await interactionMemory.storedResponse(forQuestion: question) {
            logger.info("[LoopSafety] 'ask_user' repeated an identical question — replaying the earlier response, no banner.")
            continuation.yield(.thought("↩️ Repeated question — replaying your earlier response."))
            let didAnswer = stored != nil
            let answerText = stored ?? "System: The user skipped or did not respond."
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

        // [WF-SE11] The closest twin of the confirmation refusal below — same function, and the
        // shape most likely to hit it: `AskUserTool` is appended to EVERY agent profile
        // (AgentConnect: `wrapTool(AskUserTool(...), requiresConfirmation: false)`), so a scheduled
        // run is one model decision away from an indefinite park. `suspendForClarification` is
        // unbounded by contract ("Indefinite — container owns the deadline"), so with nobody
        // reachable it only ever ended one way: the 600s deadline killing the whole run.
        //
        // ⚠️ The confirmation arm's remedy ("turn off Ask-first for this tool") CANNOT apply here —
        // ask_user is wrapped `requiresConfirmation: false` and never reaches the Tool Library
        // gate — so refusing with the existing skip observation is the only honest option. That
        // observation already has a defined meaning downstream ("the user skipped or did not
        // respond"), which is exactly what happened.
        if !WorkflowRunAttendance.canReachAHuman {
            let skipText = "System: No one is available to answer (this run is unattended). Proceed with reasonable assumptions, or stop and report what you need."
            logger.error("[HITL] ask_user REFUSED — nobody can answer this run (scheduled), question: \(String(question.prefix(120))). CONSEQUENCE: the agent is told immediately that no answer is coming and continues on assumptions, instead of parking indefinitely until the run deadline cancels everything.")
            // ⚠️ Found on adversarial audit: this arm returned the ToolObservation WITHOUT ever
            // closing the `.toolCall` row opened above — the timeline showed the step as
            // perpetually running (or, once a run-end settle pass closes dangling rows, as an
            // "Interrupted" failure) for a run that actually completed cleanly on its own
            // assumptions. Mirrors the identical-re-ask replay arm just above, which correctly
            // closes its own `.toolCall` with a terminal event before returning.
            let askOutput = ToolOutput(toolName: toolName, params: paramsString, output: skipText, isSuccess: true)
            continuation.yield(.toolSucceeded(askOutput))
            return ToolObservation(
                stepId: currentIteration,
                toolCallId: toolCallId,
                toolName: toolName,
                result: skipText,
                summary: skipText,
                isSuccess: true,
                params: paramsString,
                output: skipText,
                artifacts: [],
                failureCategory: nil
            )
        }

        let operationID = UUID()
        continuation.yield(.requestClarification(
            question: question,
            operationID: operationID,
            options: AskUserInterceptor.extractOptions(arguments),
            multiline: AskUserInterceptor.extractMultiline(arguments)
        ))

        let userResponse = await ExecutionSuspensionService.shared.suspendForClarification(for: operationID, conversationID: conversationID, nodeID: approvalNodeID)

        // ⚠️ The `ask_user` twin of the permission check above. A cancelled clarification resolves
        // `nil`, which this path reads as "the user skipped or did not respond" — it records that
        // non-answer in `RunInteractionMemory` so an identical re-ask REPLAYS the fabricated skip,
        // and yields `.toolFailed(… .cancelled)` for a question the user was never given the chance
        // to answer. Checked BEFORE `recordAnswer` so nothing is written.
        if Task.isCancelled { throw CancellationError() }

        // [Loop Safety] Remember the response (or skip) so an identical re-ask replays it.
        await interactionMemory.recordAnswer(question: question, response: userResponse)
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
        // [HITL] If the user chose "Allow for this chat" for this tool, skip the banner. The
        // allowlist is durable (survives runs + app restarts) and never touches the shared
        // profile, so the grant can't leak to other conversations — and inside a workflow it is
        // scoped to `approvalNodeID`, so it can't leak to another NODE of the same run either.
        if await SessionToolApprovals.shared.isAllowed(toolName: toolName, conversationID: conversationID, nodeID: approvalNodeID) {
            let scope = approvalNodeID.map { "node \($0)" } ?? "conversation"
            logger.info("[HITL] '\(toolName)' auto-approved via the \(scope)-scoped allowlist (\"Allow for this chat\") — skipping banner.")
        } else if await interactionMemory.isDenied(toolName: toolName, params: paramsString) {
            // [Loop Safety] Identical previously-denied request → auto-deny without a banner.
            // The observation matches a manual denial byte-for-byte, so the consecutive-denial
            // cap (and the repetition fingerprint) govern persistent hammering; a request with
            // DIFFERENT arguments still reaches the user.
            logger.info("[LoopSafety] '\(toolName)' repeated an identical declined request — auto-denied, no banner.")
            continuation.yield(.thought("🚫 Repeated a declined request — auto-denied."))
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
        } else if !WorkflowRunAttendance.canReachAHuman {
            // [WF-SE11] NOBODY TO ASK — a SCHEDULED run: no local banner and no remote channel.
            // Before this, the confirmation parked to an empty room until the 600s deadline killed
            // the WHOLE run as an unexplained `.cancelled`, on every fire, forever.
            //
            // ⚠️ `hasRemoteResponder` is load-bearing, not belt-and-braces. A ChatOps run also
            // binds `isAttended = false` (for the Router arbitration reason, WF-EX5), but a human
            // IS reachable there: `RemoteMirrorService` mirrors this confirmation to
            // Telegram/Slack/Discord with tappable Approve/Deny and resolves it through
            // `handleApproval`. Keying the refusal on `isAttended` alone deleted that shipped
            // flow and left a plain ChatOps agent chat no remedy but disabling Ask-first globally.
            //
            // The node's EXPLICIT setting is the sanctioned unattended path (threaded from
            // `WorkflowNodeConfig.unattendedAutoApprove`); a scheduled plain agent (no node
            // dimension) has no such setting — its remedy is the profile Tool Library's per-tool
            // Ask-first toggle. Refused fast, with an honest observation the model can act on and
            // an honest category for the dashboards (`.hitlUnattendedRefused`, NOT
            // `.toolUserDenied` — no user denied anything).
            if unattendedAutoApprove {
                logger.notice("[HITL] '\(toolName)' auto-approved by the workflow node's EXPLICIT unattended setting (run is unattended). CONSEQUENCE: the tool runs with no banner; this is configured intent, not a leaked chat grant.")
                // fall through to execution below — same as an attended allowlist hit
            } else {
                let remedy = approvalNodeID != nil
                    ? "Enable \u{201C}Unattended auto-approve\u{201D} on this workflow node, or run attended."
                    : "Turn off Ask-first for this tool in the profile's Tool Library, or run attended."
                let reason = "Tool '\(toolName)' requires confirmation, but this run is unattended — nobody can answer. The tool was NOT executed. \(remedy)"
                logger.error("[HITL] '\(toolName)' REFUSED — unattended run, no standing approval. CONSEQUENCE: the tool is refused NOW with an honest observation instead of parking to nobody until the run deadline kills everything. \(remedy)")
                let refusalOutput = ToolOutput(toolName: toolName, params: paramsString, output: reason, isSuccess: false)
                // Timeline tier: `.permissionRejected` (permission unavailable — pointedly NOT
                // `.userDenied`, no user denied anything). Dashboard tier: the classified
                // `.hitlUnattendedRefused`, so a schedule failing on this every night shows up
                // in the error panels as what it is.
                continuation.yield(.toolFailed(refusalOutput, category: .permissionRejected))
                await TraceRecorder.shared.emitAgentError(
                    span: iterationSpan,
                    error: ClassifiedAgentError.synthetic(
                        category: .hitlUnattendedRefused,
                        origin: "ToolExecutionLoop.unattendedConfirmation",
                        message: reason,
                        context: ["tool": toolName]
                    ),
                    iteration: currentIteration
                )
                return ToolObservation(
                    stepId: currentIteration,
                    toolCallId: toolCallId,
                    toolName: toolName,
                    result: reason,
                    summary: reason,
                    isSuccess: false,
                    params: paramsString,
                    output: reason,
                    artifacts: [],
                    failureCategory: .permissionRejected
                )
            }
        } else {
            let operationID = UUID()
            continuation.yield(.requestConfirmation(toolName: toolName, params: ps, operationID: operationID))

            let approved = await ExecutionSuspensionService.shared.suspend(for: operationID, conversationID: conversationID, nodeID: approvalNodeID)

            // ⚠️ A CANCELLED PARK IS NOT A DENIAL. Every teardown path resolves a waiting
            // permission with `false` — `cancel(for:)` force-resolves it, and the suspend's own
            // `onCancel` handler resumes `approved: false` — so without this check, pressing Stop
            // while a permission banner is up records a decision the user never made. That is not
            // cosmetic: the `!approved` body below writes a denial into `RunInteractionMemory`
            // (auto-denying an identical later call with NO banner), emits `.toolFailed(…
            // .userDenied)` into the node timeline and the persisted record, feeds the agent a
            // "user denied" observation it then reasons about, and charges the dedicated 2-strike
            // denial circuit breaker. `false` here means "not approved", and only a live user can
            // turn that into "denied".
            //
            // Throwing is safe and is the established shape: this function is `async throws`, its
            // sequential caller already does `try Task.checkCancellation()` per interactive tool,
            // and `ReActAgentExecutor` absorbs it in `catch is CancellationError`.
            if Task.isCancelled { throw CancellationError() }

            if approved, let edited = await ExecutionSuspensionService.shared.consumeEditedArguments(for: operationID) {
                // [HITL/A3] The user corrected the arguments in the banner — run with those.
                effectiveArguments = edited
                effectiveParams = serializeToolParams(edited)
            }
            if !approved {
                // [Loop Safety] Remember the denial so an identical re-ask is auto-denied.
                await interactionMemory.recordDenial(toolName: toolName, params: paramsString)
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

    // [CodeViewer] Pre-write snapshot for file-writing tools, captured from the
    // POST-HITL-edit arguments (the path that will actually be written). This is what
    // the timeline's "View changes" affordance diffs against — nothing else records the
    // file's prior state once the write lands.
    let preWriteContent = await preWriteSnapshot(toolName: toolName, arguments: effectiveArguments)

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

    // Edit tools' params carry only find/replace strings — read the post-state back so
    // the timeline can diff what actually changed.
    let postWriteContent = await postWriteSnapshot(toolName: toolName, arguments: effectiveArguments, isSuccess: result.isSuccess)

    // Emit structured success/failure — category drives negativeConstraints policy and UI affordance.
    let output = ToolOutput(toolName: toolName, params: effectiveParams, output: result.llmObservation, isSuccess: result.isSuccess, preWriteContent: preWriteContent, postWriteContent: postWriteContent)
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

/// Tools whose successful execution mutates a file on disk — all of them get a PRE-write
/// snapshot for the timeline's "View changes" diff.
///
/// ⚠️ "All of them" is now TRUE. It was not: `create_file` and `edit_code` were missing while
/// `write_file` was present, though all three are `.libraryExceptCode` in `NativeToolCatalog` —
/// the same class, superseded by the same splits. So a CHAT or WORKFLOW profile's file write got
/// no `preWriteContent`, and `TimelineFileViewerAction.resolve` (which gates on the mirror of
/// this set) then produced no chip and no persisted `ActionEffect`. Keep this set and
/// `AgentTimelineView.chipEligibleTools` in step: a name in one and not the other is a row that
/// either has a snapshot nothing renders, or an affordance with no data behind it.
private let preSnapshotToolNames: Set<String> = [
    "write_file", "overwrite_file", "create_new_file", "create_file",
    "edit_code_single", "edit_code_batch", "edit_code"
]

/// Tools whose params DON'T carry the full post-state (`edit_code_*` carry find/replace
/// strings only) — these get a POST-write read-back after success. Ground truth beats
/// replicating the tool's replacement semantics (uniqueness rules, matching behavior)
/// in the UI, where they would silently drift.
/// `edit_code` is included for the same reason as its two splits: its params are
/// `{file_path, edits | old_string + new_string}`, i.e. find/replace only, so the post-state
/// exists nowhere but on disk.
private let postSnapshotToolNames: Set<String> = ["edit_code_single", "edit_code_batch", "edit_code"]

/// Drift seam. The executor's snapshot sets and `AgentTimelineView.chipEligibleTools` are two
/// halves of ONE contract: a name in the chip set with no snapshot gets an affordance with no data
/// behind it, and a name with a snapshot nothing renders is a file read for nothing. [tc-2] was
/// exactly that drift — `create_file` and `edit_code` were in neither, and the fix had to add them
/// to BOTH. Exposed so a test can assert the two stay in step, rather than each side being tested
/// against hand-fed fixtures that cannot notice the other half is missing.
enum SnapshotToolContract {
    static var preSnapshot: Set<String> { preSnapshotToolNames }
    static var postSnapshot: Set<String> { postSnapshotToolNames }
}

/// Snapshot cap: source files land far below this; anything bigger isn't worth
/// carrying in a persisted timeline event just to render a diff.
private let preWriteSnapshotByteLimit = 512_000

/// The file-target path of a mutating tool call, honoring both spellings: native tools
/// take `path`, split tools `file_path`.
///
/// ⚠️ [CR19] Resolved through `FilePathResolver`, which is what the tools that actually WRITE
/// the file use (`CodingAssistantTools`) and what the live-write events use.
///
/// This used to be `expandingTildeInPath` alone, which expands `~` but leaves a RELATIVE path
/// relative — and `FileManager` then resolves it against the PROCESS working directory, which for
/// a GUI-launched app is `/`. So for a bare `notes.md` the snapshot looked at `/notes.md` and the
/// write tool wrote `<home>/notes.md`: two different files. `snapshotContents` found nothing,
/// returned nil, and the empty baseline made an OVERWRITE of an existing file render as a
/// creation — every line green, nothing shown as replaced — in the timeline chip, the diff
/// preview and the `ActionEffect` the model reads back as its own memory of what it did.
///
/// The resolver is the single source of truth precisely so these cannot drift; this was the one
/// file-touching path that had not been routed through it.
/// Internal rather than private [CR19]: this is the one place the snapshot decides WHICH FILE it
/// is looking at, and the defect was that it decided differently from the writer. A rule that has
/// already drifted once needs a test that can reach it.
func fileTargetPath(in arguments: [String: JSONValue]) -> String? {
    guard let path = arguments["path"]?.stringValue ?? arguments["file_path"]?.stringValue,
          !path.isEmpty else { return nil }
    return FilePathResolver.resolve(path)
}

/// Size-capped UTF-8 read of a snapshot target. Nil = unreadable or over the cap.
private func snapshotContents(atPath resolved: String) -> String? {
    guard let attributes = try? FileManager.default.attributesOfItem(atPath: resolved),
          (attributes[.size] as? Int ?? .max) <= preWriteSnapshotByteLimit,
          let content = try? String(contentsOfFile: resolved, encoding: .utf8) else {
        return nil
    }
    return content
}

/// The target file's content just before a file-mutating tool runs. Semantics:
/// "" = the file doesn't exist yet (a diff against empty shows the whole write as
/// added — meaningful); nil = not a file-mutating tool, no path argument, or the file
/// is unreadable/over the cap (no diff affordance, logged).
private func preWriteSnapshot(toolName: String, arguments: [String: JSONValue]) async -> String? {
    guard preSnapshotToolNames.contains(toolName),
          let resolved = fileTargetPath(in: arguments) else { return nil }

    // Off the cooperative pool: this reads up to `preWriteSnapshotByteLimit` bytes
    // synchronously, and blocking a cooperative thread starves every other concurrent
    // task in the agent run.
    return await Task.detached(priority: .utility) { () -> String? in
        guard FileManager.default.fileExists(atPath: resolved) else { return "" }
        guard let content = snapshotContents(atPath: resolved) else {
            logger.info("[CodeViewer] Pre-write snapshot skipped for '\(resolved)' — unreadable or over \(preWriteSnapshotByteLimit) bytes; the timeline row will open without a diff.")
            return nil
        }
        return content
    }.value
}

/// The target file's content just after a SUCCESSFUL edit-tool run — the post-state the
/// params can't provide. Nil = tool doesn't need read-back, the call failed, or the file
/// is unreadable/over the cap (row gets no viewer affordance, logged).
private func postWriteSnapshot(toolName: String, arguments: [String: JSONValue], isSuccess: Bool) async -> String? {
    guard isSuccess, postSnapshotToolNames.contains(toolName),
          let resolved = fileTargetPath(in: arguments) else { return nil }

    // Off the cooperative pool — see `preWriteSnapshot`.
    return await Task.detached(priority: .utility) { () -> String? in
        guard let content = snapshotContents(atPath: resolved) else {
            logger.info("[CodeViewer] Post-edit snapshot skipped for '\(resolved)' — unreadable or over \(preWriteSnapshotByteLimit) bytes; the timeline row will open without a diff.")
            return nil
        }
        return content
    }.value
}

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
    // Sorted keys make the serialization DETERMINISTIC: identical logical arguments always
    // produce identical strings. Both the repetition fingerprint (argsHash) and the
    // RunInteractionMemory denial key depend on this.
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    if let data = try? encoder.encode(normalized), let str = String(data: data, encoding: .utf8) { return str }
    return "{}"
}

/// Normalizes filesystem path arguments to canonical form so that
/// `/Users/alice/Acme/` and `/Users/alice/Acme` produce identical
/// signatures for deduplication and circuit-breaker fingerprinting.
///
/// Handles: trailing slashes, tilde expansion, `.` / `..` segments, doubled slashes.
///
/// Applies ONLY to arguments that are actually paths, chosen by KEY. It used to sniff the
/// VALUE for a leading `/`, `~` or `./` — which is true of any file whose first line is a
/// `//` comment, so `write_file`'s `content` was run through `standardizingPath`. That
/// silently (a) collapsed every `//` to `/`, turning Java/Swift/C line comments into syntax
/// errors, and (b) truncated the content at PATH_MAX (1024 bytes). The corrupted string
/// became the HITL banner's preview, the live Code Viewer tab, `ToolExecutionData.params`
/// and therefore the episodic `effect` diff — so the user approved a write they could only
/// partly see, and the model read its own mangled output back on the next turn and
/// reproduced it. Field-observed 2026-07-27 (live-tab lengths 1014/1018/1019/1021 for files
/// of 1.5K–2.9K, and `+/ Program 3:` in the rendered diff).
private let pathArgumentKeys: Set<String> = [
    "path", "file_path", "filepath", "filePath", "file", "filename", "destination",
    "destination_path", "destinationPath", "source", "source_path", "sourcePath",
    "src", "dest", "target", "target_path", "targetPath", "new_path", "newPath",
    "current_path", "currentPath", "folder", "folderPath", "directory",
    "directoryPath", "dir", "copy_path", "original", "item"
]

func normalizePathArguments(_ params: [String: JSONValue]) -> [String: JSONValue] {
    params.reduce(into: [String: JSONValue]()) { result, entry in
        let (key, value) = entry
        guard pathArgumentKeys.contains(key),
              case .string(let str) = value,
              str.hasPrefix("/") || str.hasPrefix("~") || str.hasPrefix("./") else {
            result[key] = value
            return
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
        result[key] = .string(normalized)
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
    continuation.yield(.toolCall(name: "final_answer", params: paramsString, stepId: currentIteration))
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
