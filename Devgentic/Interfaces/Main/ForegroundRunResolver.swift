// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2026 Raj Singh
//
//  ForegroundRunResolver.swift
//  Devgentic
//
//  Which in-flight run the main window's composer is talking about — i.e. what Stop targets and
//  whether the send button shows Send or Stop.
//
//  ⚠️ THIS EXISTS BECAUSE THE ANSWER USED TO BE *STORED*.
//
//  `MainApplicationViewModel` held `streamingMessageID` / `streamingMessage` as two bare `var`s.
//  Five surfaces wrote them (chat send, Redo, Resume, ChatOps, scheduler) and five cleared them,
//  and none of the ten carried an identity guard. Two consequences, both reproducible with no
//  automation at all:
//
//    • WRITE-SIDE CLOBBER — a newer run overwrote an older run's claim, so Stop hit the wrong run.
//    • CLEAR-SIDE CLOBBER — whichever run finished FIRST nil'd the slot regardless of ownership,
//      so the composer flipped back to Send while another run was still streaming and that run
//      became permanently unstoppable from the UI. This needed no Stop press to occur.
//
//  ⚠️ A CLEAR-SIDE IDENTITY GUARD DOES NOT FIX THIS, and that is why this file is a *deletion* of
//  state rather than a guard on it. Trace the guard: slot = W → S overwrites → Stop kills S → S
//  completes and *legitimately* holds the slot → the guard passes → the slot is nil'd → W is
//  orphaned. The guard is correct and the bug survives it. Only removing the storage removes the
//  race, because a derived value has no write site to clobber and no clear site to lose.
//
//  THE RULE THIS ENCODES (owner decision, 2026-08-17): **a run is bound to a conversation, and the
//  conversation is the unit of interaction.** The composer stops the run in the conversation you
//  are looking at, and nothing else. Switch away and you can no longer stop it from here — that is
//  a deliberate UI boundary, not a limitation. Five conversations can stream at once, each
//  stoppable only from inside itself.
//
//  Kept as a pure `nonisolated static` over plain values, with no view model and no
//  `ActiveStreamManager` in the signature, precisely so the boundary rule itself is unit-testable
//  offline — see `ForegroundRunResolverTests`. This mirrors `MLXService.isResident(...)` and
//  `MessagingCoordinator.historySlice(...)`, the codebase's established shape for "policy in a pure
//  function, effects in the actor".
//
//  Design + migration context: repo-root `LLM_Execution_Concurrency_Design.md` (increment 1).
//

import Foundation

enum ForegroundRunResolver {

    /// One in-flight run, reduced to just what the foreground decision needs.
    ///
    /// Deliberately NOT `ChatMessage`: the decision must be expressible without the message graph
    /// so it can be tested without constructing one.
    struct LiveRun: Equatable, Sendable {
        /// The message this run streams into. Note this is NOT a run id — Redo and Resume reuse the
        /// same message, which is the root defect this increment begins to unwind. It is the
        /// correct *cancellation* key today because `ActiveStreamManager.activeTasks` is keyed on it.
        let messageID: UUID
        let conversationID: UUID
        /// When this run CLAIMED the stream — not when its message was created. The two differ for
        /// Redo and Resume, which stream into a pre-existing (possibly hours-old) message.
        let startedAt: Date
        /// Parked on a HITL rather than actively generating. Parked runs are still stoppable — the
        /// user is looking at a banner and Stop must dismiss the work behind it.
        ///
        /// ⚠️ Reads stale in one known case: `ChatMessage.lifecycleState` is never reset from
        /// `.parkedHITL` back to `.streaming` after a HITL resolves, so a run that answered a
        /// prompt and resumed generating still reports parked. That only affects the tie-break
        /// below (an anomaly path), never whether a run is a candidate, so it is not load-bearing
        /// here. Tracked in `LLM_Execution_Concurrency_Design.md` §7(a).
        let isParked: Bool
    }

    /// Every live run belonging to `conversation`, in no particular order.
    ///
    /// Separate from `foregroundRun` so callers can detect and LOG the anomaly of two live runs in
    /// one conversation, which the product model says must not happen (and which admission control
    /// will refuse outright — design doc increment 4). Until then it is possible via Redo on an
    /// older message while a newer run streams, so it is logged rather than assumed away.
    nonisolated static func liveRuns(in conversation: UUID?, from live: [LiveRun]) -> [LiveRun] {
        guard let conversation else { return [] }
        return live.filter { $0.conversationID == conversation }
    }

    /// The run the composer is talking about, or `nil` to show Send.
    ///
    /// `nil` for a run in a conversation the user is not looking at is the POINT, not a miss: a
    /// background scheduled or ChatOps run no longer locks the composer, and Stop can no longer
    /// reach across conversations to kill it.
    ///
    /// Total, deterministic, and side-effect free. When a conversation somehow holds more than one
    /// live run, prefer an actively-streaming run over a parked one, then the most recently
    /// started, then lowest message id — so the answer never depends on dictionary ordering.
    nonisolated static func foregroundRun(live: [LiveRun], selectedConversation: UUID?) -> LiveRun? {
        let candidates = liveRuns(in: selectedConversation, from: live)
        if candidates.count <= 1 { return candidates.first }
        return candidates.max { a, b in
            if a.isParked != b.isParked { return a.isParked }
            if a.startedAt != b.startedAt { return a.startedAt < b.startedAt }
            return a.messageID.uuidString < b.messageID.uuidString
        }
    }
}
