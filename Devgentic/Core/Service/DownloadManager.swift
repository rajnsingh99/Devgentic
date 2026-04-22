//
//  DownloadManager.swift
//  Devgentic
//
//  Created by Raj Singh on 19/03/26.
//  Refactored 2026-04-21 — retired session-only `DownloadEntry` in favor of
//  persistent `DownloadRecord` written to `DownloadHistoryStore`. The manager
//  is now a thin orchestrator that bridges each backend service's in-memory
//  download state into SwiftData-backed history. Views fetch records from
//  `DownloadHistoryStore` directly (or via `@Query`).
//
//  Extended 2026-04-21 with live speed + ETA:
//    · Each bridge feeds a per-record `SpeedSampler` with byte counts
//    · `activeSpeeds` is an @Observable map of UUID → snapshot so views
//      animate MB/s + "3 min left" without subscribing to the sampler
//    · Backends differ in how they source bytes — see per-bridge notes
//
//  What used to live here that's now gone:
//    · `DownloadEntry` struct → replaced by `DownloadRecord` @Model
//    · `activeDownloads` / `completedDownloads` arrays → query the store
//    · `clearCompleted` / `removeCompleted` → `DownloadHistoryStore.delete(...)`
//

import SwiftUI

// MARK: - Models

enum ModelBackendType: String, Equatable, Hashable {
    case ollama  = "Ollama"
    case mlx     = "MLX"
    case whisper = "Whisper"

    var icon: String {
        switch self {
        case .ollama:  return "server.rack"
        case .mlx:     return "apple.logo"
        case .whisper: return "waveform"
        }
    }

    var tintColor: Color {
        switch self {
        case .ollama:  return .blue
        case .mlx:     return .purple
        case .whisper: return .green
        }
    }
}

// MARK: - Download Manager

@Observable @MainActor
final class DownloadManager {
    static let shared = DownloadManager()

    // MARK: - Live counters (read from SwiftData on demand)

    var activeRecords: [DownloadRecord] {
        DownloadHistoryStore.shared.fetchActive()
    }

    var hasActiveDownloads: Bool { !activeRecords.isEmpty }
    var activeCount: Int { activeRecords.count }

    /// Live speed + ETA per active record. Updated every time a bridge
    /// records a new byte sample. Views observe this to animate the
    /// "12.4 MB/s · 3 min left" line under the progress bar.
    var activeSpeeds: [UUID: DownloadSpeedSnapshot] = [:]

    /// Active record IDs keyed by `"<backend>:<modelIdentifier>"`.
    /// Published separately from `activeSpeeds` because the speed dict
    /// doesn't populate until the sampler has enough data (up to ~1s
    /// into a pull), whereas this dict flips the moment a bridge sees
    /// the service transition to `isDownloading = true`. Views use this
    /// for the "is this model actively being pulled RIGHT NOW?" check —
    /// replaces the earlier `@Query` lookup in `ModelDownloadStatusView`
    /// which wasn't reliable when SwiftUI recycled rows in `LazyVStack`.
    var activeRecordIDsByKey: [String: UUID] = [:]

    // MARK: - Per-backend active record tracking
    //
    // Services only know "am I currently pulling?" — they don't own a UUID
    // per download. The bridge assigns a UUID when the service flips to
    // `isPulling = true`, then uses it for every subsequent update.

    @ObservationIgnored private var ollamaActiveID: UUID?
    @ObservationIgnored private var mlxActiveID: UUID?
    @ObservationIgnored private var whisperActiveID: UUID?

    // Progress throttlers (1% delta) — one per backend. Reset on start.
    @ObservationIgnored private var ollamaThrottler = ProgressThrottler()
    @ObservationIgnored private var mlxThrottler = ProgressThrottler()
    @ObservationIgnored private var whisperThrottler = ProgressThrottler()

    // Speed samplers — keyed by record UUID rather than backend so that
    // (theoretically) multi-download scenarios work out-of-the-box if we
    // ever support them. Cleared on terminal transitions.
    @ObservationIgnored private var samplers: [UUID: SpeedSampler] = [:]

    /// Pre-seeded total byte counts, keyed by `"<backend>:<modelIdentifier>"`.
    /// MLX writes here from `DownloadCoordinator` (which hits the HF API
    /// before triggering the pull) so the bridge can attach a correct size
    /// to the fresh `DownloadRecord`. Consumed once on download-start and
    /// evicted.
    @ObservationIgnored private var pendingTotalBytes: [String: Int64] = [:]

