// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
//
//  DownloadHistoryStore.swift
//  Devgentic
//
//  Created by Raj Singh.
//

import Foundation
import SwiftData
import os

private let logger = DGLogger(category: "DownloadHistoryStore")

/// Persistence layer for `DownloadRecord`: records download lifecycle from the download bridges and
/// serves history to the UI. Records still `.queued` or `.downloading` at launch are reconciled to
/// `.interrupted`.
enum DownloadHistoryError: LocalizedError, Equatable {
    case containerUnavailable
    case fetchFailed(String)
    case saveFailed(String)
    case notFound(UUID)

    var errorDescription: String? {
        switch self {
        case .containerUnavailable:        return "Download history storage is unavailable."
        case .fetchFailed(let reason):     return "Couldn't load download history: \(reason)"
        case .saveFailed(let reason):      return "Couldn't save download record: \(reason)"
        case .notFound(let id):            return "Download record \(id.uuidString) was not found."
        }
    }
}

@MainActor
final class DownloadHistoryStore {

    static let shared = DownloadHistoryStore()

    private var modelContainer: ModelContainer?

    private var mainContext: ModelContext? {
        modelContainer?.mainContext
    }

    private init() {}

    /// Call once from `DevgenticApp`'s container init block.
    func configureContainer(_ container: ModelContainer) {
        self.modelContainer = container
    }

    // MARK: - Start / update / terminal writes

    /// Inserts a new record for a freshly triggered download; the caller supplies the UUID so service-side
    /// tracking matches it. `fileSizeBytes` is optional: MLX seeds it up front, while Ollama and Whisper
    /// set it via `updateProgress`.
    @discardableResult
    func startDownload(
        id: UUID,
        backend: ModelBackendType,
        modelIdentifier: String,
        displayName: String? = nil,
        fileSizeBytes: Int64? = nil,
        sourceURL: String? = nil,
        profileID: UUID? = nil
    ) -> Result<DownloadRecord, DownloadHistoryError> {
        guard let context = mainContext else { return .failure(.containerUnavailable) }

        let now = Date()
        let record = DownloadRecord(
            id: id,
            backend: backend,
            modelIdentifier: modelIdentifier,
            displayName: displayName,
            status: .downloading,
            progress: 0,
            fileSizeBytes: fileSizeBytes,
            startedAt: now,
            updatedAt: now,
            sourceURL: sourceURL,
            profileID: profileID
        )
        context.insert(record)
        logger.info("Started download record id=\(id.uuidString) backend=\(backend.rawValue) model=\(modelIdentifier)")
        return save().map { record }
    }

    /// Persists a progress tick. `fileSizeBytes` is honored only if the record has no size yet, so a seeded
    /// size is kept.
    @discardableResult
    func updateProgress(id: UUID, progress: Double, fileSizeBytes: Int64? = nil) -> Result<Void, DownloadHistoryError> {
        guard let record = fetch(id: id) else { return notFound(id) }
        record.progress = max(0, min(1, progress))
        record.updatedAt = Date()
        if record.statusRaw == DownloadRecordStatus.queued.rawValue {
            record.statusRaw = DownloadRecordStatus.downloading.rawValue
        }
        if let size = fileSizeBytes, record.fileSizeBytes == nil {
            record.fileSizeBytes = size
        }
        return save()
    }

    @discardableResult
    func markCompleted(id: UUID, fileSizeBytes: Int64? = nil) -> Result<Void, DownloadHistoryError> {
        guard let record = fetch(id: id) else { return notFound(id) }
        let now = Date()
        record.statusRaw = DownloadRecordStatus.completed.rawValue
        record.progress = 1.0
        record.updatedAt = now
        record.completedAt = now
        if let bytes = fileSizeBytes { record.fileSizeBytes = bytes }
        logger.info("Completed download record id=\(id.uuidString)")
        return save()
    }

    @discardableResult
    func markFailed(id: UUID, message: String?) -> Result<Void, DownloadHistoryError> {
        guard let record = fetch(id: id) else { return notFound(id) }
        record.statusRaw = DownloadRecordStatus.failed.rawValue
        record.updatedAt = Date()
        record.errorMessage = message
        logger.info("Failed download record id=\(id.uuidString): \(message ?? "nil")")
        return save()
    }

