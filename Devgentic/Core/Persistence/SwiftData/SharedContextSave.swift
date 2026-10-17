// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
//
//  SharedContextSave.swift
//  Devgentic
//
//  The ONE way a store saves a SwiftData context (RAG-27 / CR-69).
//
//  Every store — chat, profiles, prompts, MCP tools, run history, downloads, scheduler, skills,
//  workflow layouts — is configured with the SAME container and saves its `mainContext`. A save
//  commits every pending change in that context, not just the caller's.
//
//  ⚠️⚠️ A failed save CANNOT be undone in place. SwiftData's `rollback()` after a failed save leaves
//  the failed change in the context (a failed insert keeps failing every later save; a changed
//  value is not restored) — proven and pinned by `SharedContextCommitTests`. So when a failure is
//  persistent (an invalid object, an external-storage clone error, a full disk), EVERY later save
//  from EVERY store fails with it until the app is relaunched, which is the only recovery.
//
//  What this does about it is make the failure impossible to miss: the first failure on a context
//  latches it, logs, and posts ONE app-wide advisory saying changes are not being saved and since
//  when; the next successful save of that context clears it. A transient failure therefore costs a
//  banner that disappears with the next good save — the failed change is still pending and goes
//  out with it — and a persistent one tells the user to restart rather than letting them work for
//  an hour on writes that will vanish.
//

import Foundation
import SwiftData

private let logger = DGLogger(category: "SharedContextSave")

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

    /// Saves `context`. On failure: latches it, posts the app-wide advisory, logs, and rethrows.
    /// Callers keep their own failure log — they know what the lost write MEANT to the user.
    ///
    /// - Parameter label: the write, for the log ("chat: upsert 2 message(s) → conv 1A2B3C4D").
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
