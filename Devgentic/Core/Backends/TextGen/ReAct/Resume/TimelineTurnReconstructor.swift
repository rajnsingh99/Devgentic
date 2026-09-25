// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
//
//  TimelineTurnReconstructor.swift
//  Devgentic
//
//  [G1 Piece 2 — resume] Rebuilds an interrupted run's in-flight reasoning state from the persisted
//  message timeline so a parked-HITL run can continue after restart. The persisted `timelineEvents`
//  are a DIALECT-AGNOSTIC record of what happened (reasoning + each tool's name/args/output, grouped
//  by `stepId`). This reconstructor turns them into provider-agnostic `ReconstructedStep`s; the
//  executor then serializes those into native turns via the *currently re-resolved* `ToolTurnAdapter`
//  — which is why a run parked under one provider can resume on any same-family provider.
//
//  The KV cache is dead on restart, so faithfulness here is SEMANTIC, not byte-identical: tool-call
//  ids are freshly synthesized but kept internally consistent (each assistant `tool_use` paired with
//  its `tool_result`), which every provider accepts.
//

import Foundation

/// A single reconstructed ReAct iteration. `toolCalls` and `observations` are paired 1:1 in order and
/// share synthesized ids, so the adapter emits balanced `assistant(tool_calls)` → `tool(result)` turns.
struct ReconstructedStep {
    let stepId: Int
    let reasoning: String?
    let toolCalls: [PendingToolCall]
    let observations: [ToolObservation]
}

/// The result of reconstructing an interrupted run from its persisted timeline.
struct TimelineReconstruction {
    /// Completed tool exchanges, in iteration order — the conversation up to the park.
    let completedSteps: [ReconstructedStep]
    /// The tool the run was parked on (the dangling, still-executing event), re-raised + executed on
    /// resume. `nil` if no dangling tool was found (e.g. a `.streaming` death mid-generation, which
    /// resume v1 does not handle).
    let parkedTool: PendingToolCall?
    /// `true` when the parked tool is `ask_user` (re-raise a clarification) vs a permission confirmation.
    let parkedToolIsClarification: Bool
    /// Re-derived count of successful reading-tool calls so the G6 reading-gate doesn't re-lock on resume.
    let readingToolSuccessCount: Int
    /// The iteration the run had reached (the parked iteration). The loop resumes generating at +1.
    let resumeIteration: Int
}

enum TimelineTurnReconstructor {

    /// Tools that count toward the G6 reading-gate. Mirrors `ReActAgentExecutor.readingToolNames`
    /// so the gate counter re-derived here matches what a fresh run would compute.
    static let readingToolNames: Set<String> = [
        "read_file", "find_definition", "code_search", "file_overview", "project_tree", "codebase_map"
    ]

    /// Rebuilds the in-flight state from a persisted timeline.
    /// - Parameters:
    ///   - timelineEvents: the interrupted message's persisted timeline (chronological).
    ///   - parkedOperationID: the persisted HITL operationID, reused as the parked tool's id for
    ///     audit / remote continuity (the executor mints its own id when it actually re-runs the tool).
    ///   - dropDanglingTool: when `true` (a STREAMING resume), the dangling mid-execution tool is
    ///     DROPPED — not returned as `parkedTool` — because it was actually running when the process
    ///     died (its side effect may have partially happened), so it is neither replayed nor re-run;
    ///     the agent re-decides from the completed work. When `false` (a PARKED-HITL resume) the
    ///     dangling tool is the request the run was waiting on, so it's returned to be re-raised.
    static func reconstruct(from timelineEvents: [TimelineEvent], parkedOperationID: UUID?, dropDanglingTool: Bool = false) -> TimelineReconstruction {
        var stepReasoning: [Int: String] = [:]
        var stepTools: [Int: [ToolExecutionData]] = [:]
        var stepOrder: [Int] = []            // first-seen order of step ids
        var pendingReasoning: String?         // most recent reasoning not yet attached to a step
        var dangling: ToolExecutionData?      // the still-executing (parked) tool, if any
        var readingSuccess = 0
        var maxStep = 0

        for event in timelineEvents {
            switch event {
            case .reasoning(_, let text):
                pendingReasoning = text

            case .toolExecution(let data):
                // Legacy events without a stepId fold into the current iteration (defensive — every
                // resumable, Piece-1-persisted run stamps stepId at the .toolCall emit site).
                let step = data.stepId ?? max(1, maxStep)
                maxStep = max(maxStep, step)

                if data.isExecuting || data.output == nil {
                    // Still running when the process died = the tool the run parked on. Keep the
                    // latest such event (there should be exactly one for a parked-HITL run).
                    dangling = data
                } else {
                    if stepTools[step] == nil { stepTools[step] = []; stepOrder.append(step) }
                    stepTools[step]?.append(data)
                    if stepReasoning[step] == nil, let r = pendingReasoning, !r.isEmpty {
                        stepReasoning[step] = r
                    }
                    pendingReasoning = nil
                    if data.isSuccess == true, readingToolNames.contains(data.name) {
                        readingSuccess += 1
                    }
                }

            default:
                break
            }
        }

        // Build completed steps in iteration order with synthesized, internally-consistent pairing ids.
        var steps: [ReconstructedStep] = []
        for step in stepOrder.sorted() {
            guard let tools = stepTools[step] else { continue }
            var calls: [PendingToolCall] = []
            var observations: [ToolObservation] = []
            for tool in tools {
                // `final_answer` terminates a run, so it never appears in a *parked* (unfinished) run;
                // guard defensively — it has no place in a resumed prefix.
                if tool.name == "final_answer" { continue }
                let synthID = UUID().uuidString
                let args = JSONValue.parseStructured(tool.params)?.objectValue ?? [:]
                calls.append(PendingToolCall(id: synthID, name: tool.name, arguments: args))
                observations.append(ToolObservation(
                    stepId: step,
                    toolCallId: synthID,
                    toolName: tool.name,
                    result: tool.output ?? "",
                    summary: tool.output ?? "",
                    isSuccess: tool.isSuccess ?? false,
                    params: tool.params,
                    output: tool.output ?? "",
                    artifacts: [],
                    failureCategory: tool.failureCategory
                ))
            }
            if !calls.isEmpty {
                steps.append(ReconstructedStep(stepId: step, reasoning: stepReasoning[step], toolCalls: calls, observations: observations))
            }
        }

        // `maxStep` already counted the dangling tool's iteration in the loop above, so `resumeIteration`
        // continues at N+1 whether we re-raise the dangling tool (parked) or drop it (streaming).
        var parked: PendingToolCall?
        var parkedIsClarification = false
        if let d = dangling, !dropDanglingTool {
            let args = JSONValue.parseStructured(d.params)?.objectValue ?? [:]
            parked = PendingToolCall(id: parkedOperationID?.uuidString ?? UUID().uuidString, name: d.name, arguments: args)
            parkedIsClarification = (d.name == "ask_user")
        }

        return TimelineReconstruction(
            completedSteps: steps,
            parkedTool: parked,
            parkedToolIsClarification: parkedIsClarification,
            readingToolSuccessCount: readingSuccess,
            resumeIteration: max(1, maxStep)
        )
    }
}
