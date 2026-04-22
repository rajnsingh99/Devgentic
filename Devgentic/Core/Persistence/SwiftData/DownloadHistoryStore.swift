//
//  DownloadHistoryStore.swift
//  Devgentic
//
//  Created 2026-04-21.
//
//  Persistence layer for the new `DownloadRecord` model. Singleton + injected
//  `ModelContainer`, matching `PromptStore` / `ChatPersistenceStore`.
//
//  Write path (from DownloadManager bridges):
//    startDownload(...)         → inserts a fresh `.queued` record
//    updateProgress(...)        → 1%-throttled writes during the pull
//    markCompleted / Failed /   → terminal transitions
//      Cancelled
//
//  Read path (from UI):
//    fetchMostRecent(backend:modelIdentifier:)  — "is this model in history?"
//    fetchActive()                              — in-flight records for sidebar
//    fetchHistory(limit:)                       — completed/failed/cancelled
//
//  Recovery:
//    reconcileOrphans()  — called on app launch. Any record still in
//    `.queued` or `.downloading` must be a leftover from a crashed session;
//    flip to `.interrupted` with a helpful `errorMessage`. Service-level
//    state rebuilds itself on next interaction, so the user can just click
//    re-download.
//

import Foundation
import SwiftData
import os

private let logger = DGLogger(category: "DownloadHistoryStore")

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

    /// Insert a new record for a freshly-triggered download. Caller (typically
    /// a `DownloadManager` bridge) supplies the UUID so service-side tracking
    /// (e.g. OllamaService's active task) matches the record for later updates.
    ///
    /// `fileSizeBytes` is optional — MLX pre-fetches size from HuggingFace
    /// before starting so we can seed it here, while Ollama / Whisper discover
    /// it on the first progress callback and update it via `updateProgress`.
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

    /// Persist a progress tick. `fileSizeBytes` is honored only if the
    /// record doesn't already have one — avoids replacing a pre-seeded
    /// authoritative size (MLX) with a chunk-transfer estimate, but still
    /// lets Ollama / Whisper populate the field the first time they see it.
    @discardableResult
    func updateProgress(id: UUID, progress: Double, fileSizeBytes: Int64? = nil) -> Result<Void, DownloadHistoryError> {
        guard let record = fetch(id: id) else { return .failure(.notFound(id)) }
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
        guard let record = fetch(id: id) else { return .failure(.notFound(id)) }
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
        guard let record = fetch(id: id) else { return .failure(.notFound(id)) }
        record.statusRaw = DownloadRecordStatus.failed.rawValue
        record.updatedAt = Date()
        record.errorMessage = message
        logger.info("Failed download record id=\(id.uuidString): \(message ?? "nil")")
        return save()
    }

    @discardableResult
    func markCancelled(id: UUID, reason: String? = nil) -> Result<Void, DownloadHistoryError> {
        guard let record = fetch(id: id) else { return .failure(.notFound(id)) }
        record.statusRaw = DownloadRecordStatus.cancelled.rawValue
        record.updatedAt = Date()
        record.cancelReason = reason
        logger.info("Cancelled download record id=\(id.uuidString)")
        return save()
    }

    @discardableResult
    func delete(id: UUID) -> Result<Void, DownloadHistoryError> {
        guard let context = mainContext else { return .failure(.containerUnavailable) }
        guard let record = fetch(id: id) else { return .failure(.notFound(id)) }
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
        guard let context = mainContext else { return nil }
        let predicate = #Predicate<DownloadRecord> { $0.id == id }
        var descriptor = FetchDescriptor<DownloadRecord>(predicate: predicate)
        descriptor.fetchLimit = 1
        return (try? context.fetch(descriptor))?.first
    }

    /// Returns the most recent record for a given (backend, modelIdentifier) pair,
    /// regardless of status. Used by the idempotent "already downloaded" check.
    func fetchMostRecent(backend: ModelBackendType, modelIdentifier: String) -> DownloadRecord? {
        guard let context = mainContext else { return nil }
        let backendRaw = backend.rawValue
        let predicate = #Predicate<DownloadRecord> { rec in
            rec.backendRaw == backendRaw && rec.modelIdentifier == modelIdentifier
        }
        var descriptor = FetchDescriptor<DownloadRecord>(
            predicate: predicate,
            sortBy: [SortDescriptor(\.updatedAt, order: .reverse)]
        )
        descriptor.fetchLimit = 1
        return (try? context.fetch(descriptor))?.first
    }

    /// All currently-active (queued or downloading) records. Drives the
    /// "In progress" section of the Downloads sidebar and the activity-bar
    /// badge count.
    func fetchActive() -> [DownloadRecord] {
        guard let context = mainContext else { return [] }
        let queuedRaw = DownloadRecordStatus.queued.rawValue
        let downloadingRaw = DownloadRecordStatus.downloading.rawValue
        let predicate = #Predicate<DownloadRecord> { rec in
            rec.statusRaw == queuedRaw || rec.statusRaw == downloadingRaw
        }
        let descriptor = FetchDescriptor<DownloadRecord>(
            predicate: predicate,
            sortBy: [SortDescriptor(\.startedAt, order: .reverse)]
        )
        return (try? context.fetch(descriptor)) ?? []
    }

    /// Terminal records (completed / failed / cancelled / interrupted),
    /// newest first. Used for the "History" section of the sidebar.
    func fetchHistory(limit: Int = 200) -> [DownloadRecord] {
        guard let context = mainContext else { return [] }
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
        return (try? context.fetch(descriptor)) ?? []
    }

    /// Full unsorted fetch. Rare — prefer `fetchActive` / `fetchHistory`.
    func fetchAll() -> [DownloadRecord] {
        guard let context = mainContext else { return [] }
        return (try? context.fetch(FetchDescriptor<DownloadRecord>())) ?? []
    }

    // MARK: - Orphan reconcile

    /// Any record still in `.queued` or `.downloading` when the app launches
    /// is by definition a leftover from a previous session (no download task
    /// survives app termination). Flip to `.interrupted` with an explanatory
    /// error so the user can decide whether to re-trigger.
    ///
    /// Safe to call repeatedly — only touches records matching the active
    /// predicate, and writes the terminal transition exactly once per row.
    func reconcileOrphans() {
        let stillActive = fetchActive()
        guard !stillActive.isEmpty else { return }
        for record in stillActive {
            record.statusRaw = DownloadRecordStatus.interrupted.rawValue
            record.updatedAt = Date()
            record.errorMessage = record.errorMessage ?? "App closed during download"
        }
        _ = save()
        logger.info("Reconciled \(stillActive.count) orphaned active download(s) to .interrupted.")
    }

    // MARK: - Save helper

    @discardableResult
    private func save() -> Result<Void, DownloadHistoryError> {
        guard let context = mainContext else { return .failure(.containerUnavailable) }
        do {
            try context.save()
            return .success(())
        } catch {
            logger.error("SwiftData save failed: \(error.localizedDescription)")
            return .failure(.saveFailed(error.localizedDescription))
        }
    }
}