    @ObservationIgnored private var ollamaObserver: ObservationStream?
    @ObservationIgnored private var mlxObserver: ObservationStream?
    @ObservationIgnored private var whisperObserver: ObservationStream?

    private init() {
        bindOllama()
        bindMLX()
        bindWhisper()
    }

    // MARK: - Pre-seed hook for coordinators

    /// Called by `DownloadCoordinator` before triggering a download when
    /// the total size is known up-front (MLX fetches from HF API). The
    /// bridge reads this on its next `isDownloading = true` transition
    /// and seeds the record's `fileSizeBytes`.
    func preSeedTotalBytes(backend: ModelBackendType, modelIdentifier: String, bytes: Int64?) {
        guard let bytes = bytes, bytes > 0 else { return }
        pendingTotalBytes[Self.presseedKey(backend, modelIdentifier)] = bytes
    }

    private static func presseedKey(_ backend: ModelBackendType, _ modelIdentifier: String) -> String {
        "\(backend.rawValue):\(modelIdentifier)"
    }

    // MARK: - Cancel routing

    func cancelDownload(_ record: DownloadRecord) {
        guard let backend = record.backend else { return }
        switch backend {
        case .ollama:
            OllamaService.shared.cancelPullModel()
        case .mlx:
            MLXModelService.shared.cancelDownload()
        case .whisper:
            Task { await WhisperModelDownloadService.shared.cancelDownload() }
        }
    }

    // MARK: - Shared progress application

    /// Unified progress handler used by all three bridges. Responsible for:
    ///   1. Feeding the sampler with the latest byte count (derived from
    ///      `completedBytes` if provided, otherwise `fractionalProgress ×
    ///      totalBytes`).
    ///   2. Publishing an `activeSpeeds` snapshot when the sampler has
    ///      enough data.
    ///   3. Persisting the progress update (throttled) to SwiftData.
    ///
    /// `completedBytes` is optional because MLX's progress closure only
    /// hands us a fraction — we reconstruct bytes from the pre-seeded
    /// `totalBytes`. Ollama and Whisper pass real bytes directly.
    private func applyProgress(
        recordID: UUID,
        fractionalProgress: Double,
        completedBytes: Int64?,
        totalBytes: Int64?,
        throttler: inout ProgressThrottler
    ) {
        // 1. Sample + snapshot (always — we want live MB/s even between
        //    throttled persistence writes).
        let bytesForSample: Int64? = {
            if let bytes = completedBytes { return bytes }
            if let total = totalBytes { return Int64(Double(total) * fractionalProgress) }
            return nil
        }()

        if let bytes = bytesForSample {
            var sampler = samplers[recordID] ?? SpeedSampler()
            sampler.record(bytes: bytes)
            samplers[recordID] = sampler

            if let speed = sampler.bytesPerSecond {
                let eta: TimeInterval? = totalBytes.flatMap { total in
                    let remaining = max(0, total - bytes)
                    return sampler.etaSeconds(remainingBytes: remaining)
                }
                activeSpeeds[recordID] = DownloadSpeedSnapshot(
                    bytesPerSecond: speed,
                    etaSeconds: eta
                )
            }
        }

        // 2. Persist if the throttle allows.
        if throttler.shouldWrite(progress: fractionalProgress) {
            _ = DownloadHistoryStore.shared.updateProgress(
                id: recordID,
                progress: fractionalProgress,
                fileSizeBytes: totalBytes
            )
        }
    }

    /// Terminal cleanup for a record — removes sampler + speed snapshot,
    /// clears backend-specific active ID + public active lookup.
    /// Called from each bridge's reconcile when the service flips
    /// `isDownloading = false`.
    private func clearTransients(recordID: UUID, backend: ModelBackendType, modelIdentifier: String) {
        samplers.removeValue(forKey: recordID)
        activeSpeeds.removeValue(forKey: recordID)
        activeRecordIDsByKey.removeValue(forKey: Self.presseedKey(backend, modelIdentifier))
    }

    /// Public lookup used by `ModelDownloadStatusView` — returns the
    /// currently-active record for a given (backend, model) pair, if any.
    /// Observable-safe because it reads `activeRecordIDsByKey` which is
    /// a stored @Observable property.
    func activeRecord(backend: ModelBackendType, modelIdentifier: String) -> DownloadRecord? {
        let key = Self.presseedKey(backend, modelIdentifier)
        guard let id = activeRecordIDsByKey[key] else { return nil }
        return DownloadHistoryStore.shared.fetch(id: id)
    }

    // MARK: - Ollama bridge

