// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
//
//  UserSkipTeardownPolicy.swift
//  Devgentic
//
//  Created by Raj Singh.
//

import Foundation

/// The typed signal `WorkflowExecutor.runningSkipSentinel` throws when the user skips a running node.
/// Distinct from `CancellationError` (Stop or group teardown) and `AgentExecutionError(.executionTimeout)`, so the
/// three interruptions stay separately classifiable.
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

    // Why: Stop always wins: `externallyCancelled` is checked first, since a `.skipped` pass-through row would keep downstream
    // edges live inside a teardown the user asked for.
    /// Classifies how an interrupted node run should settle.
    /// `externallyCancelled` is `Task.isCancelled` on the node's own task (outside cancellation only, never the racer group);
    /// `skipFired` is the store record of a running-skip firing, repairing the race where the work child cancelled first.
    nonisolated static func classify(
        caughtSkipSignal: Bool,
        externallyCancelled: Bool,
        skipFired: Bool
    ) -> Verdict {
        if externallyCancelled { return .cancelled }
        if caughtSkipSignal { return .skippedByUser }
        if skipFired { return .skippedByUser }
        // A CancellationError with no external cancellation and no skip on record (an inner stream error or teardown
        // noise): nothing says "skip", so `.cancelled` is the honest floor.
        return .cancelled
    }
}
