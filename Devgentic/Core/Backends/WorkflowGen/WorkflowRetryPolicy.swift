//
//  WorkflowRetryPolicy.swift
//  Devgentic
//
//  WHEN a workflow node retries. Extracted as pure statics because none of this had a test surface:
//  the rules lived inline in two different retry loops that disagreed with each other, and one of
//  them disagreed with its own comment.
//
//  THE RULE (owner decision, 2026-08-19). A retry fires in exactly two situations:
//
//    1. **A compute timeout**, on any node kind that retries at all.
//    2. **A failure of a profile node** — bot, agent, or sub-workflow.
//
//  Everything else runs once. In particular an Action node's tool failure is NOT a retry trigger
//  unless it was transient: a tool call is deterministic, so `file not found` is `file not found`
//  again on attempt two. That is the whole difference between the two families:
//
//    • PROFILE nodes are LLM-driven and NON-DETERMINISTIC. A second attempt is a fresh sample, not
//      a replay, so retrying a generic failure is genuinely worth something — a parse failure or a
//      repetitive-action loop may simply not recur. This is why the rule is deliberately coarse
//      here rather than reasoning about which failure "deserves" a retry.
//    • ACTION nodes are deterministic tool calls. Retrying a permanent error burns the node's whole
//      budget to arrive at the identical error, so it is gated on transience.
//
//  ⚠️ CANCELLATION IS NEVER RETRIED, and this is not an exception to the rule above — a cancel is
//  not a failure, it is the user pressing Stop. Retrying it would restart the very run they just
//  stopped, up to five times, directly fighting the conversation-scoped Stop in
//  `ForegroundRunResolver`. `AgentFailureReason.cancelled` already reports `isRetryable == false`;
//  the structural path additionally catches `CancellationError` before the failure arm is reached.
//
//  ⚠️ NOT A CLASSIFICATION GATE. This decides whether another attempt is CAPABLE of a different
//  outcome. It must never refuse a retry because a tool "looks side-effecting" — that would be
//  metadata overriding a configured preference. Side-effect risk is SURFACED (logged, and warned
//  about in the inspector), never enforced.
//

import Foundation

enum WorkflowRetryPolicy {

    /// How many attempts a node gets from the OUTER structural loop.
    ///
    /// Sub-workflow nodes only. Everything else returns 1:
    ///   • bot / agent nodes retry in `executeProfileNodeWithRetry`, which never reaches here;
    ///   • Action nodes retry in their own per-tool loop, and an outer loop on top would MULTIPLY
    ///     the two (3 outer × 3 inner = 9 tool invocations for a setting that says 3);
    ///   • condition / code / gate / trigger have no retry semantics — re-asking a human to answer
    ///     a Gate is not a retry.
    nonisolated static func structuralAttempts(
        isSubWorkflow: Bool,
        maxNodeRetries: Int?,
        fallbackRetries: Int
    ) -> Int {
        guard isSubWorkflow else { return 1 }
        return max((maxNodeRetries ?? fallbackRetries) + 1, 1)
    }

    /// Whether a node's result ENDS the attempt loop in `executeProfileNodeWithRetry`.
    ///
    /// Extracted here for the same reason the rest of this file was: the decision lived as four
    /// inline `if case` lines in the middle of the loop, with no test surface, and it was missing
    /// a case. An EXHAUSTIVE switch is the point — a new `NodeExecutionStatus` case cannot be added
    /// without deciding, at compile time, whether it retries.
    ///
    /// ⚠️ `.skipped` STOPS THE LOOP, and that arm is currently unreachable by construction: both
    /// `.skipped` envelopes are built in the dispatch pre-flight (`WorkflowExecutor` cascade skip
    /// and user skip), which never enters this loop. It exists because Phase B's running-node skip
    /// WILL return `.skipped` from `executeNode`, and without it the node the user just skipped is
    /// re-dispatched at full token cost — on existing workflows too, since `maxRetries` still
    /// honours the retired workflow-level fallback. A skip is an instruction, not a failure: the
    /// same rule that makes `shouldRetrySubWorkflow` refuse to retry a cancellation.
    nonisolated static func stopsRetrying(after status: NodeExecutionStatus) -> Bool {
        switch status {
        case .completed:            return true
        case .failed(let reason):   return !reason.isRetryable
        case .canceled:             return true
        case .skipped:              return true
        }
    }

    /// Whether a sub-workflow node's failure should be retried.
    ///
    /// Coarse ON PURPOSE — see the non-determinism note in the file header. The only exclusion is
    /// cancellation, which is an instruction rather than a failure.
    nonisolated static func shouldRetrySubWorkflow(after reason: AgentFailureReason) -> Bool {
        if case .cancelled = reason { return false }
        return true
    }

    /// Whether a thrown tool error is transient enough to be worth a second identical attempt.
    ///
    /// ⚠️ This exists because the Action path's retry sat in a bare `catch` under a comment reading
    /// "Retry transient failures (timeout, network, MCP) up to the cap" — which the code did not
    /// do. It retried everything, including permanent errors. This makes the comment true.
    ///
    /// Deliberately a SHORT allowlist rather than a deny-list of permanent errors: an unrecognised
    /// error is treated as permanent, so a new tool error does not silently acquire retry behaviour
    /// nobody chose. Widening it is a one-line change plus a test.
    nonisolated static func isTransientToolError(_ error: Error) -> Bool {
        // A compute timeout — trigger (1) of the rule. A fresh full budget genuinely helps a stall.
        if let agentError = error as? AgentExecutionError,
           case .executionTimeout = agentError.reason {
            return true
        }
        // Network transport, including MCP over HTTP, which surfaces as URLError or wraps one.
        if error is URLError { return true }
        if let underlying = (error as NSError).userInfo[NSUnderlyingErrorKey] as? Error,
           underlying is URLError {
            return true
        }
        return false
    }

    /// One-line reason for the log when a retry is declined, so a skipped attempt is never silent.
    nonisolated static func declineReason(for error: Error) -> String {
        if error is CancellationError { return "the run was cancelled" }
        return "the error is not transient (\(type(of: error)))"
    }
}