    @discardableResult
    func markCancelled(id: UUID, reason: String? = nil) -> Result<Void, DownloadHistoryError> {
        guard let record = fetch(id: id) else { return notFound(id) }
        record.statusRaw = DownloadRecordStatus.cancelled.rawValue
        record.updatedAt = Date()
        record.cancelReason = reason
        logger.info("Cancelled download record id=\(id.uuidString)")
        return save()
    }

    /// Pause: a non-failure stop that keeps the partial bytes. `progress` is preserved so the
    /// row can show how far it got and the resume has something to display.
    @discardableResult
    func markPaused(id: UUID) -> Result<Void, DownloadHistoryError> {
        guard let record = fetch(id: id) else { return notFound(id) }
        record.statusRaw = DownloadRecordStatus.paused.rawValue
        record.updatedAt = Date()
        record.errorMessage = nil
        logger.info("[DOWNLOAD] Paused download record id=\(id.uuidString) at \(Int(record.progress * 100))% — partial files retained for resume.")
        return save()
    }

    @discardableResult
    func delete(id: UUID) -> Result<Void, DownloadHistoryError> {
        guard let context = mainContext else { return .failure(.containerUnavailable) }
        guard let record = fetch(id: id) else { return notFound(id) }
        context.delete(record)
        logger.info("Deleted download record id=\(id.uuidString)")
        return save()
    }

    @discardableResult
    func deleteAllHistory(keepingActive: Bool = true) -> Result<Int, DownloadHistoryError> {
        guard let context = mainContext else { return .failure(.containerUnavailable) }
        do {
            let all = try context.fetch(FetchDescriptor<DownloadRecord>())
            var removed = 0
            for record in all {
                if keepingActive && record.isActive { continue }
                context.delete(record)
                removed += 1
            }
            return save().map { removed }
        } catch {
            return .failure(.fetchFailed(error.localizedDescription))
        }
    }

    // MARK: - Lookups

    func fetch(id: UUID) -> DownloadRecord? {
        guard let context = requireContext("fetch(id:)") else { return nil }
        let predicate = #Predicate<DownloadRecord> { $0.id == id }
        var descriptor = FetchDescriptor<DownloadRecord>(predicate: predicate)
        descriptor.fetchLimit = 1
        do {
            return try context.fetch(descriptor).first
        } catch {
            logger.error("[DOWNLOAD] fetch(id: \(id.uuidString)) FAILED: \(error.localizedDescription). CONSEQUENCE: the caller treats this record as missing — progress and terminal updates for it are silently dropped.")
            return nil
        }
    }

