// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
//
//  ConversationAdmission.swift
//  Devgentic
//
//  Created by Raj Singh.
//

import Foundation
import os

private let logger = DGLogger(category: "ConversationAdmission")

// Why: keep this a MainActor class, not an actor: a hop between the busy check and the enqueue lets a second run slip through.
/// Serialises runs so at most one runs per conversation at a time; later arrivals queue rather than being dropped.
/// A ChatOps message or scheduled task is therefore never lost to a refusal.
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

    /// Whether this run is parked here waiting for its turn, i.e. a queued run that Stop must not prefer
    /// over the one actually working.
    func isWaiting(_ messageID: UUID) -> Bool { waiters[messageID] != nil }

    /// How many runs are waiting in a conversation. Diagnostics and tests.
    func waitingCount(inConversation conversationID: UUID) -> Int {
        queue[conversationID]?.count ?? 0
    }

    // Why: also parks when the conversation looks idle but a queue exists, so an arrival cannot overtake queued runs.
    /// Parks until this conversation has no other live run; returns immediately when it is free.
    /// - Parameter onWait: called only if this run actually parks, before it suspends.
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

    // Why: call after the finishing run leaves the live set, or the admitted run parks again with nothing left to wake it.
    /// Admits the next waiter. Call wherever a run leaves the live set.
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

    // Why: teardown only: `withCheckedContinuation` is not cancellation-aware, so a cancelled parked task would never resume.
    /// Releases every waiter in a conversation, in order, without waiting for turns.
    /// Each body then exits through its own cancellation check.
    func releaseAll(inConversation conversationID: UUID) {
        guard let waiting = queue.removeValue(forKey: conversationID), !waiting.isEmpty else { return }
        for messageID in waiting {
            waiters.removeValue(forKey: messageID)?.resume()
        }
        logger.info("[ADMISSION] Released \(waiting.count) waiting run(s) in conversation \(conversationID.uuidString.prefix(8)) — it is being cancelled or deleted.")
    }

    /// Withdraws one run without admitting it.
    /// Removes the waiter only, leaving the id queued for `admitNext` to skip.
    func forget(messageID: UUID, inConversation conversationID: UUID) {
        waiters.removeValue(forKey: messageID)?.resume()
    }
}
