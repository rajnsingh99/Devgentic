// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2026 Raj Singh
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
//    1. **A compute timeout**, on any node kind that retries at all — EXCEPT a sub-workflow node
//       (WF-EX9, 2026-08-25): its outer timeout is now ONE cumulative budget shared across every
//       attempt (`WorkflowExecutor.executeStructuralNodeBounded`), not a fresh one per attempt, so
//       a timeout there ends the whole retry sequence instead of triggering another attempt — the
//       cumulative budget is defined as already having spent everything a retry could have used.
//       An Action node's own tool timeout is unaffected: it retries inside its OWN independent
//       per-tool race (`runToolWithTimeout`), never through this outer mechanism.
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

    /// How many attempts a bot/agent node gets from `executeProfileNodeWithRetry`.
    ///
    /// ⚠️ THE CLAMP IS THE POINT (register EXC-8). That loop was `for attempt in 0...maxRetries`, and
    /// a `ClosedRange` whose lowerBound exceeds its upperBound TRAPS — it does not yield an empty
    /// range — so a negative count ABORTS THE APP on an ordinary bot/agent dispatch. Neither feeder
    /// value is clamped on the way in: `WorkflowNodeConfig.init(from:)` decodes `maxNodeRetries` with
    /// a bare `decodeIfPresent(...) ?? 0`, and `BackendProfile`'s workflow arm decodes
    /// `defaultMaxRetries` the same way, so one negative in an externally-written blob arms EVERY
    /// node that carries no count of its own.
    ///
    /// ⚠️ Clamped HERE, at the read, rather than at either decode boundary. There are two of those,
    /// in two files, and clamping both would still leak — `WorkflowNodeConfig`'s memberwise init and
    /// `materialised(inheritedRetryDefault:)` bypass `init(from:)` entirely, and `resolvedMaxRetries`
    /// is a computed property any future writer can feed. A decode clamp would also silently rewrite
    /// the user's stored blob on the next save.
    ///
    /// Same guarantee, same shape and the same reason as `structuralAttempts` above — which has
    /// carried this clamp, and a test naming the corrupt-stored-value case, since it was written.
    nonisolated static func profileAttempts(maxNodeRetries: Int?, fallbackRetries: Int) -> Int {
        max((maxNodeRetries ?? fallbackRetries) + 1, 1)
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
    ///
    /// ⚠️ EXCLUDES a cancellation-shaped `URLError` (WF-CC4, 2026-08-26). A tool cancelled mid-flight
    /// via URLSession's Task-cancellation bridging throws `URLError(.cancelled)`, not
    /// `CancellationError` — without this exclusion this predicate called it "transient" and
    /// contradicted the file's own rule above (cancellation is never retried) whenever a Stop
    /// happened to surface through this specific error shape instead of `CancellationError`.
    nonisolated static func isTransientToolError(_ error: Error) -> Bool {
        // A compute timeout — trigger (1) of the rule. A fresh full budget genuinely helps a stall.
        if let agentError = error as? AgentExecutionError,
           case .executionTimeout = agentError.reason {
            return true
        }
        // Network transport, including MCP over HTTP, which surfaces as URLError or wraps one —
        // except .cancelled, which is Stop, not a transient blip.
        if let urlError = error as? URLError, urlError.code != .cancelled { return true }
        if let underlying = (error as NSError).userInfo[NSUnderlyingErrorKey] as? URLError,
           underlying.code != .cancelled {
            return true
        }
        return false
    }

    /// One-line reason for the log when a retry is declined, so a skipped attempt is never silent.
    nonisolated static func declineReason(for error: Error) -> String {
        if error is CancellationError { return "the run was cancelled" }
        return "the error is not transient (\(type(of: error)))"
    }

    /// Whether an Action node's failed tool attempt should be retried.
    ///
    /// ⚠️ `isCancelled` is checked FIRST and unconditionally (WF-CC4, 2026-08-26) — a cancellation
    /// must never be retried regardless of what shape the underlying error took (bare
    /// `CancellationError`, a cancellation-flavored `URLError`, or something a tool's own internal
    /// retry wrapped further). Extracted as a single choke point so a future widening of
    /// `isTransientToolError`'s allowlist cannot silently reopen a retry-after-Stop path — the caller
    /// still owns routing a `true`-for-`isCancelled` case to a `.canceled` result rather than treating
    /// a `false` return here as an ordinary declined-retry failure.
    ///
    /// ⚠️ THIS GOVERNS ONLY THE OUTER ACTION-NODE LOOP. It has no visibility into, and no effect on,
    /// what a single `tool.run()` call does internally before it returns or throws back here. An
    /// MCP-resolved tool's own `reconnectAndRetry` wrapper has this identical bug class at least one
    /// level deeper (its own `try?`-swallowed backoff sleep, no `Task.isCancelled` check of its own) —
    /// tracked separately, not closed by this function. Do not read "cancellation is never retried"
    /// here as a claim that a tool invocation as a whole cannot be re-run after Stop; it only means
    /// THIS loop will not dispatch a second `tool.run()` call of its own.
    ///
    /// ⚠️ Also does not close the residual gap between deciding to retry and actually dispatching the
    /// next attempt when `retryDelay == 0` (the field's default): with no sleep to interrupt, nothing
    /// between that decision and the next `runToolWithTimeout` call checks cancellation, so a Stop
    /// landing in that sub-microsecond, no-`await` window can still let one more attempt through. This
    /// mirrors the same generic, unavoidable check-then-act race already accepted (and documented) for
    /// the sub-workflow outer retry loop's own zero-delay case; closing it would need an unconditional
    /// `Task.checkCancellation()` at the top of the loop body, which is not part of this fix.
    nonisolated static func shouldRetryToolFailure(_ error: Error, attempt: Int, maxRetries: Int, isCancelled: Bool) -> Bool {
        guard !isCancelled, attempt < maxRetries else { return false }
        return isTransientToolError(error)
    }
}
