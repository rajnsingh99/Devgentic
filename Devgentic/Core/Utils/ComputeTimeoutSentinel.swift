// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
//
//  ComputeTimeoutSentinel.swift
//  Devgentic
//
//  Shared execution-timeout sentinel that bounds COMPUTE time rather than wall-clock.
//

import Foundation

private let logger = DGLogger(category: "ComputeTimeoutSentinel")

/// Sleeps until **compute** time exceeds a limit, then throws `.executionTimeout`.
///
/// ⚠️ THE POINT: the clock excludes time spent parked awaiting a human. A run that sat for ten
/// minutes because nobody clicked a confirmation button has not misbehaved, and killing it is the
/// wrong answer.
///
/// ⚠️⚠️ This was WORKFLOW-ONLY until now, and that asymmetry was the bug. `WorkflowExecutor`
/// gained the park-aware sentinel on 2026-08-13, and its own doc comment named the profile path's
/// plain `Task.sleep` race as "a live defect" — but only the workflow path was fixed. The profile
/// path (`AgentConnect.streamAgentResponse`, which serves BOTH Chat and Code) kept racing a bare
/// sleep, so every second a user spent reading a tool-confirmation banner was charged against
/// their execution budget. Code mode feels it worst: five of its sixteen preset tools are
/// `requiresConfirmation: true`, so a handful of unhurried approvals could exhaust a 300 s budget
/// before the model had done 300 s of work. Both paths now share this one implementation, so a
/// future fix cannot land on one and miss the other.
///
/// Self-correcting rather than a precomputed deadline: sleep to the nominal deadline, ask how much
/// of that was parked, and if compute has not reached the limit, extend by the shortfall and sleep
/// again. That handles parks beginning AFTER the sentinel is already asleep, which a deadline
/// computed up front cannot.
///
/// ⚠️ Park time is accounted per CONVERSATION, not per operation, so parallel siblings share the
/// credit and a run can over-run its limit when a sibling parked. Deliberate: over-crediting wastes
/// some time, under-crediting kills work that was only ever waiting.
///
/// Returns `Never` — it resolves only by throwing, so it is a sentinel to race real work against.
enum ComputeTimeoutSentinel {

    /// - Parameters:
    ///   - limit: The compute budget in seconds.
    ///   - conversationID: The park-accounting scope. Parks are keyed per conversation by
    ///     `ExecutionSuspensionService`, and every HITL surface (tool confirmation, clarification,
    ///     plan review) accrues into it — not just workflow nodes.
    ///   - logTag: Bracket tag for the emitted logs, e.g. `WF_TIMEOUT` or `EXEC_LIMITS`. Callers
    ///     keep their own vocabulary so existing log greps still match.
    ///   - subject: What is being bounded, e.g. `Node 'Summarise'` or `Conversation ab12cd34 (code)`.
    ///   - consequence: What happens when the budget is exhausted, for the CONSEQUENCE clause.
    static func sleepUntilComputeExceeded(
        limit: TimeInterval,
        conversationID: UUID,
        logTag: String,
        subject: String,
        consequence: String
    ) async throws -> Never {
        let start = Date()
        let parkedAtStart = await ExecutionSuspensionService.shared.cumulativeParkedTime(for: conversationID)
        var remaining = limit

        while true {
            try await Task.sleep(for: .seconds(remaining))
            let parked = await ExecutionSuspensionService.shared
                .cumulativeParkedTime(for: conversationID) - parkedAtStart
            let wall = Date().timeIntervalSince(start)
            let compute = wall - parked

            if compute >= limit {
                logger.error("[\(logTag)] \(subject) exceeded its \(Int(limit))s compute budget (\(Int(compute))s compute, \(Int(parked))s parked awaiting a human, \(Int(wall))s wall-clock). CONSEQUENCE: \(consequence)")
                throw AgentExecutionError(reason: .executionTimeout(elapsed: compute, limit: limit))
            }

            remaining = limit - compute
            logger.info("[\(logTag)] \(subject) timeout extended by \(Int(remaining))s — \(Int(parked))s of the elapsed \(Int(wall))s was spent awaiting a human, which does not count against the compute budget.")
        }
    }
}
