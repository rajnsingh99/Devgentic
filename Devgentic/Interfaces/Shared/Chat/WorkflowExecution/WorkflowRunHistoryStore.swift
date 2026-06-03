//
//  WorkflowRunHistoryStore.swift
//  Devgentic
//
//  Created by Raj Singh on 11/04/26.
//
//  SwiftData-backed persistence for workflow run history.
//  Keyed by conversation ID — each conversation owns its run history independently.
//  Sliding window: at most `maxRecordsPerConversation` records per conversation;
//  inserts past the cap evict the oldest record.
//
//  Records are stored as `WorkflowRunRecordSD` rows linked to `ConversationSD`
//  via a SwiftData `@Relationship`, so deleting a conversation cascades to its
//  workflow runs automatically.
//
//  Concurrency: `@MainActor`-isolated, matching `BackendProfileStore` and
//  `DownloadHistoryStore`. All current call sites are already `@MainActor`.
//

import Foundation
import SwiftData
import OSLog

private let logger = DGLogger(category: "WorkflowRunHistoryStore")

@MainActor
final class WorkflowRunHistoryStore {

    // MARK: - Singleton

    static let shared = WorkflowRunHistoryStore()
    private init() {}

    // MARK: - Tuning

    private let maxRecordsPerConversation = 20

    // MARK: - SwiftData Container

    private(set) var modelContainer: ModelContainer?

    /// Called once from `DevgenticApp` after the shared `ModelContainer` is built.
    func configureContainer(_ container: ModelContainer) {
        self.modelContainer = container
        logger.info("WorkflowRunHistoryStore configured with SwiftData ModelContainer.")
    }

    private var mainContext: ModelContext? {
        modelContainer?.mainContext
    }

    // MARK: - Public API (matches the old UserDefaults-backed signature)

    /// Loads all run records for a conversation, newest first. Returns `[]` on
    /// miss (no records, no container, or fetch failure).
    func load(forConversation conversationID: UUID) -> [WorkflowRunRecord] {
        guard let context = mainContext else {
            logger.error("load(forConversation:) called before container was configured — returning [].")
            return []
        }

        let predicate = #Predicate<WorkflowRunRecordSD> { $0.conversationID == conversationID }
        let descriptor = FetchDescriptor<WorkflowRunRecordSD>(
            predicate: predicate,
            sortBy: [SortDescriptor(\.timestamp, order: .reverse)]
        )

        do {
            return try context.fetch(descriptor).map(\.record)
        } catch {
            logger.error("Failed to fetch run history for \(conversationID): \(error.localizedDescription)")
            return []
        }
    }

    /// Inserts or updates a run record under the given conversation, keyed by `record.id`.
    ///
    /// Workflow runs are persisted twice during their lifecycle:
    ///   1. At run *start*, `MessagingCoordinator` inserts a stub record with
    ///      `status = .running` so the history list shows the run from frame 1.
    ///   2. At run *end*, the same `record.id` is upserted with the finalized
    ///      `nodeResults`, `finalOutput`, `duration`, and terminal status.
    /// Both paths funnel through this method; the second call finds the existing
    /// row and rewrites it in place.
    ///
    /// On insert, the sliding-window cap is enforced (evicts the oldest if over
    /// `maxRecordsPerConversation`). On update, no eviction happens (we're
    /// mutating a row that's already counted).
    func upsert(_ record: WorkflowRunRecord, forConversation conversationID: UUID) {
        guard let context = mainContext else {
            logger.error("upsert(_:forConversation:) called before container was configured — drop.")
            return
        }

        do {
            let recordID = record.id
            let existingPredicate = #Predicate<WorkflowRunRecordSD> { $0.id == recordID }
            var existingDescriptor = FetchDescriptor<WorkflowRunRecordSD>(predicate: existingPredicate)
            existingDescriptor.fetchLimit = 1

            if let existing = try context.fetch(existingDescriptor).first {
                // Update path — rewrite the row's contents. The `record` computed
                // setter on `WorkflowRunRecordSD` syncs every column + blob.
                existing.record = record
                try context.save()
                logger.info("Updated run \(record.id) for conversation \(conversationID) — status=\(record.status.rawValue).")
                return
            }

            // Insert path
            let conversation = try fetchConversation(id: conversationID, in: context)
            let newRow = WorkflowRunRecordSD(record: record, conversation: conversation)
            context.insert(newRow)

            // Enforce sliding window: fetch the conversation's records sorted oldest-first,
            // delete from the top until we're back under the cap.
            let conversationPredicate = #Predicate<WorkflowRunRecordSD> { $0.conversationID == conversationID }
            let overflowDescriptor = FetchDescriptor<WorkflowRunRecordSD>(
                predicate: conversationPredicate,
                sortBy: [SortDescriptor(\.timestamp, order: .forward)]
            )
            let allForConversation = try context.fetch(overflowDescriptor)
            let overflow = allForConversation.count - maxRecordsPerConversation
            if overflow > 0 {
                for old in allForConversation.prefix(overflow) {
                    context.delete(old)
                }
            }

            try context.save()
            logger.info("Persisted run \(record.id) for conversation \(conversationID) (\(allForConversation.count - max(0, overflow)) total after cap, status=\(record.status.rawValue)).")
        } catch {
            logger.error("Failed to upsert run \(record.id) for \(conversationID): \(error.localizedDescription)")
        }
    }