    private func bindOllama() {
        let service = OllamaService.shared
        ollamaObserver = ObservationStream(
            track: {
                _ = service.isPullingModel
                _ = service.pullProgress
                _ = service.modelToPull
                _ = service.modelPullError
                _ = service.pullCompletedBytes
                _ = service.pullTotalBytes
            },
            onChange: { [weak self] in
                self?.reconcileOllama(
                    isPulling: service.isPullingModel,
                    progress: service.pullProgress,
                    modelName: service.modelToPull,
                    errorMessage: service.modelPullError,
                    completedBytes: service.pullCompletedBytes,
                    totalBytes: service.pullTotalBytes
                )
            }
        )
    }

    private func reconcileOllama(
        isPulling: Bool,
        progress: Double,
        modelName: String,
        errorMessage: String?,
        completedBytes: Int64?,
        totalBytes: Int64?
    ) {
        if isPulling && !modelName.isEmpty {
            if let id = ollamaActiveID {
                applyProgress(
                    recordID: id,
                    fractionalProgress: progress,
                    completedBytes: completedBytes,
                    totalBytes: totalBytes,
                    throttler: &ollamaThrottler
                )
            } else {
                let id = UUID()
                ollamaActiveID = id
                ollamaThrottler.reset()
                samplers[id] = SpeedSampler()
                let preSeeded = pendingTotalBytes.removeValue(
                    forKey: Self.presseedKey(.ollama, modelName)
                )
                activeRecordIDsByKey[Self.presseedKey(.ollama, modelName)] = id
                _ = DownloadHistoryStore.shared.startDownload(
                    id: id,
                    backend: .ollama,
                    modelIdentifier: modelName,
                    displayName: modelName,
                    fileSizeBytes: preSeeded ?? totalBytes
                )
            }
        } else if let id = ollamaActiveID {
            let modelIdentifier = DownloadHistoryStore.shared.fetch(id: id)?.modelIdentifier ?? ""
            // Prefer backend-truth over percentage threshold. After a
            // successful pull, OllamaService `await`s `loadLocalModels`
            // before flipping `isPullingModel = false`, so by the time
            // we see the transition, `localModels` is fresh.
            let isInstalledNow = OllamaService.shared.localModels.contains { $0.name == modelIdentifier }
            if let err = errorMessage, !err.isEmpty {
                _ = DownloadHistoryStore.shared.markFailed(id: id, message: err)
            } else if isInstalledNow || progress >= 0.99 {
                _ = DownloadHistoryStore.shared.markCompleted(id: id, fileSizeBytes: totalBytes)
            } else {
                _ = DownloadHistoryStore.shared.markCancelled(id: id, reason: nil)
            }
            clearTransients(recordID: id, backend: .ollama, modelIdentifier: modelIdentifier)
            ollamaActiveID = nil
        }
    }

    // MARK: - MLX bridge

    private func bindMLX() {
        let service = MLXModelService.shared
        mlxObserver = ObservationStream(
            track: {
                _ = service.isDownloading
                _ = service.downloadProgress
                _ = service.currentDownloadName
                _ = service.errorMessage
            },
            onChange: { [weak self] in
                self?.reconcileMLX(
                    isDownloading: service.isDownloading,
                    progress: service.downloadProgress,
                    modelName: service.currentDownloadName,
                    errorMessage: service.errorMessage
                )
            }
        )
    }

    private func reconcileMLX(
        isDownloading: Bool,
        progress: Double,
        modelName: String,
        errorMessage: String?
    ) {
        if isDownloading && !modelName.isEmpty {
            if let id = mlxActiveID {
                // MLX doesn't expose completed bytes — the applyProgress
                // helper derives bytes from progress × totalBytes using
                // whatever we pre-seeded on the record.
                let totalBytes = DownloadHistoryStore.shared.fetch(id: id)?.fileSizeBytes
                applyProgress(
                    recordID: id,
                    fractionalProgress: progress,
                    completedBytes: nil,
                    totalBytes: totalBytes,
                    throttler: &mlxThrottler
                )
            } else {
                let id = UUID()
                mlxActiveID = id
                mlxThrottler.reset()
                samplers[id] = SpeedSampler()
                let preSeeded = pendingTotalBytes.removeValue(
                    forKey: Self.presseedKey(.mlx, modelName)
                )
                activeRecordIDsByKey[Self.presseedKey(.mlx, modelName)] = id
                _ = DownloadHistoryStore.shared.startDownload(
                    id: id,
                    backend: .mlx,
                    modelIdentifier: modelName,
                    displayName: modelName,
                    fileSizeBytes: preSeeded,
                    sourceURL: "https://huggingface.co/\(modelName)"
                )
            }
        } else if let id = mlxActiveID {
            let record = DownloadHistoryStore.shared.fetch(id: id)
            let totalBytes = record?.fileSizeBytes
            let modelIdentifier = record?.modelIdentifier ?? ""
            // MLXModelService calls `forceRefreshInstalledModels()`
            // (synchronous on MainActor) before flipping isDownloading,
            // so installedModels is fresh at this moment.
            let isInstalledNow = MLXModelService.shared.installedModels.contains {
                $0.displayName == modelIdentifier
            }
            if let err = errorMessage, !err.isEmpty {
                _ = DownloadHistoryStore.shared.markFailed(id: id, message: err)
            } else if isInstalledNow || progress >= 0.99 {
                _ = DownloadHistoryStore.shared.markCompleted(id: id, fileSizeBytes: totalBytes)
            } else {
                _ = DownloadHistoryStore.shared.markCancelled(id: id, reason: nil)
            }
            clearTransients(recordID: id, backend: .mlx, modelIdentifier: modelIdentifier)
            mlxActiveID = nil
        }
    }

