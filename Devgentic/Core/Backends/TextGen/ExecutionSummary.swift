// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2026 Raj Singh
//
//  ExecutionSummary.swift
//  Devgentic
//
//  Created by Raj Singh on 21/02/26.
//
//  A structured, clean record of what the agent actually did during a single execution run.
//
//  Design contract:
//  - Records ONLY factual outcomes: tool name, params, output, success flag.
//  - NEVER contains scratchpad strings, system escalation messages, or internal monologue.
//  - This object is the sole source of truth passed to ResponseSynthesizer.
//  - It is scoped to a single user query and reset on every new request.
//

import Foundation

// MARK: - Completion Status

/// The terminal state of a ReAct execution run, as seen from the outside.
/// Used by ResponseSynthesizer to choose the appropriate response framing.
enum CompletionStatus: Sendable {
    /// All tools succeeded and the primary goal was met.
    case success
    /// Some tools succeeded and some failed; the task is partially complete.
    case partialSuccess
    /// All attempted tools failed.
    case failed
    /// No tools were invoked; the agent looped without making meaningful progress.
    case stalled
}

// MARK: - Synthesized Tool Result

/// A clean, factual record of a single tool invocation within a ReAct loop.
/// Contains no reasoning traces or system alerts — only observable data.
struct SynthesizedToolResult: Sendable {
    let toolCallId: String // The unique ID assigned by the provider API for correlation
    let toolName: String
    let params: String     // Serialized JSON parameters string
    let output: String     // Raw tool output string
    let isSuccess: Bool
    /// Why the call failed (nil on success). Lets status math and the terminal
    /// block distinguish EVIDENCE failures from user decisions — `.userDenied`
    /// (tool confirmation rejected) and `.cancelled` (ask_user skipped) are
    /// choices, not tool failures, and must not demote the run.
    var failureCategory: ToolFailureCategory? = nil
}

// MARK: - Execution Summary

/// Accumulates tool results during the ReAct execution loop.
/// Scoped to one user query; reset at the start of every new request.
struct ExecutionSummary: Sendable {

    // MARK: - Properties

    let originalGoal: String
    var completionStatus: CompletionStatus
    var toolResults: [SynthesizedToolResult]
    var failureReason: String?
    
    /// Captures the agent's final reasoning block when it terminates the loop
        var finalAgentThought: String?
    
    // MARK: - Initialization

    init(originalGoal: String) {
            self.originalGoal = originalGoal
            self.completionStatus = .stalled
            self.toolResults = []
            self.failureReason = nil
            self.finalAgentThought = nil
        }

    // MARK: - Mutation

    /// Results that constitute tool EVIDENCE. User decisions (denied confirmation,
    /// skipped ask_user, mid-flight cancel) are excluded — a run where the user
    /// declined one write but the agent completed the task is a success, not a
    /// partial failure, and must not store a FAILED episode.
    var evidenceResults: [SynthesizedToolResult] {
        toolResults.filter { $0.failureCategory != .userDenied && $0.failureCategory != .cancelled }
    }

    /// Records a tool invocation result and updates the aggregate completion status unconditionally.
    mutating func record(toolCallId: String, toolName: String, params: String, output: String, isSuccess: Bool, failureCategory: ToolFailureCategory? = nil) {
        toolResults.append(SynthesizedToolResult(
            toolCallId: toolCallId,
            toolName: toolName,
            params: params,
            output: output,
            isSuccess: isSuccess,
            failureCategory: failureCategory
        ))
        recomputeStatus()
    }

    /// Marks the run as definitively complete.
    /// Optionally records a system failure reason if the loop was aborted abruptly.
    mutating func markComplete(failureReason: String? = nil) {
        self.failureReason = failureReason
        if evidenceResults.isEmpty {
            // No tool EVIDENCE was produced — either no tools ran, or everything
            // that ran was a user decision (denials / skips). A partial result at
            // best (e.g., parser dropped tool calls, or the model decided it
            // couldn't help without tool use).
            completionStatus = .partialSuccess
        } else {
            // Same math as recomputeStatus(): an all-failed run must read `.failed`.
            // The previous `allSatisfy ? .success : .partialSuccess` ceiling silently
            // upgraded all-failed runs to partialSuccess at loop end, overwriting the
            // honest per-record verdict.
            recomputeStatus()
        }
    }

    // MARK: - Private

    /// Status is computed over EVIDENCE results only — user decisions don't
    /// demote a run (a denied write followed by task completion is `.success`).
    private mutating func recomputeStatus() {
        let evidence = evidenceResults
        guard !evidence.isEmpty else {
            completionStatus = .stalled
            return
        }
        let allSucceeded  = evidence.allSatisfy(\.isSuccess)
        let anySucceeded  = evidence.contains(where: \.isSuccess)
        completionStatus  = allSucceeded ? .success : (anySucceeded ? .partialSuccess : .failed)
    }
}
