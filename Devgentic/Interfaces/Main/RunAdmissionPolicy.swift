// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2026 Raj Singh
//
//  RunAdmissionPolicy.swift
//  Devgentic
//
//  Whether a new run may START. The claim-SIDE half of run ownership.
//
//  ⚠️ INTERIM AND DELIBERATELY PARTIAL. Today this answers exactly one question — "may a Redo /
//  Retry start in this conversation right now?" — because that is the one unguarded claim path
//  that can put two root runs in one conversation. `LLM_Execution_Concurrency_Design.md` increment 4
//  grows this same type into general admission control (queueing for MLX contention and inbound
//  ChatOps, child/depth limits, and a `.queued` verdict beside `.refused`). It is named for what it
//  becomes so that increment extends it rather than replacing it.
//
//  WHY A CLAIM-SIDE POLICY AT ALL. Increment 1 removed the stored `streamingMessageID` slot and made
//  the foreground run a derived query, which killed the clear-side clobber outright. It did NOT kill
//  this:
//
//      activeTasks[agentMessage.id] = streamTask      // ActiveStreamManager
//
//  `activeTasks` is the only cancellable handle for an entire run tree, and it is keyed by MESSAGE.
//  Redo and Resume stream into a pre-existing message (`updating:`), so a second run on the same
//  message OVERWRITES the first run's task handle — after which the first `Task` is unreachable by
//  `cancelStream(for:)` forever. Not mis-targeted by Stop: permanently uncancellable by any code
//  path in the app, still burning tokens and still holding an MLX container. No clear-side guard
//  reaches that; only refusing the second claim does.
//
//  THE RULE (owner decision, 2026-08-17): at most one ROOT run per conversation. That is what makes
//  "the conversation is the thing you stop" true by construction rather than by convention. Workflow
//  nodes, sub-workflows, planning subtasks and sub-agents are NOT root runs — they are children of
//  the conversation's one root run and are unaffected by this policy.
//
//  Kept pure (`nonisolated static` over plain values) so the rule is unit-testable with no view
//  model, no `ActiveStreamManager` and no `ChatMessage` — the `MLXService.isResident(...)` shape.
//

import Foundation

enum RunAdmissionPolicy {

    /// Why a claim was refused. `nil` from `admitRegeneration` means admitted.
    enum Refusal: Equatable, Sendable {

        /// The conversation already has a live run. Transient — the button re-enables when it ends.
        case conversationBusy(existingMessageID: UUID)

        /// This message has used all its regeneration attempts. Permanent for this message.
        case attemptCapReached(attempts: Int, cap: Int)

        /// Nothing to regenerate — the message carries no agent response.
        case noResponseToRegenerate

        /// Shown to the user (tooltip on the disabled control). Must not name internal ids.
        var userFacingReason: String {
            switch self {
            case .conversationBusy:
                return "Wait for the current response to finish, or press Stop."
            case .attemptCapReached(_, let cap):
                return "This message has reached its limit of \(cap) attempts."
            case .noResponseToRegenerate:
                return "There is no response to regenerate."
            }
        }

        /// Logged with the consequence, per the project logging standard.
        var logReason: String {
            switch self {
            case .conversationBusy(let existing):
                return "conversation already has a live run (\(existing.uuidString.prefix(8))). "
                     + "CONSEQUENCE: the Redo is refused rather than started — starting it would "
                     + "overwrite that run's entry in ActiveStreamManager.activeTasks and leave it "
                     + "permanently uncancellable."
            case .attemptCapReached(let attempts, let cap):
                return "attempt cap reached (\(attempts)/\(cap)). CONSEQUENCE: no variant is "
                     + "appended and no run starts."
            case .noResponseToRegenerate:
                return "message carries no agentResponse. CONSEQUENCE: nothing to regenerate; "
                     + "no run starts."
            }
        }
    }

    /// May a regeneration (Redo / Retry) start for a message in `conversation`?
    ///
    /// Returns `nil` to admit, or the reason to refuse. Total, deterministic, side-effect free.
    ///
    /// Checks the attempt cap BEFORE business: the cap is permanent for this message and the busy
    /// state is transient, so when both apply the permanent reason is the more useful thing to
    /// tell the user — waiting would not help them.
    ///
    /// `live` is every live run app-wide; only runs in `conversation` are considered, so a run
    /// streaming in a DIFFERENT conversation never blocks a Redo here. That is the same scope
    /// boundary `ForegroundRunResolver` encodes for Stop.
    ///
    /// ⚠️ A run on this very message counts as busy. That is the primary case — Redo pressed while
    /// the message it targets is still streaming.
    nonisolated static func admitRegeneration(
        in conversation: UUID,
        attempts: Int?,
        cap: Int = ChatMessage.maxGenerationAttempts,
        live: [ForegroundRunResolver.LiveRun]
    ) -> Refusal? {
        guard let attempts else { return .noResponseToRegenerate }
        guard attempts < cap else { return .attemptCapReached(attempts: attempts, cap: cap) }
        return conversationBusy(in: conversation, live: live)
    }

    /// May a RESUME (the interrupted-run chip) start for a message in `conversation`?
    ///
    /// The same one-root-run-per-conversation rule, WITHOUT the attempt cap: a resume re-enters the
    /// original run rather than appending a variant, so it never calls `beginRegenerationVariant`
    /// and never consumes a generation attempt. Folding the cap in here would refuse a legitimate
    /// post-crash resume on a message that had simply been retried five times before the crash.
    ///
    /// ⚠️ The case this exists for is a RACE, not a scope failure. `resumeRun` hops through
    /// `Task { await resolveBackendHistory… }` before claiming the stream, and the chip stays live
    /// throughout that hop because the message has not started streaming yet — so a double-press
    /// starts two runs on ONE message and the second overwrites the first's entry in
    /// `ActiveStreamManager.activeTasks`, orphaning it permanently. Enforcing this AFTER the hop is
    /// what closes the window.
    nonisolated static func admitResume(
        in conversation: UUID,
        live: [ForegroundRunResolver.LiveRun]
    ) -> Refusal? {
        conversationBusy(in: conversation, live: live)
    }

    /// The shared rule: at most one ROOT run per conversation.
    ///
    /// Deterministic — reports the earliest-started blocker, so the log names the same run on every
    /// press rather than whichever the dictionary happened to yield first.
    nonisolated static func conversationBusy(
        in conversation: UUID,
        live: [ForegroundRunResolver.LiveRun]
    ) -> Refusal? {
        let blocking = ForegroundRunResolver.liveRuns(in: conversation, from: live)
        guard let existing = blocking.min(by: {
            $0.startedAt != $1.startedAt ? $0.startedAt < $1.startedAt
                                         : $0.messageID.uuidString < $1.messageID.uuidString
        }) else { return nil }
        return .conversationBusy(existingMessageID: existing.messageID)
    }
}