    // MARK: - Orphan reconciliation

    /// Flips any record still in `.running` to `.cancelled` with an "Interrupted"
    /// error message. By definition no run survives an app termination (the
    /// `WorkflowExecutor` lives in process), so any `.running` row at launch is
    /// from a previous session that crashed, was force-quit, or otherwise ended
    /// before the run could finalize. Mirrors `DownloadHistoryStore.reconcileOrphans`.
    func reconcileOrphans() {
        guard let context = mainContext else {
            logger.error("reconcileOrphans() called before container was configured — skip.")
            return
        }

        let runningRaw = WorkflowRunRecord.RunStatus.running.rawValue
        let predicate = #Predicate<WorkflowRunRecordSD> { $0.statusRaw == runningRaw }
        let descriptor = FetchDescriptor<WorkflowRunRecordSD>(predicate: predicate)

        do {
            let orphans = try context.fetch(descriptor)
            guard !orphans.isEmpty else { return }

            for orphan in orphans {
                orphan.statusRaw = WorkflowRunRecord.RunStatus.cancelled.rawValue
                orphan.errorMessage = orphan.errorMessage ?? "Interrupted"
                // Recompute duration from start → now so the displayed time
                // reflects how long the run actually ran before being lost.
                if orphan.duration == 0 {
                    orphan.duration = Date().timeIntervalSince(orphan.timestamp)
                }
            }
            try context.save()
            logger.info("Reconciled \(orphans.count) orphaned .running run record(s) to .cancelled (Interrupted).")
        } catch {
            logger.error("Failed to reconcile orphaned runs: \(error.localizedDescription)")
        }
    }

    /// Removes every run record under a conversation. Called from the
    /// conversation-management coordinator when the user clears history or
    /// deletes a conversation manually (the `@Relationship` cascade also covers
    /// SwiftData-level conversation deletion).
    func clearHistory(forConversation conversationID: UUID) {
        guard let context = mainContext else {
            logger.error("clearHistory(forConversation:) called before container was configured — drop.")
            return
        }

        let predicate = #Predicate<WorkflowRunRecordSD> { $0.conversationID == conversationID }
        let descriptor = FetchDescriptor<WorkflowRunRecordSD>(predicate: predicate)

        do {
            let records = try context.fetch(descriptor)
            for r in records {
                context.delete(r)
            }
            try context.save()
            logger.info("Cleared \(records.count) run record(s) for conversation \(conversationID).")
        } catch {
            logger.error("Failed to clear run history for \(conversationID): \(error.localizedDescription)")
        }
    }

    // MARK: - Helpers

    /// Fetches the `ConversationSD` row for a given conversation ID, if it
    /// exists. Returning `nil` is fine — the record still persists; it just
    /// won't be cascade-deleted by SwiftData. Defensive against the case where
    /// a workflow somehow runs against an unpersisted conversation.
    private func fetchConversation(id: UUID, in context: ModelContext) throws -> ConversationSD? {
        let predicate = #Predicate<ConversationSD> { $0.id == id }
        var descriptor = FetchDescriptor<ConversationSD>(predicate: predicate)
        descriptor.fetchLimit = 1
        return try context.fetch(descriptor).first
    }
}
