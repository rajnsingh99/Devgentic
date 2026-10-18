// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
//
//  RunAdmissionPolicy.swift
//  Devgentic
//
//  Created by Raj Singh.
//

import Foundation

// Why: `activeTasks` is keyed by message, so a second run on the same message overwrites the first's
// task handle and leaves it uncancellable.
/// Decides whether a new run may start: at most one root run per conversation.
/// Workflow nodes, sub-workflows, planning subtasks and sub-agents are children of the root run and unaffected.
/// Pure over plain values.
enum RunAdmissionPolicy {

    /// Why a claim was refused. `nil` from `admitRegeneration` means admitted.
    enum Refusal: Equatable, Sendable {

        /// The conversation already has a live run. Transient — the button re-enables when it ends.
        case conversationBusy(existingMessageID: UUID)

        /// This message has used all its regeneration attempts. Permanent for this message.
        case attemptCapReached(attempts: Int, cap: Int)

        /// Nothing to regenerate — the message carries no agent response.
        case noResponseToRegenerate

        /// A background-task report whose stub saved no task card: the output it reported on was never persisted, so a redo would
        /// report on nothing. Permanent.
        case reportOutputNotSaved

        /// A background task this turn started is still running. Transient — the button re-enables
        /// when it ends. Redo would re-run the request beside it: a second build racing the first.
        case backgroundTaskRunning(taskID: String)

        /// Shown to the user (tooltip on the disabled control). Must not name internal ids.
        var userFacingReason: String {
            switch self {
            case .conversationBusy:
                return "Wait for the current response to finish, or press Stop."
            case .attemptCapReached(_, let cap):
                return "This message has reached its limit of \(cap) attempts."
            case .noResponseToRegenerate:
                return "There is no response to regenerate."
            case .reportOutputNotSaved:
                return "This report was saved before its task's output was kept, so it can't be redone."
            case .backgroundTaskRunning:
                return "A background task this response started is still running. Stop it or wait for it to finish."
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
            case .backgroundTaskRunning(let taskID):
                return "background task \(taskID), started by this response, is still running. "
                     + "CONSEQUENCE: the Redo is refused — it would re-run the request beside the "
                     + "task, e.g. a second build racing the first."
            case .reportOutputNotSaved:
                return "it is a background-task report whose stub saved no task card. CONSEQUENCE: "
                     + "no run starts — the only thing left to re-ask from is the one-line stub, "
                     + "and a report on that is a report on nothing."
            }
        }
    }

    /// May a regeneration (Redo / Retry) start for a message in `conversation`?
    /// Returns `nil` to admit, or the reason to refuse; total, deterministic and side-effect free.
    /// Cap is checked before busy (permanent beats transient); only runs in `conversation` count, including this message's.
    nonisolated static func admitRegeneration(
        in conversation: UUID,
        attempts: Int?,
        cap: Int = ChatMessage.maxGenerationAttempts,
        live: [ForegroundRunResolver.LiveRun]
    ) -> Refusal? {
        admitRegeneration(in: conversation, attempts: attempts, cap: cap, live: live,
                          isReport: false, reportCardSaved: false, runningTaskID: nil)
    }

    /// The same, for a message that may be a background-task report. A report redoes from the task
    /// card its stub saved; without one it is refused (`.reportOutputNotSaved`), checked after the
    /// cap and before business, since it is permanent too.
    nonisolated static func admitRegeneration(
        in conversation: UUID,
        attempts: Int?,
        cap: Int = ChatMessage.maxGenerationAttempts,
        live: [ForegroundRunResolver.LiveRun],
        isReport: Bool,
        reportCardSaved: Bool,
        runningTaskID: String? = nil
    ) -> Refusal? {
        guard let attempts else { return .noResponseToRegenerate }
        guard attempts < cap else { return .attemptCapReached(attempts: attempts, cap: cap) }
        if isReport && !reportCardSaved { return .reportOutputNotSaved }
        if let busy = conversationBusy(in: conversation, live: live) { return busy }
        return runningTaskID.map { .backgroundTaskRunning(taskID: $0) }
    }

    /// May a resume start for a message in `conversation`?
    /// The same one-root-run rule, without the attempt cap: a resume re-enters the original run, consuming no attempt.
    /// Enforce it after the history hop: the chip stays live through it, so a double-press could start two runs.
    nonisolated static func admitResume(
        in conversation: UUID,
        live: [ForegroundRunResolver.LiveRun]
    ) -> Refusal? {
        conversationBusy(in: conversation, live: live)
    }

    /// The shared rule: at most one root run per conversation.
    /// Deterministic: reports the earliest-started blocker so the log names the same run on every press.
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
