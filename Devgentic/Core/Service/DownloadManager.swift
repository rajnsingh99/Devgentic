// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2026 Raj Singh
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

    /// ⚠️ `rawValue` is a PERSISTENCE key (`DownloadRecord.backendRaw`, the pre-seed dictionary
    /// key). Never change it for display purposes.
    ///
    /// There is deliberately NO `localizedTitle` here, unlike the other enums the C2 sweep
    /// touched. These three are product names: a catalog entry mapping "Ollama" to "Ollama" in
    /// every locale is noise, and worse, it invites a translator to localize a proper noun.
    /// Display sites render `Text(verbatim: backend.rawValue)` and localize only the
    /// *fallback* prose ("Unknown", "the backend"), which is where the real defect was.
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

/// How a download ended, as decided by a bridge's terminal branch.
///
/// Typed rather than a raw string so the notification policy can be unit-tested without
/// driving a real download, and so a typo can't silently drop a case.
/// ⚠️ `CaseIterable` so the notification-policy test covers the real set rather than a
/// hand-written array that a new terminal state would slip past unnoticed.
enum DownloadTerminalClassification: String, CaseIterable {
    case completed
    case failed
    case cancelled
    case paused

    /// Whether finishing this way should reach the user, and how insistently.
    enum NotificationPolicy: Equatable {
        /// User-initiated — they pressed the button a moment ago.
        case silent
        /// Deliver even when the app is frontmost.
        case always
        /// Deliver only when the user has switched away.
        case whenAway
    }

    var notificationPolicy: NotificationPolicy {
        switch self {
        case .completed:
            // Visible in the sidebar row, the activity badge and the store card while the app
            // is in front, so notifying then would only duplicate what is already on screen.
            return .whenAway
        case .failed:
            // The only in-app failure surface is the MLX store's banner, which a user sitting
            // in a chat never sees — worth interrupting for wherever they are.
            return .always
        case .cancelled, .paused:
            return .silent
        }
    }
}

// MARK: - Download Manager

@Observable @MainActor
final class DownloadManager {
    static let shared = DownloadManager()

    @ObservationIgnored private let logger = DGLogger(category: "DownloadManager")

    // MARK: - Live counters (read from SwiftData on demand)

    /// ⚠️ Read `activeCount` / `hasActiveDownloads` from views, not this.
    ///
    /// `@Observable` only instruments STORED properties. This computed one touches nothing on
    /// `self` — it calls into `DownloadHistoryStore` (a plain `@MainActor` class) which runs a
    /// fetch and returns records without reading any observable property. Inside SwiftUI's
    /// `withObservationTracking` nothing gets registered, so a view built on it never
    /// invalidates: the activity-bar badge only appeared when its body happened to re-run for
    /// an unrelated reason (a hover changing `@State`), and went stale again afterwards —
    /// visibly disagreeing with the `@Query`-backed sidebar. It also costs a full predicated
    /// main-thread fetch per access.
    var activeRecords: [DownloadRecord] {
        DownloadHistoryStore.shared.fetchActive()
    }

    /// Stored, therefore actually observable. Maintained from the same bridge transitions
    /// that write `activeRecordIDsByKey`.
    private(set) var activeCount: Int = 0
    var hasActiveDownloads: Bool { activeCount > 0 }

