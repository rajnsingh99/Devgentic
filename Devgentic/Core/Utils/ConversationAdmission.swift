// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
//
//  ConversationAdmission.swift
//  Devgentic
//
//  One run at a time, per conversation.
//
//  ⚠️⚠️ TWO CONCURRENT RUNS IN ONE CONVERSATION WAS REACHABLE AND UNGUARDED.
//
//  The only thing preventing it was the composer greying out its send button while streaming —
//  a property of the TEXT BOX, not of the engine. `SchedulerCoordinator`, Orb and the ChatOps
//  bridge call `ActiveStreamManager` directly, and no button is involved.
//  `ActiveStreamManager.deriveHistory` already admitted this in its own comment: *"Concurrency in
//  one conversation is reachable: the scheduler, Orb and the ChatOps bridge carry no admission
//  check."* — and then worked AROUND it, excluding concurrent half-written turns from history so
//  `pairTurns` would stop reporting a live question as answered with nothing.
//
//  Nothing ever threw. `activeStreams` is keyed by MESSAGE id, so two runs in one conversation are
//  a perfectly valid state. What actually happened: two agents reading the same history, calling
//  tools against the same files, writing into one transcript, at double the token cost.
//
//  ── Queue, never drop ───────────────────────────────────────────────────────────────────
//
//  Refusing the second run is the obvious design and it is wrong here. A ChatOps message that is
//  refused is a USER'S MESSAGE thrown away; a refused scheduled task makes schedules silently
//  unreliable. A late answer is recoverable, a discarded one is not — so arrivals serialise.
//
//  ── Why this is not an actor ────────────────────────────────────────────────────────────
//
//  `@MainActor` because `ActiveStreamManager` is, and the busy test reads its `activeStreams`.
//  Making this an actor would put a hop between the check and the enqueue — and that gap is
//  exactly where a second run slips through.
//

import Foundation
import os

private let logger = DGLogger(category: "ConversationAdmission")

@MainActor
final class ConversationAdmission {

    /// Message ids waiting for their conversation, oldest first.
    private var queue: [UUID: [UUID]] = [:]

    /// messageID → the continuation that resumes when its turn comes.
    private var waiters: [UUID: CheckedContinuation<Void, Never>] = [:]

    /// Answers "is some OTHER run live in this conversation". Injected so this type owns the
    /// queueing policy and nothing else, and so tests do not need a running backend to exercise it.
    private let isBusy: (_ conversationID: UUID, _ excluding: UUID) -> Bool

    init(isBusy: @escaping (_ conversationID: UUID, _ excluding: UUID) -> Bool) {
        self.isBusy = isBusy
    }

    /// How many runs are waiting in a conversation. Diagnostics and tests.
    func waitingCount(inConversation conversationID: UUID) -> Int {
        queue[conversationID]?.count ?? 0
    }

    /// Parks until this conversation has no other live run. Returns immediately when it is free.
    ///
    /// ⚠️ Also parks when the conversation looks IDLE but a queue exists. A caller that queues
    /// BEFORE it appears in the live set leaves exactly that window: `isBusy` says no, and a run
    /// arriving in it would jump the whole queue. The ChatOps message that has waited longest is
    /// precisely the one that must not be starved, so the queue's mere existence is enough to
    /// park — see `testAnArrivalDoesNotOvertakeAQueueWhenTheConversationLooksIdle`.
    /// - Parameter onWait: called ONLY if this run actually parks, before it suspends. The caller
    ///   uses it to say so on screen — see `AgentState.ThinkingDetail.queued`. A caller cannot ask
    ///   "will I wait?" beforehand without a second lookup that could disagree with this one.
    /// - Returns: whether it parked, so the caller can undo whatever `onWait` did.
    @discardableResult
    func awaitTurn(conversationID: UUID,
                   messageID: UUID,
                   onWait: () -> Void = {}) async -> Bool {
        let hasQueue = !(queue[conversationID]?.isEmpty ?? true)
        guard isBusy(conversationID, messageID) || hasQueue else { return false }

        queue[conversationID, default: []].append(messageID)
        logger.notice("[ADMISSION] Run \(messageID.uuidString.prefix(8)) is WAITING — conversation \(conversationID.uuidString.prefix(8)) already has a run in flight (\(self.queue[conversationID]?.count ?? 0) queued). CONSEQUENCE: it starts when the current run ends, instead of running concurrently and interleaving its tool calls and history with the other's.")
        onWait()
        await withCheckedContinuation { continuation in
            waiters[messageID] = continuation
        }
        return true
    }

    /// Admits the next waiter. Call wherever a run leaves the live set.
    ///
    /// ⚠️ Must be called AFTER the finishing run has been removed from the live set, or the run it
    /// admits sees a conversation that still looks occupied, parks again, and nothing is left to
    /// wake it.
    func admitNext(inConversation conversationID: UUID) {
        guard var waiting = queue[conversationID], !waiting.isEmpty else { return }
        let next = waiting.removeFirst()
        queue[conversationID] = waiting.isEmpty ? nil : waiting
        guard let continuation = waiters.removeValue(forKey: next) else {
            // The waiter was torn down between being queued and being admitted. Keep going, or one
            // stale id would block every run behind it.
            logger.notice("[ADMISSION] Queued run \(next.uuidString.prefix(8)) had no waiter — skipping to the next. CONSEQUENCE: the queue advances instead of stalling behind an id whose task is already gone.")
            admitNext(inConversation: conversationID)
            return
        }
        logger.info("[ADMISSION] Admitting queued run \(next.uuidString.prefix(8)) in conversation \(conversationID.uuidString.prefix(8)).")
        continuation.resume()
    }

    /// Releases every waiter in a conversation, in order, without waiting for turns.
    ///
    /// ⚠️ TEARDOWN ONLY (cancel, delete). `withCheckedContinuation` is NOT cancellation-aware: a
    /// parked task whose stream is cancelled would never resume, leaking its continuation for the
    /// life of the process and hanging anything awaiting that task. Resuming lets each body run on
    /// and exit through its own cancellation check.
    func releaseAll(inConversation conversationID: UUID) {
        guard let waiting = queue.removeValue(forKey: conversationID), !waiting.isEmpty else { return }
        for messageID in waiting {
            waiters.removeValue(forKey: messageID)?.resume()
        }
        logger.info("[ADMISSION] Released \(waiting.count) waiting run(s) in conversation \(conversationID.uuidString.prefix(8)) — it is being cancelled or deleted.")
    }

    /// Withdraws one run without admitting it.
    ///
    /// ⚠️ Removes the WAITER only, deliberately leaving the id in the queue for `admitNext` to skip.
    /// The first version removed it from both, which meant `admitNext`'s skip guarded a state
    /// nothing could produce — mutation deleted that skip and every test stayed green. Two
    /// mechanisms for one job means neither is tested; this leaves exactly one, and it is the one
    /// a future caller that drops a waiter without dequeuing will also need.
    func forget(messageID: UUID, inConversation conversationID: UUID) {
        waiters.removeValue(forKey: messageID)?.resume()
    }
}
