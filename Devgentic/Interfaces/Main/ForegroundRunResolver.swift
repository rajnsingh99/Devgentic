// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
//
//  ForegroundRunResolver.swift
//  Devgentic
//
//  Created by Raj Singh.
//

import Foundation

// Why: derived, never stored: a stored slot let one run clobber another's claim.
/// Resolves which in-flight run the main window's composer is talking about (Stop target, Send vs Stop).
/// A pure `nonisolated static` derivation over plain values: a run is bound to a conversation, and the composer
/// stops only the run in the conversation being viewed.
enum ForegroundRunResolver {

    /// One in-flight run, reduced to just what the foreground decision needs.
    /// Not `ChatMessage`, so the decision can be tested without constructing a message graph.
    struct LiveRun: Equatable, Sendable {
        /// The message this run streams into. Note this is NOT a run id — Redo and Resume reuse the
        /// same message, which is the root defect this increment begins to unwind. It is the
        /// correct *cancellation* key today because `ActiveStreamManager.activeTasks` is keyed on it.
        let messageID: UUID
        let conversationID: UUID
        /// When this run CLAIMED the stream — not when its message was created. The two differ for
        /// Redo and Resume, which stream into a pre-existing (possibly hours-old) message.
        let startedAt: Date
        /// Parked on a HITL rather than actively generating.
        /// Parked runs are still stoppable: Stop must dismiss the work behind the user's banner.
        /// Can read stale after a HITL resolves (`lifecycleState` is not reset); it only affects the tie-break below.
        let isParked: Bool
        // Why: a queued run is registered before it waits, so Stop would otherwise target it instead of the working run.
        /// Waiting in `ConversationAdmission` for this conversation's current run to finish; it has done no work yet.
        var isQueued: Bool = false
    }

    /// Every live run belonging to `conversation`, in no particular order.
    /// Separate from `foregroundRun` so callers can detect and log two live runs in one conversation.
    nonisolated static func liveRuns(in conversation: UUID?, from live: [LiveRun]) -> [LiveRun] {
        guard let conversation else { return [] }
        return live.filter { $0.conversationID == conversation }
    }

    // Why: queued ranks last: the run in front is the one the user means to stop,
    // and stopping a parked run must cancel its own task so its approval is not recorded as a denial.
    /// The run the composer is talking about, or `nil` to show Send.
    /// `nil` for a conversation the user is not viewing is intended: background runs do not lock the composer.
    /// Ties break: actively streaming, then parked, then queued, then most recently started, then lowest message id.
    nonisolated static func foregroundRun(live: [LiveRun], selectedConversation: UUID?) -> LiveRun? {
        let candidates = liveRuns(in: selectedConversation, from: live)
        if candidates.count <= 1 { return candidates.first }
        return candidates.max { a, b in
            if rank(a) != rank(b) { return rank(a) < rank(b) }
            if a.startedAt != b.startedAt { return a.startedAt < b.startedAt }
            return a.messageID.uuidString < b.messageID.uuidString
        }
    }

    /// Higher is the better Stop target: working, then waiting on the user, then not started.
    private nonisolated static func rank(_ run: LiveRun) -> Int {
        if run.isQueued { return 0 }
        return run.isParked ? 1 : 2
    }
}