    /// Recomputes the observable counter. Called on every bridge start/terminal transition;
    /// the fetch is the same one the computed property did, but now it happens once per
    /// actual state change rather than once per view-body evaluation.
    private func refreshActiveCount() {
        let count = DownloadHistoryStore.shared.fetchActive().count
        if count != activeCount {
            logger.info("[DOWNLOAD] Active download count \(self.activeCount) → \(count).")
            activeCount = count
        }
        // Single seam for the sleep assertion across all three backends: every bridge start
        // and terminal transition already routes through here. Keyed off the aggregate count
        // rather than per-download so a leaked key cannot pin the machine awake — when
        // nothing is active we release everything unconditionally.
        if count > 0 {
            DownloadPowerAssertion.shared.begin(
                "downloads",
                reason: "Downloading \(count) model\(count == 1 ? "" : "s")"
            )
        } else {
            DownloadPowerAssertion.shared.endAll()
        }
    }

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
        // ⚠️ Deliberately NOT priming `activeCount` here. This singleton is constructed
        // during launch BEFORE `DownloadHistoryStore.configureContainer` runs (that happens
        // in an async Task in DevgenticApp), so a fetch here hits an unconfigured container,
        // logs a hard error on every single launch, and returns 0 regardless of reality.
        // `DevgenticApp` calls `primeActiveCount()` once the container is up and orphans
        // have been reconciled.
    }

    /// Seeds `activeCount` after the SwiftData container is configured. Call once at launch,
    /// after `DownloadHistoryStore.reconcileOrphans()`.
    func primeActiveCount() {
        refreshActiveCount()
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

    // MARK: - Active-record identity

    /// True when `recordID`'s persisted `modelIdentifier` still matches the model the
    /// service reports as in-flight.
    ///
    /// The services expose a single download slot, but `isDownloading` does not return to
    /// false between one pull being superseded and its replacement starting — both happen
    /// in the same MainActor turn. Without this check the bridge only saw "still
    /// downloading", so the NEW model's progress ticks were persisted into the OLD model's
    /// record, and when the old pull's terminal branch fired it nil'd the active ID —
    /// leaving the new download with no record, no sidebar row and no cancel button.
    /// A missing record counts as a mismatch so we re-open rather than write into nothing.
    private func activeRecordMatches(_ recordID: UUID, modelName: String) -> Bool {
        DownloadHistoryStore.shared.fetch(id: recordID)?.modelIdentifier == modelName
    }

    /// Close a record whose download was superseded by a different model on the same
    /// backend, so the replacement can open a clean one.
    private func supersedeActiveRecord(
        _ recordID: UUID,
        backend: ModelBackendType,
        replacedBy modelName: String
    ) {
        let previous = DownloadHistoryStore.shared.fetch(id: recordID)?.modelIdentifier ?? "<record missing>"
        logger.error("[DOWNLOAD] \(backend.rawValue) active download changed identity mid-flight: '\(previous)' → '\(modelName)' (record \(recordID.uuidString)). CONSEQUENCE: closing the old record as superseded and opening a fresh one, so the new download gets its own progress, speed/ETA and cancel affordance.")
        _ = DownloadHistoryStore.shared.markCancelled(id: recordID, reason: "Superseded by \(modelName)")
        clearTransients(recordID: recordID, backend: backend, modelIdentifier: previous)
    }

    /// Logs how a terminal transition was classified. Every one of these branches was
    /// previously silent, so a download that ended up "failed" in history left no trace
    /// of which signal produced that verdict.
    private func logTerminal(
        backend: ModelBackendType,
        recordID: UUID,
        modelIdentifier: String,
        classification: DownloadTerminalClassification,
        progress: Double,
        isInstalledNow: Bool,
        errorMessage: String?
    ) {
        logger.notice("[DOWNLOAD] \(backend.rawValue) '\(modelIdentifier)' terminal → \(classification.rawValue) (record \(recordID.uuidString), progress=\(String(format: "%.3f", progress)), installedNow=\(isInstalledNow), error=\(errorMessage ?? "nil")).")
        notifyTerminal(backend: backend, modelIdentifier: modelIdentifier,
                       classification: classification, errorMessage: errorMessage)
    }

    /// Surfaces a finished download through the app's notification channel.
    ///
    /// Model downloads are the longest-running operation in the app — tens of minutes to hours
    /// — and the terminal transition used to write a SwiftData row and nothing else, so a user
    /// who switched away had to poll the sidebar to learn the model was ready.
    ///
    /// This is emitted from `logTerminal`, which every backend's reconcile already funnels
    /// through, so all three are covered by one seam rather than three parallel call sites.
    ///
    /// Two deliberate policy choices:
    ///
    /// 1. **Only completion and failure notify.** `cancelled` and `paused` are user-initiated —
    ///    the user pressed the button a moment ago and does not need telling.
    /// 2. **Success is suppressed while the app is frontmost; failure is not.** When the app is
    ///    in front, a successful download is already visible in the sidebar row, the activity
    ///    badge and the store card, so a banner would only duplicate what is on screen. A
    ///    FAILURE's only in-app surface is the MLX store's error banner, which a user sitting
    ///    in a chat never sees — so that one is worth interrupting for wherever they are.
    private func notifyTerminal(
        backend: ModelBackendType,
        modelIdentifier: String,
        classification: DownloadTerminalClassification,
        errorMessage: String?
    ) {
        let policy = classification.notificationPolicy
        guard policy != .silent else { return }
        let succeeded = (classification == .completed)

        Task.detached(priority: .utility) {
            if policy == .whenAway {
                // Mirrors ActiveStreamManager's rule: the QuickAccess panel can be key while
                // `NSApp.isActive` is false, so check both or a watched completion notifies
                // on top of what the user is already looking at.
                let userIsViewing = await MainActor.run {
                    NSApp.isActive || (AppDelegate.shared?.isQuickAccessPanelKey ?? false)
                }
                if userIsViewing { return }
            }

            let payload = AppNotificationPayload(
                title: succeeded ? "Model ready" : "Download failed",
                body: succeeded
                    ? "\(modelIdentifier) finished downloading."
                    : "\(modelIdentifier) — \(errorMessage ?? "the download did not complete").",
                metadata: [
                    "source": "download",
                    "backend": backend.rawValue,
                    "model": modelIdentifier
                ]
            )
            await NotificationDispatcher.shared.dispatch(payload)
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
        refreshActiveCount()
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
            if let id = ollamaActiveID, activeRecordMatches(id, modelName: modelName) {
                applyProgress(
                    recordID: id,
                    fractionalProgress: progress,
                    completedBytes: completedBytes,
                    totalBytes: totalBytes,
                    throttler: &ollamaThrottler
                )
            } else {
                if let stale = ollamaActiveID {
                    supersedeActiveRecord(stale, backend: .ollama, replacedBy: modelName)
                }
                let id = UUID()
                ollamaActiveID = id
                ollamaThrottler.reset()
                samplers[id] = SpeedSampler()
                let preSeeded = pendingTotalBytes.removeValue(
                    forKey: Self.presseedKey(.ollama, modelName)
                )
                activeRecordIDsByKey[Self.presseedKey(.ollama, modelName)] = id
                defer { refreshActiveCount() }
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
            // Prefer backend-truth over percentage threshold. After a successful pull,
            // OllamaService awaits its refresh before flipping `isPullingModel = false`, so by
            // the time we see the transition, `localModels` is fresh.
            //
            // ⚠️ THIS COMMENT WAS AN ASSERTION THE CODE DID NOT HONOUR. The refresh call was
            // `loadLocalModels()`, whose first line is `guard …, !isPullingModel, … else
            // { return }` — and `isPullingModel` is still true at that point, so it returned
            // having fetched nothing and `isInstalledNow` was ALWAYS false. Classification
            // silently rested on the `progress >= 0.99` fallback below. The pull path now calls
            // an unguarded `performLocalModelRefresh()`; if that is ever reverted, this line goes
            // back to being a lie and this branch goes back to being dead.
            let isInstalledNow = OllamaService.shared.localModels.contains { $0.name == modelIdentifier }
            let classification: DownloadTerminalClassification
            if let err = errorMessage, !err.isEmpty {
                classification = .failed
                _ = DownloadHistoryStore.shared.markFailed(id: id, message: err)
            } else if isInstalledNow || progress >= 0.99 {
                classification = .completed
                _ = DownloadHistoryStore.shared.markCompleted(id: id, fileSizeBytes: totalBytes)
            } else {
                classification = .cancelled
                _ = DownloadHistoryStore.shared.markCancelled(id: id, reason: nil)
            }
            logTerminal(backend: .ollama, recordID: id, modelIdentifier: modelIdentifier,
                        classification: classification, progress: progress,
                        isInstalledNow: isInstalledNow, errorMessage: errorMessage)
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
            if let id = mlxActiveID, activeRecordMatches(id, modelName: modelName) {
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
                if let stale = mlxActiveID {
                    supersedeActiveRecord(stale, backend: .mlx, replacedBy: modelName)
                }
                let id = UUID()
                mlxActiveID = id
                mlxThrottler.reset()
                samplers[id] = SpeedSampler()
                let preSeeded = pendingTotalBytes.removeValue(
                    forKey: Self.presseedKey(.mlx, modelName)
                )
                activeRecordIDsByKey[Self.presseedKey(.mlx, modelName)] = id
                defer { refreshActiveCount() }
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
            // Goes through the shared identity comparator: an exact `displayName ==` test
            // never matched for publishers other than `mlx-community`, so a successful
            // download of those fell through to the `progress >= 0.99` fallback and could
            // be written to history as `.cancelled`.
            let isInstalledNow = MLXModelService.shared.isInstalled(repoId: modelIdentifier)
            let classification: DownloadTerminalClassification
            if let err = errorMessage, !err.isEmpty {
                classification = .failed
                _ = DownloadHistoryStore.shared.markFailed(id: id, message: err)
            } else if isInstalledNow || progress >= 0.99 {
                classification = .completed
                _ = DownloadHistoryStore.shared.markCompleted(id: id, fileSizeBytes: totalBytes)
            } else if MLXModelService.shared.pausedRepoId == modelIdentifier {
                // A pause and a cancel both stop the task; only the pause keeps the bytes, so
                // recording it as cancelled would tell the user their progress was discarded.
                classification = .paused
                _ = DownloadHistoryStore.shared.markPaused(id: id)
            } else {
                classification = .cancelled
                _ = DownloadHistoryStore.shared.markCancelled(id: id, reason: nil)
            }
            logTerminal(backend: .mlx, recordID: id, modelIdentifier: modelIdentifier,
                        classification: classification, progress: progress,
                        isInstalledNow: isInstalledNow, errorMessage: errorMessage)
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
            if let id = whisperActiveID, activeRecordMatches(id, modelName: modelName) {
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
                if let stale = whisperActiveID {
                    supersedeActiveRecord(stale, backend: .whisper, replacedBy: modelName)
                }
                let id = UUID()
                whisperActiveID = id
                whisperThrottler.reset()
                samplers[id] = SpeedSampler()
                let preSeeded = pendingTotalBytes.removeValue(
                    forKey: Self.presseedKey(.whisper, modelName)
                )
                activeRecordIDsByKey[Self.presseedKey(.whisper, modelName)] = id
                defer { refreshActiveCount() }
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
            let classification: DownloadTerminalClassification
            if let err = errorMessage, !err.isEmpty {
                classification = .failed
                _ = DownloadHistoryStore.shared.markFailed(id: id, message: err)
            } else if isInstalledNow || progress >= 0.99 {
                classification = .completed
                _ = DownloadHistoryStore.shared.markCompleted(id: id, fileSizeBytes: recordTotal)
            } else {
                classification = .cancelled
                _ = DownloadHistoryStore.shared.markCancelled(id: id, reason: nil)
            }
            logTerminal(backend: .whisper, recordID: id, modelIdentifier: modelIdentifier,
                        classification: classification, progress: progress,
                        isInstalledNow: isInstalledNow, errorMessage: errorMessage)
            clearTransients(recordID: id, backend: .whisper, modelIdentifier: modelIdentifier)
            whisperActiveID = nil
        }
    }
}
