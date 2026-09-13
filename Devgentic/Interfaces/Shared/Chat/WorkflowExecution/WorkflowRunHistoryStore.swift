// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2026 Raj Singh
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

    /// Sliding-window size per conversation.
    ///
    /// `static` and internal so the in-memory mirror kept by `MainApplicationViewModel` can trim
    /// to the SAME number instead of repeating the literal — the two were duplicated `20`s that
    /// nothing tied together, so a change here would have silently desynced the UI list from the
    /// store.
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

    /// Loads all run records for a conversation, newest first, decoding SYNCHRONOUSLY on the main
    /// actor. Returns `[]` on miss (no records, no container, or fetch failure).
    ///
    /// ⚠️ **TEST-ONLY. Production reads `loadFinalized` (a list) or `loadRecord` (one run).** Every
    /// remaining caller is in `DevgenticTests`, which wants a synchronous read; keeping it is
    /// cheaper than making twenty assertions `async` for no coverage gained. It is documented here
    /// rather than deleted so nobody reintroduces a main-actor decode by reaching for the file's
    /// first, most public-looking method.
    ///
    /// ⚠️ [CF-34] It decodes each row's `rowSnapshot` DIRECTLY. It used to read a
    /// `WorkflowRunRecordSD.record` accessor that cached its decode into the row's
    /// `_cachedRecord`, re-parking exactly the full-record residency XUI-14 removed from
    /// `apply`/`init` — and from a test helper at that. Rerouting here left that accessor with
    /// no callers and CF-34 DELETED it outright; this is now the only shape. Same bytes, same
    /// decoder (`decodeRecord(from:)`, which `loadFinalized` and `loadRecord` also use). The decode stays on this
    /// actor because the callers are synchronous — that is the reason this is not the production
    /// path, not an oversight.
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

    /// `load(forConversation:)` with the DECODE off the main actor (WF-UI6 ≡ WF-PE7).
    ///
    /// The fetch and the row-field copies stay on main (SwiftData requires it); the JSON decode of
    /// every run's node-results blob — the expensive part, and the reason first-visit to a
    /// workflow-heavy conversation hitched the main thread — runs detached. Mirrors
    /// `upsertFinalized`, which moved the ENCODE off-main for the same reason. Rows carrying a
    /// warm `_cachedRecord` decode for free either way.
    ///
    /// [workflow/vm-6] Returns records with their node traces ALREADY STRIPPED, plus the number
    /// of events dropped. The one caller (`ConversationSwitchCoordinator.applyLoadedRunHistory`)
    /// stripped them on arrival and nothing read a trace in between, so every finalized run of
    /// the conversation was materialised whole — each node up to 400 `TimelineEvent`s, tool rows
    /// holding outputs up to `ToolExecutionData.maxPersistedOutputLength` — and then thrown away.
    /// Stripping inside the task makes the peak ONE record's traces instead of the whole page.
    /// The count is returned rather than recomputed because the caller logs it, and because
    /// `mergeLoadedHistory` keeps its own (now idempotent) strip: that strip is what a mutation
    /// test pins, and a mutant that stopped stripping there survived the first battery.
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
            // ⚠️ `decodeRecord` stays THE app's one decode (CF-34): all three on-disk envelope
            // shapes are read in that one place. Stripping AFTER it keeps that invariant — a
            // second, trace-free decode path would buy at most half the cost (JSONDecoder parses
            // the whole blob regardless of which keys are consumed) and cost the single reader.
            let records = snapshots.map { snapshot -> WorkflowRunRecord in
                let (record, droppedHere) = WorkflowRunRecordSD.decodeRecord(from: snapshot).strippingNodeTimelines()
                dropped += droppedHere
                return record
            }
            return (records, dropped)
        }.value
    }

    /// ONE run record by id, with the decode off the main actor — the hydration read for XUI-11.
    ///
    /// The in-memory mirror drops node traces (`strippingNodeTimelines`) because holding twenty
    /// runs' worth for every conversation the user visits is where the residency goes; this reads
    /// the full record back for the single run actually being looked at. `fetchLimit = 1` on an
    /// id predicate, then the same `RowSnapshot` → detached-decode path `loadFinalized` uses.
    ///
    /// Returns nil when the row is gone (deleted conversation, evicted by the sliding window) —
    /// the caller then keeps the trace-less copy it already has rather than blanking the run.
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
        write(record, forConversation: conversationID, blobs: nil)
    }

    /// Same as `upsert`, but the JSON encode runs OFF the main actor.
    ///
    /// Use this for FINALIZED records. A finished run's blob carries up to 400
    /// `TimelineEvent`s per node, and this write lands at the exact moment the UI
    /// transitions to "completed" — encoding that inline on `@MainActor` was a
    /// visible hitch at the worst possible time. SwiftData's `mainContext` still
    /// requires the actual write on main, so only the encode moves; the `.running`
    /// stub at run start keeps using the cheap synchronous `upsert` (its
    /// `nodeResults` is empty, so there's nothing to move).
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
                try context.save()
                logger.info("Updated run \(record.id) for conversation \(conversationID) — status=\(record.status.rawValue).")
                return
            }

            // Insert path
            //
            // ⚠️ REFUSE when the conversation is gone. A run is persisted twice — a `.running`
            // stub at start, then a finalize upsert at the end — and `MessagingCoordinator`
            // cannot start one without an existing `ConversationSD` (it returns early, logging
            // CRITICAL). So a missing conversation on the INSERT path means exactly one thing:
            // the user deleted the conversation while the run was still going, `clearHistory`
            // removed this row, and the cancelled stream is now finalizing.
            //
            // Inserting anyway is what made deleted content come back. The delete path
            // deliberately purges messages, traces and vector memory for privacy; writing the
            // run's node outputs and final text back afterwards defeats that — and the row is
            // unparented, so no UI, no cascade and no cleanup path can ever reach it again.
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
                // Duration is deliberately LEFT AT 0 for an interrupted run.
                //
                // This used to be `Date().timeIntervalSince(orphan.timestamp)`, with the
                // rationale "so the displayed time reflects how long the run actually ran".
                // It cannot: `Date()` here is the time of the NEXT APP LAUNCH, not the moment
                // the run died, so the stored interval spanned all the intervening downtime.
                // `orphan.timestamp` is the run's start and `duration == 0` is precisely the
                // `.running` stub's value, so the branch fired for EVERY interrupted run — a
                // run killed on Monday and reopened on Thursday was rendered by
                // `DurationFormat.seconds` as "4320m 0s" in the history card, the run picker
                // and the VoiceOver label.
                //
                // `DurationFormat.seconds` already renders "" for <= 0, so leaving it at 0
                // simply omits the duration and lets the "Interrupted" error carry the meaning.
                // Recording a real value would need a heartbeat persisted DURING the run;
                // there is no such field today.
            }
            try context.save()
            logger.info("Reconciled \(orphans.count) orphaned .running run record(s) to .cancelled (Interrupted); duration left unset — the wall-clock time since the run started would include app downtime, not execution time.")
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

    /// Fetches the `ConversationSD` row for a given conversation ID, if it exists.
    ///
    /// ⚠️ `nil` is NOT benign, despite what this comment used to say ("the record still persists;
    /// it just won't be cascade-deleted"). An unparented run row is unreachable forever: the
    /// history list, run picker and `clearHistory` all query by `conversationID`, and the
    /// `@Relationship` cascade cannot collect it. The only caller now refuses the write.
    private func fetchConversation(id: UUID, in context: ModelContext) throws -> ConversationSD? {
        let predicate = #Predicate<ConversationSD> { $0.id == id }
        var descriptor = FetchDescriptor<ConversationSD>(predicate: predicate)
        descriptor.fetchLimit = 1
        return try context.fetch(descriptor).first
    }
}
