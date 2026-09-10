// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2026 Raj Singh
//
//  UserSkipTeardownPolicy.swift
//  Devgentic
//
//  The RUNNING-skip teardown verdict — Phase B increment 5 of the per-node skip design
//  (`LLM_Execution_Concurrency_Design.md` §0.6 D2.1).
//
//  A running-skip interrupts the node through the SAME mechanism as everything else that ends a
//  node early: cooperative cancellation racing through `executeNode`'s task group. That signal is
//  ambiguous by construction — the identical `CancellationError` can mean "user pressed Stop"
//  (downstream must die), or be the teardown echo of a skip whose typed signal lost the
//  `group.next()` race (downstream must LIVE and receive the pass-through). Misreading the first
//  as a skip keeps a run alive that the user tried to kill; misreading the second as a Stop turns
//  the Skip button into a lying Stop.
//
//  Extracted as a pure function for the same reason `WorkflowRetryPolicy.stopsRetrying` was: the
//  repair arm (skip fired but the work child's CancellationError surfaced first) is a race window
//  no end-to-end test can hit on demand, so the decision is verified exhaustively HERE and the
//  executor merely plumbs it. See `UserSkipTeardownPolicyTests` for the full truth table.
//

import Foundation

/// The typed signal `WorkflowExecutor.runningSkipSentinel` throws when the user skips a RUNNING
/// node. Distinct from `CancellationError` (user Stop / group teardown) and from
/// `AgentExecutionError(.executionTimeout)` (the timeout sentinel) — the catch chain's ordering
/// and this type's existence are what keep the three interruptions separately classifiable.
struct WorkflowNodeSkipRequested: Error {
    let nodeID: UUID
}

enum UserSkipTeardownPolicy {

    enum Verdict: Equatable {
        /// Settle the node `.skipped(reason: .byUser)` with the pass-through envelope.
        case skippedByUser
        /// Settle the node `.canceled` — downstream dies, exactly as for Stop.
        case cancelled
    }

    /// Classifies how an interrupted node run should settle.
    ///
    /// - Parameters:
    ///   - caughtSkipSignal: the catch arm holds a `WorkflowNodeSkipRequested` (the typed signal
    ///     won the `group.next()` race — the overwhelmingly common skip path).
    ///   - externallyCancelled: `Task.isCancelled` on the NODE's own task. The racer group
    ///     cancelling its children never sets this — only cancellation inherited from outside
    ///     (Stop, conversation deletion, a scheduled run's deadline) does. That asymmetry is the
    ///     whole discriminator.
    ///   - skipFired: the store recorded a running-skip firing for this node
    ///     (`WorkflowNodeSkipStore.runningSkipFired`) — the repair signal for the race where the
    ///     work child's own `CancellationError` surfaced before the typed throw.
    ///
    /// ⚠️ STOP ALWAYS WINS. `externallyCancelled` is checked first regardless of the other two:
    /// if the user pressed Stop while a skip was in flight, the run is dying — reporting the node
    /// `.skipped` would put a live-looking pass-through row in a run the user killed, and (worse)
    /// its envelope would keep downstream edges live inside a teardown. A user skip is an
    /// instruction to CONTINUE without this node; Stop is an instruction to continue with nothing.
    nonisolated static func classify(
        caughtSkipSignal: Bool,
        externallyCancelled: Bool,
        skipFired: Bool
    ) -> Verdict {
        if externallyCancelled { return .cancelled }
        if caughtSkipSignal { return .skippedByUser }
        if skipFired { return .skippedByUser }
        // A CancellationError with no external cancellation and no skip on record: an inner
        // stream error-typed as CancellationError, or teardown noise. Nothing says "skip", so
        // nothing may claim one — `.canceled` is the honest floor.
        return .cancelled
    }
}