    /// Returns the most recent record for a given (backend, modelIdentifier) pair,
    /// regardless of status. Used by the idempotent "already downloaded" check.
    func fetchMostRecent(backend: ModelBackendType, modelIdentifier: String) -> DownloadRecord? {
        guard let context = requireContext("fetchMostRecent") else { return nil }
        let backendRaw = backend.rawValue
        let predicate = #Predicate<DownloadRecord> { rec in
            rec.backendRaw == backendRaw && rec.modelIdentifier == modelIdentifier
        }
        var descriptor = FetchDescriptor<DownloadRecord>(
            predicate: predicate,
            sortBy: [SortDescriptor(\.updatedAt, order: .reverse)]
        )
        descriptor.fetchLimit = 1
        do {
            return try context.fetch(descriptor).first
        } catch {
            logger.error("[DOWNLOAD] fetchMostRecent(\(backend.rawValue), '\(modelIdentifier)') FAILED: \(error.localizedDescription). CONSEQUENCE: treated as no prior history, so the idempotent 'already downloaded' short-circuit is skipped and the model may be re-pulled.")
            return nil
        }
    }

    /// All currently-active (queued or downloading) records. Drives the
    /// "In progress" section of the Downloads sidebar and the activity-bar
    /// badge count.
    func fetchActive() -> [DownloadRecord] {
        guard let context = requireContext("fetchActive") else { return [] }
        let queuedRaw = DownloadRecordStatus.queued.rawValue
        let downloadingRaw = DownloadRecordStatus.downloading.rawValue
        let predicate = #Predicate<DownloadRecord> { rec in
            rec.statusRaw == queuedRaw || rec.statusRaw == downloadingRaw
        }
        let descriptor = FetchDescriptor<DownloadRecord>(
            predicate: predicate,
            sortBy: [SortDescriptor(\.startedAt, order: .reverse)]
        )
        do {
            return try context.fetch(descriptor)
        } catch {
            logger.error("[DOWNLOAD] fetchActive FAILED: \(error.localizedDescription). CONSEQUENCE: the app behaves as if nothing is downloading — the sidebar shows its empty state and the activity badge stays hidden.")
            return []
        }
    }

    /// Terminal records (completed / failed / cancelled / interrupted),
    /// newest first. Used for the "History" section of the sidebar.
    func fetchHistory(limit: Int = 200) -> [DownloadRecord] {
        guard let context = requireContext("fetchHistory") else { return [] }
        let queuedRaw = DownloadRecordStatus.queued.rawValue
        let downloadingRaw = DownloadRecordStatus.downloading.rawValue
        let predicate = #Predicate<DownloadRecord> { rec in
            rec.statusRaw != queuedRaw && rec.statusRaw != downloadingRaw
        }
        var descriptor = FetchDescriptor<DownloadRecord>(
            predicate: predicate,
            sortBy: [SortDescriptor(\.updatedAt, order: .reverse)]
        )
        descriptor.fetchLimit = limit
        do {
            return try context.fetch(descriptor)
        } catch {
            logger.error("[DOWNLOAD] fetchHistory FAILED: \(error.localizedDescription). CONSEQUENCE: the Downloads history list renders empty, indistinguishable from a user who has never downloaded anything.")
            return []
        }
    }

    /// Full unsorted fetch. Rare — prefer `fetchActive` / `fetchHistory`.
    func fetchAll() -> [DownloadRecord] {
        guard let context = requireContext("fetchAll") else { return [] }
        do {
            return try context.fetch(FetchDescriptor<DownloadRecord>())
        } catch {
            logger.error("[DOWNLOAD] fetchAll FAILED: \(error.localizedDescription). CONSEQUENCE: download history renders empty.")
            return []
        }
    }

    /// Row count without materializing the rows.
    /// Lets the launch sweep log how many rows were at stake before the destructive retention sweep runs.
    func totalRecordCount() -> Int {
        guard let context = requireContext("totalRecordCount") else { return 0 }
        do {
            return try context.fetchCount(FetchDescriptor<DownloadRecord>())
        } catch {
            logger.error(
                "[DOWNLOAD] totalRecordCount FAILED: \(error.localizedDescription). "
                + "CONSEQUENCE: the launch-sweep pre-flight log reports 0 rows, which is "
                + "indistinguishable from an empty history."
            )
            return 0
        }
    }

    // MARK: - Retention

    /// Terminal records older than this are eligible for pruning.
    static let retentionDays = 90
    /// …and never more than this many terminal records are kept, whichever is looser.
    static let retentionMaxRecords = 500

    /// The retention decision, free of SwiftData so it can be tested directly.
    /// `index` is the record's position in a newest-first list; a record goes if it is beyond the count cap
    /// or older than the age cap.
    nonisolated static func shouldPrune(
        index: Int,
        updatedAt: Date,
        now: Date,
        olderThanDays days: Int,
        keepingNewest keep: Int
    ) -> Bool {
        let cutoff = Calendar.current.date(byAdding: .day, value: -days, to: now) ?? .distantPast
        return index >= keep || updatedAt < cutoff
    }

    /// The statuses the retention sweep may delete; the pruning predicate is derived from this list.
    /// `.paused` is absent: its partial bytes stay on disk and the row is the only Resume affordance
    /// pointing at them.
    static let prunableStatuses: [DownloadRecordStatus] = [
        .completed, .cancelled, .failed, .interrupted
    ]

    @discardableResult
    func pruneOldRecords(
        olderThanDays days: Int = retentionDays,
        keepingNewest keep: Int = retentionMaxRecords
    ) -> Int {
        guard let context = requireContext("pruneOldRecords") else { return 0 }

        let prunableRaw = Self.prunableStatuses.map(\.rawValue)
        let predicate = #Predicate<DownloadRecord> { prunableRaw.contains($0.statusRaw) }
        let descriptor = FetchDescriptor<DownloadRecord>(
            predicate: predicate,
            sortBy: [SortDescriptor(\.updatedAt, order: .reverse)]
        )

        let candidates: [DownloadRecord]
        do {
            candidates = try context.fetch(descriptor)
        } catch {
            logger.error("[DOWNLOAD] Retention sweep could not read history: \(error.localizedDescription). CONSEQUENCE: nothing was pruned this launch; history keeps growing.")
            return 0
        }

        let now = Date()
        var removed = 0
        for (index, record) in candidates.enumerated() {
            guard Self.shouldPrune(
                index: index, updatedAt: record.updatedAt, now: now,
                olderThanDays: days, keepingNewest: keep
            ) else { continue }
            context.delete(record)
            removed += 1
        }

        guard removed > 0 else {
            logger.info("[DOWNLOAD] Retention sweep: nothing to prune (\(candidates.count) terminal record(s), limit \(keep), cutoff \(days)d).")
            return 0
        }
        _ = save()
        logger.notice("[DOWNLOAD] Retention sweep pruned \(removed) of \(candidates.count) terminal download record(s) — older than \(days) days or beyond the newest \(keep). Paused and in-progress records were left untouched; any partial files remain on disk and are still reported by the orphan scan.")
        return removed
    }

    // MARK: - Orphan reconcile

    /// Flips every record still `.queued` or `.downloading` at launch to `.interrupted`; safe to repeat.
    /// - Parameter startedBefore: only rows started before this instant are orphans.
    func reconcileOrphans(startedBefore cutoff: Date = .distantFuture) {
        let active = fetchActive()
        let stillActive = active.filter { $0.startedAt < cutoff }
        if stillActive.count < active.count {
            logger.info("[DOWNLOAD] Left \(active.count - stillActive.count) active download(s) alone — started during this launch, so they are live, not orphans.")
        }
        guard !stillActive.isEmpty else { return }
        for record in stillActive {
            record.statusRaw = DownloadRecordStatus.interrupted.rawValue
            record.updatedAt = Date()
            record.errorMessage = record.errorMessage ?? "App closed during download"
        }
        _ = save()
        logger.notice("[DOWNLOAD] Reconciled \(stillActive.count) orphaned active download(s) to .interrupted: \(stillActive.map { "\($0.backendRaw)/\($0.modelIdentifier) at \(Int($0.progress * 100))%" }.joined(separator: ", ")). CONSEQUENCE: their partial bytes are still on disk and are RESUMABLE — the history row offers Resume; nothing reclaims them automatically.")
    }

    // MARK: - Diagnostics
    // Logs a missing container and a failed fetch separately, so a store that failed to open is visible.
    // The container is configured from an async Task at launch, so it can be unavailable.

    private func requireContext(_ operation: String) -> ModelContext? {
        guard let context = mainContext else {
            logger.error("[DOWNLOAD] \(operation) called before the SwiftData container was configured. CONSEQUENCE: the operation is skipped and download history is neither read nor written — any download running right now will never appear in history.")
            return nil
        }
        return context
    }

    private func notFound(_ id: UUID) -> Result<Void, DownloadHistoryError> {
        logger.error("[DOWNLOAD] No record \(id.uuidString) to update. CONSEQUENCE: this download's progress and terminal state are not persisted; it will not appear in history and any active row for it goes stale.")
        return .failure(.notFound(id))
    }

    // MARK: - Save helper

    @discardableResult
    private func save() -> Result<Void, DownloadHistoryError> {
        guard let context = mainContext else { return .failure(.containerUnavailable) }
        do {
            try SharedContextSave.save(context, "download history")
            return .success(())
        } catch {
            logger.error("SwiftData save failed: \(error.localizedDescription)")
            return .failure(.saveFailed(error.localizedDescription))
        }
    }
}
