// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
//
//  WorkflowRunHistoryStore.swift
//  Devgentic
//
//  Created by Raj Singh.
//

import Foundation
import SwiftData
import OSLog

private let logger = DGLogger(category: "WorkflowRunHistoryStore")

/// SwiftData-backed persistence for workflow run history, keyed by conversation ID.
/// A sliding window keeps at most `maxRecordsPerConversation` records per conversation, evicting the oldest.
/// `@MainActor`-isolated; rows link to `ConversationSD`, so deleting a conversation cascades to its runs.
@MainActor
final class WorkflowRunHistoryStore {

    // MARK: - Singleton

    static let shared = WorkflowRunHistoryStore()
    private init() {}

    // MARK: - Tuning

    /// Sliding-window size per conversation.
    /// Internal so the in-memory mirror in `MainApplicationViewModel` trims to the same number.
    static let maxRecordsPerConversation = 20

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

    /// Loads all run records for a conversation, newest first, decoding synchronously on the main actor.
    /// Returns `[]` when there are no records, no container, or the fetch fails.
    /// Test-only: production reads `loadFinalized` (a list) or `loadRecord` (one run).
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
            return try context.fetch(descriptor)
                .map { WorkflowRunRecordSD.decodeRecord(from: $0.rowSnapshot) }
        } catch {
            logger.error("Failed to fetch run history for \(conversationID): \(error.localizedDescription)")
            return []
        }
    }

    /// Like `load(forConversation:)` with the JSON decode off the main actor; the fetch and row copies stay on main.
    /// Returns records with node traces stripped, plus the number of events dropped, so peak memory is one record's traces.
    func loadFinalized(forConversation conversationID: UUID) async -> (records: [WorkflowRunRecord], droppedEvents: Int) {
        guard let context = mainContext else {
            logger.error("loadFinalized(forConversation:) called before container was configured — returning [].")
            return ([], 0)
        }

        let predicate = #Predicate<WorkflowRunRecordSD> { $0.conversationID == conversationID }
        let descriptor = FetchDescriptor<WorkflowRunRecordSD>(
            predicate: predicate,
            sortBy: [SortDescriptor(\.timestamp, order: .reverse)]
        )

        let snapshots: [WorkflowRunRecordSD.RowSnapshot]
        do {
            snapshots = try context.fetch(descriptor).map(\.rowSnapshot)
        } catch {
            logger.error("Failed to fetch run history for \(conversationID): \(error.localizedDescription)")
            return ([], 0)
        }
        guard !snapshots.isEmpty else { return ([], 0) }

        return await Task.detached(priority: .userInitiated) { () -> (records: [WorkflowRunRecord], droppedEvents: Int) in
            var dropped = 0
            // Strips after `decodeRecord`, which stays the single place that reads all on-disk envelope shapes.
            let records = snapshots.map { snapshot -> WorkflowRunRecord in
                let (record, droppedHere) = WorkflowRunRecordSD.decodeRecord(from: snapshot).strippingNodeTimelines()
                dropped += droppedHere
                return record
            }
            return (records, dropped)
        }.value
    }

    /// Loads one run record by id with the decode off the main actor, including its full node traces.
    /// Returns nil when the row is gone (deleted conversation or evicted by the sliding window).
    func loadRecord(id: UUID) async -> WorkflowRunRecord? {
        guard let context = mainContext else {
            logger.error("loadRecord(id:) called before container was configured — returning nil. CONSEQUENCE: the run opens without its per-node trace; its output and status are unaffected.")
            return nil
        }

        var descriptor = FetchDescriptor<WorkflowRunRecordSD>(
            predicate: #Predicate<WorkflowRunRecordSD> { $0.id == id }
        )
        descriptor.fetchLimit = 1

        let snapshot: WorkflowRunRecordSD.RowSnapshot
        do {
            guard let row = try context.fetch(descriptor).first else { return nil }
            snapshot = row.rowSnapshot
        } catch {
            logger.error("[PERSISTENCE] Failed to re-read run \(id) for its node traces: \(error.localizedDescription). CONSEQUENCE: the run's Timeline tabs render empty; its output, status and node list are unaffected, and a reopen retries.")
            return nil
        }

        return await Task.detached(priority: .userInitiated) {
            WorkflowRunRecordSD.decodeRecord(from: snapshot)
        }.value
    }

    /// Inserts or updates a run record under the given conversation, keyed by `record.id`.
    /// A run is upserted at start (a `.running` stub) and again at end with the finalized results.
    /// Insert enforces the sliding-window cap, evicting the oldest record; update evicts nothing.
    func upsert(_ record: WorkflowRunRecord, forConversation conversationID: UUID) {
        write(record, forConversation: conversationID, blobs: nil)
    }

    /// Same as `upsert`, but the JSON encode runs off the main actor; use it for finalized records.
    /// Only the encode moves; SwiftData's `mainContext` still performs the write on main.
    func upsertFinalized(_ record: WorkflowRunRecord, forConversation conversationID: UUID) async {
        let blobs = await Task.detached(priority: .userInitiated) {
            WorkflowRunRecordSD.encodeBlobs(for: record)
        }.value
        write(record, forConversation: conversationID, blobs: blobs)
    }

    /// Shared main-actor write. `blobs == nil` encodes inline.
    private func write(
        _ record: WorkflowRunRecord,
        forConversation conversationID: UUID,
        blobs: WorkflowRunRecordSD.EncodedBlobs?
    ) {
        guard let context = mainContext else {
            logger.error("upsert(_:forConversation:) called before container was configured — drop.")
            return
        }

        do {
            let resolvedBlobs = blobs ?? WorkflowRunRecordSD.encodeBlobs(for: record)
            let recordID = record.id
            let existingPredicate = #Predicate<WorkflowRunRecordSD> { $0.id == recordID }
            var existingDescriptor = FetchDescriptor<WorkflowRunRecordSD>(predicate: existingPredicate)
            existingDescriptor.fetchLimit = 1

            if let existing = try context.fetch(existingDescriptor).first {
                // Update path — rewrite the row's contents from the (possibly
                // off-main-encoded) blobs.
                existing.apply(record, blobs: resolvedBlobs)
                try SharedContextSave.save(context, "run history: update run \(record.id)")
                logger.info("Updated run \(record.id) for conversation \(conversationID) — status=\(record.status.rawValue).")
                return
            }

            // Insert path: refuses when the conversation is gone, which means it was deleted while the run was in flight.
            // Inserting anyway would bring deleted content back as an unparented, unreachable row.
            guard let conversation = try fetchConversation(id: conversationID, in: context) else {
                logger.error(
                    "[PERSISTENCE] Run \(record.id) NOT persisted — conversation \(conversationID) "
                    + "no longer exists, so this is a finalize landing after the conversation was "
                    + "deleted mid-run (status=\(record.status.rawValue), \(record.nodeResults.count) "
                    + "node result(s)). CONSEQUENCE: the record is DROPPED by design. Persisting it "
                    + "would resurrect content the user deleted and leave an orphan row no UI or "
                    + "cleanup path can reach."
                )
                return
            }

            let newRow = WorkflowRunRecordSD(record: record, conversation: conversation, blobs: resolvedBlobs)
            context.insert(newRow)

            // Enforce sliding window: fetch the conversation's records sorted oldest-first,
            // delete from the top until we're back under the cap.
            let conversationPredicate = #Predicate<WorkflowRunRecordSD> { $0.conversationID == conversationID }
            let overflowDescriptor = FetchDescriptor<WorkflowRunRecordSD>(
                predicate: conversationPredicate,
                sortBy: [SortDescriptor(\.timestamp, order: .forward)]
            )
            let allForConversation = try context.fetch(overflowDescriptor)
            let overflow = allForConversation.count - Self.maxRecordsPerConversation
            if overflow > 0 {
                for old in allForConversation.prefix(overflow) {
                    context.delete(old)
                }
            }

            try SharedContextSave.save(context, "run history: insert run \(record.id)")
            logger.info("Persisted run \(record.id) for conversation \(conversationID) (\(allForConversation.count - max(0, overflow)) total after cap, status=\(record.status.rawValue)).")
        } catch {
            logger.error("Failed to upsert run \(record.id) for \(conversationID): \(error.localizedDescription)")
        }
    }

    // MARK: - Orphan reconciliation

    /// Flips any record still in `.running` to `.cancelled` with an "Interrupted" error message.
    /// No run survives app termination, so a `.running` row at launch is from an earlier session.
    /// - Parameter startedBefore: only runs started before this instant are orphans; later ones are live.
    func reconcileOrphans(startedBefore cutoff: Date = .distantFuture) {
        guard let context = mainContext else {
            logger.error("reconcileOrphans() called before container was configured — skip.")
            return
        }

        let runningRaw = WorkflowRunRecord.RunStatus.running.rawValue
        let predicate = #Predicate<WorkflowRunRecordSD> { $0.statusRaw == runningRaw }
        let descriptor = FetchDescriptor<WorkflowRunRecordSD>(predicate: predicate)

        do {
            let running = try context.fetch(descriptor)
            let orphans = running.filter { $0.timestamp < cutoff }
            if orphans.count < running.count {
                logger.info("Left \(running.count - orphans.count) .running run(s) alone — started during this launch, so they are live, not orphans.")
            }
            guard !orphans.isEmpty else { return }

            for orphan in orphans {
                orphan.statusRaw = WorkflowRunRecord.RunStatus.cancelled.rawValue
                orphan.errorMessage = orphan.errorMessage ?? "Interrupted"
                // Duration stays 0 for an interrupted run: the time of the next launch would span all the downtime.
                // `DurationFormat.seconds` renders "" for <= 0, so the "Interrupted" error carries the meaning.
            }
            try SharedContextSave.save(context, "run history: reconcile orphans")
            logger.info("Reconciled \(orphans.count) orphaned .running run record(s) to .cancelled (Interrupted); duration left unset — the wall-clock time since the run started would include app downtime, not execution time.")
        } catch {
            logger.error("Failed to reconcile orphaned runs: \(error.localizedDescription)")
        }
    }

    /// Removes every run record under a conversation.
    /// Called when the user clears history or deletes a conversation; the `@Relationship` cascade also covers deletion.
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
            try SharedContextSave.save(context, "run history: clear \(conversationID)")
            logger.info("Cleared \(records.count) run record(s) for conversation \(conversationID).")
        } catch {
            logger.error("Failed to clear run history for \(conversationID): \(error.localizedDescription)")
        }
    }

    // MARK: - Helpers

    /// Fetches the `ConversationSD` row for a conversation ID, or nil if it does not exist.
    /// Nil means a run row would be unparented and unreachable, so the caller refuses the write.
    private func fetchConversation(id: UUID, in context: ModelContext) throws -> ConversationSD? {
        let predicate = #Predicate<ConversationSD> { $0.id == id }
        var descriptor = FetchDescriptor<ConversationSD>(predicate: predicate)
        descriptor.fetchLimit = 1
        return try context.fetch(descriptor).first
    }
}
