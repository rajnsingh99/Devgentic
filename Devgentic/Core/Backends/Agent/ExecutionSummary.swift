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
    let toolName: String
    let params: String     // Serialized JSON parameters string
    let output: String     // Raw tool output string
    let isSuccess: Bool
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

    /// Records a tool invocation result and updates the aggregate completion status unconditionally.
    mutating func record(toolName: String, params: String, output: String, isSuccess: Bool) {
        toolResults.append(SynthesizedToolResult(
            toolName: toolName,
            params: params,
            output: output,
            isSuccess: isSuccess
        ))
        recomputeStatus()
    }

    /// Marks the run as definitively complete.
    /// Optionally records a system failure reason if the loop was aborted abruptly.
    mutating func markComplete(failureReason: String? = nil) {
        self.failureReason = failureReason
        completionStatus = toolResults.allSatisfy(\.isSuccess) ? .success : .partialSuccess
    }

    // MARK: - Private

    private mutating func recomputeStatus() {
        guard !toolResults.isEmpty else {
            completionStatus = .stalled
            return
        }
        let allSucceeded  = toolResults.allSatisfy(\.isSuccess)
        let anySucceeded  = toolResults.contains(where: \.isSuccess)
        completionStatus  = allSucceeded ? .success : (anySucceeded ? .partialSuccess : .failed)
    }
}
