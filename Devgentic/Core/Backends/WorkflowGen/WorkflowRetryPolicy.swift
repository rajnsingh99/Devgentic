// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
//
//  WorkflowRetryPolicy.swift
//  Devgentic
//
//  Created by Raj Singh.
//

import Foundation

/// When a workflow node retries: on a compute timeout (except a sub-workflow node, whose timeout is one cumulative
/// budget) or on a failure of a profile node (bot, agent, sub-workflow). Everything else runs once, since tool calls are
/// deterministic.
enum WorkflowRetryPolicy {

    /// How many attempts a node gets from the outer structural loop; sub-workflow nodes only, everything else returns 1.
    /// Bot/agent nodes retry in `executeProfileNodeWithRetry` and Action nodes in their own per-tool loop (an outer loop
    /// would multiply the two).
    nonisolated static func structuralAttempts(
        isSubWorkflow: Bool,
        maxNodeRetries: Int?
    ) -> Int {
        guard isSubWorkflow else { return 1 }
        return max((maxNodeRetries ?? 0) + 1, 1)
    }

    // Why: a `0...maxRetries` range with a negative upper bound traps, and the decoder does not clamp `maxNodeRetries`;
    // a decode clamp would rewrite the stored blob.
    /// How many attempts a bot/agent node gets from `executeProfileNodeWithRetry`; clamped to at least 1 at the read, not at
    /// decode.
    nonisolated static func profileAttempts(maxNodeRetries: Int?) -> Int {
        max((maxNodeRetries ?? 0) + 1, 1)
    }

    /// Whether a node's result ends the attempt loop in `executeProfileNodeWithRetry`. The switch is exhaustive so a new
    /// `NodeExecutionStatus` must decide whether it retries; `.skipped` stops the loop, since a skip is an instruction, not
    /// a failure.
    nonisolated static func stopsRetrying(after status: NodeExecutionStatus) -> Bool {
        switch status {
        case .completed:            return true
        case .failed(let reason):   return !reason.isRetryable
        case .canceled:             return true
        case .skipped:              return true
        }
    }

    /// Whether a sub-workflow node's failure should be retried; deliberately coarse, with cancellation the only exclusion
    /// (an instruction, not a failure).
    nonisolated static func shouldRetrySubWorkflow(after reason: AgentFailureReason) -> Bool {
        if case .cancelled = reason { return false }
        return true
    }

    /// Whether a thrown tool error is transient enough to be worth a second identical attempt. A deliberately short
    /// allowlist: an unrecognised error is treated as permanent. A cancellation-shaped `URLError(.cancelled)` is excluded,
    /// since cancellation is never retried.
    nonisolated static func isTransientToolError(_ error: Error) -> Bool {
        // A timed-out tool is never re-run: a timeout says only that the answer did not come back in time, and the work may
        // have happened, so a retry would repeat a completed side effect. No tool declares itself safe to repeat yet.
        if isTimeout(error) { return false }
        // Network transport, including MCP over HTTP, which surfaces as URLError or wraps one —
        // except .cancelled, which is Stop, not a transient blip.
        if let urlError = error as? URLError, urlError.code != .cancelled { return true }
        if let underlying = (error as NSError).userInfo[NSUnderlyingErrorKey] as? URLError,
           underlying.code != .cancelled {
            return true
        }
        return false
    }

    /// Our own tool limit, or a network request that timed out — in both the request may have been
    /// carried out; only the reply was lost.
    nonisolated static func isTimeout(_ error: Error) -> Bool {
        if let agentError = error as? AgentExecutionError, case .executionTimeout = agentError.reason { return true }
        if let urlError = error as? URLError, urlError.code == .timedOut { return true }
        if let underlying = (error as NSError).userInfo[NSUnderlyingErrorKey] as? URLError,
           underlying.code == .timedOut { return true }
        return false
    }

    /// One-line reason for the log when a retry is declined, so a skipped attempt is never silent.
    nonisolated static func declineReason(for error: Error) -> String {
        if error is CancellationError { return "the run was cancelled" }
        if isTimeout(error) { return "it TIMED OUT — the work may already have happened, so it is never re-run automatically" }
        return "the error is not transient (\(type(of: error)))"
    }

    // Why: a single choke point, so widening `isTransientToolError` cannot reopen a retry-after-Stop path; with
    // `retryDelay == 0` a Stop can still let one attempt through.
    /// Whether an Action node's failed tool attempt should be retried. `isCancelled` is checked first and unconditionally,
    /// so a cancellation is never retried whatever shape its error took; this governs only the outer Action-node loop, not
    /// what a single `tool.run()` does internally.
    nonisolated static func shouldRetryToolFailure(_ error: Error, attempt: Int, maxRetries: Int, isCancelled: Bool) -> Bool {
        guard !isCancelled, attempt < maxRetries else { return false }
        return isTransientToolError(error)
    }
}