    // MARK: - Whisper bridge

    private func bindWhisper() {
        let service = WhisperModelDownloadService.shared
        whisperObserver = ObservationStream(
            track: {
                _ = service.isDownloading
                _ = service.downloadProgress
                _ = service.downloadingModelId
                _ = service.downloadError
                _ = service.downloadCompletedBytes
                _ = service.downloadTotalBytes
            },
            onChange: { [weak self] in
                self?.reconcileWhisper(
                    isDownloading: service.isDownloading,
                    progress: service.downloadProgress,
                    modelName: service.downloadingModelId ?? "",
                    errorMessage: service.downloadError,
                    completedBytes: service.downloadCompletedBytes,
                    totalBytes: service.downloadTotalBytes
                )
            }
        )
    }

    private func reconcileWhisper(
        isDownloading: Bool,
        progress: Double,
        modelName: String,
        errorMessage: String?,
        completedBytes: Int64?,
        totalBytes: Int64?
    ) {
        if isDownloading && !modelName.isEmpty {
            if let id = whisperActiveID {
                // IMPORTANT: Whisper's `completedBytes` / `totalBytes` from
                // the service are *file counts* (WhisperKit's `Progress`
                // unit-count is per-file, not per-byte). Passing them to
                // the sampler rounds to ~0 B/s. Instead we ignore them and
                // derive bytes from `fileSizeBytes × fractionalProgress`
                // using the pre-seeded catalog size on the record.
                let recordTotal = DownloadHistoryStore.shared.fetch(id: id)?.fileSizeBytes
                applyProgress(
                    recordID: id,
                    fractionalProgress: progress,
                    completedBytes: nil,
                    totalBytes: recordTotal,
                    throttler: &whisperThrottler
                )
            } else {
                let id = UUID()
                whisperActiveID = id
                whisperThrottler.reset()
                samplers[id] = SpeedSampler()
                let preSeeded = pendingTotalBytes.removeValue(
                    forKey: Self.presseedKey(.whisper, modelName)
                )
                activeRecordIDsByKey[Self.presseedKey(.whisper, modelName)] = id
                _ = DownloadHistoryStore.shared.startDownload(
                    id: id,
                    backend: .whisper,
                    modelIdentifier: modelName,
                    displayName: modelName,
                    // `totalBytes` from the service is file count — fall
                    // back to the catalog estimate via preSeeded only.
                    fileSizeBytes: preSeeded
                )
            }
        } else if let id = whisperActiveID {
            let record = DownloadHistoryStore.shared.fetch(id: id)
            let modelIdentifier = record?.modelIdentifier ?? ""
            let recordTotal = record?.fileSizeBytes
            // WhisperModelDownloadService refreshes downloadedModelIds
            // before resetDownloadState flips isDownloading=false, so
            // this is the authoritative "installed?" check.
            let isInstalledNow = WhisperModelDownloadService.shared.downloadedModelIds.contains(modelIdentifier)
            if let err = errorMessage, !err.isEmpty {
                _ = DownloadHistoryStore.shared.markFailed(id: id, message: err)
            } else if isInstalledNow || progress >= 0.99 {
                _ = DownloadHistoryStore.shared.markCompleted(id: id, fileSizeBytes: recordTotal)
            } else {
                _ = DownloadHistoryStore.shared.markCancelled(id: id, reason: nil)
            }
            clearTransients(recordID: id, backend: .whisper, modelIdentifier: modelIdentifier)
            whisperActiveID = nil
        }
    }
}
