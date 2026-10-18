// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
//
//  SharedContextSave.swift
//  Devgentic
//
//  Created by Raj Singh.
//

import Foundation
import SwiftData

private let logger = DGLogger(category: "SharedContextSave")

// Why: a failed save cannot be undone in place: rollback() keeps the failed change,
// so a persistent failure fails every later save until relaunch.
/// The single path through which every store saves its SwiftData `mainContext`.
/// The first failure on a context is logged and raises one app-wide advisory that changes are not being saved.
/// The next successful save of that context clears it.
@MainActor
enum SharedContextSave {

    /// Whether the context outlives this write.
    enum Scope {
        /// A long-lived context (`mainContext`): a failure leaves its changes pending, so it latches.
        case shared
        /// A context made for this one write and discarded after it: a failure leaves nothing
        /// behind, so it is logged and thrown but never latched (it could never be cleared).
        case throwaway
    }

    /// Contexts whose last save failed → when they started failing.
    private static var failingSince: [ObjectIdentifier: Date] = [:]

    /// Saves `context`. On failure: latches it, posts the app-wide advisory, logs, and rethrows. Callers keep their own
    /// failure log. - Parameter label: the write, for the log ("chat: upsert 2 message(s) → conv 1A2B3C4D").
    static func save(_ context: ModelContext, _ label: @autoclosure () -> String, scope: Scope = .shared) throws {
        let key = ObjectIdentifier(context)
        do {
            try context.save()
        } catch {
            guard scope == .shared else {
                logger.error("[PERSISTENCE] \(label()): save FAILED in a throwaway context (\(error.localizedDescription)). CONSEQUENCE: this write is not on disk; the context is discarded, so nothing stays pending and no other save is affected.")
                throw error
            }
            let since = failingSince[key] ?? Date()
            let isFirst = failingSince[key] == nil
            failingSince[key] = since
            logger.error("[PERSISTENCE] \(label()): save FAILED (\(error.localizedDescription))\(isFirst ? " — FIRST failure on this context" : " — failing since \(since)"). CONSEQUENCE: this change is NOT on disk and stays pending on the shared context (a failed save cannot be rolled back — SharedContextCommitTests). If the failure persists, EVERY later save from every store fails with it until relaunch; the user is told by the app-wide 'changes are not being saved' advisory.")
            postAdvisory(since: since)
            throw error
        }
        if let since = failingSince.removeValue(forKey: key) {
            logger.notice("[PERSISTENCE] \(label()): saving RECOVERED (it had been failing since \(since)). CONSEQUENCE: everything left pending by the failed saves went to disk with this one; the advisory is cleared.")
            if failingSince.isEmpty {
                AdvisoryCenter.shared.clear(category: .changesNotSaved, conversationID: Advisory.allConversations)
            }
        }
    }

    /// True while any shared context's last save failed.
    static var isFailing: Bool { !failingSince.isEmpty }

    private static func postAdvisory(since: Date) {
        let time = since.formatted(date: .omitted, time: .shortened)
        AdvisoryCenter.shared.post(Advisory(
            conversationID: Advisory.allConversations,
            category: .changesNotSaved,
            message: "Devgentic can't save changes. Restart the app to recover — anything changed since \(time) is not on disk yet.",
            actionLabel: nil,
            action: nil,
            // Keyed on the episode, so dismissing it does not silence a LATER failure.
            dedupeKey: "changesNotSaved|\(since.timeIntervalSince1970)"
        ))
    }

    #if DEBUG
    static func resetForTesting() {
        failingSince.removeAll()
        AdvisoryCenter.shared.clear(category: .changesNotSaved, conversationID: Advisory.allConversations)
    }
    #endif
}
