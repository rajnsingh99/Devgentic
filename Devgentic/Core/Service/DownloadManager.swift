// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
//
//  DownloadManager.swift
//  Devgentic
//
//  Created by Raj Singh.
//

import SwiftUI

// MARK: - Models

/// The backend a model download comes from (Ollama, MLX or Whisper). `DownloadManager` bridges each backend
/// service's in-memory download state into the SwiftData-backed `DownloadHistoryStore`.
enum ModelBackendType: String, Equatable, Hashable {
    case ollama  = "Ollama"
    case mlx     = "MLX"
    case whisper = "Whisper"

    /// `rawValue` is a persistence key (`DownloadRecord.backendRaw`, the pre-seed dictionary key); never change
    /// it for display. There is no `localizedTitle`: these are product names, so display sites render
    /// `Text(verbatim: backend.rawValue)` and localize only fallback prose.
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

/// How a download ended, as decided by a bridge's terminal branch. Typed rather than a raw string so the
/// notification policy is unit-testable and a typo cannot silently drop a case. `CaseIterable` so the policy
/// test covers the real set.
private let classifierLogger = DGLogger(category: "DownloadManager")

// Why: a percentage says how far a download got, never how it stopped
/// How a download ended, as the service that ran it saw it. Recorded by the service itself, synchronously,
/// before it flips `isDownloading` off, so the history bridge reads the truth instead of inferring it.
enum DownloadEnding: String, Equatable, Sendable {
    case succeeded, failed, cancelled, paused
}

/// A `DownloadEnding` and the model it belongs to, so a bridge never applies one download's
/// ending to another's record.
struct RecordedDownloadEnding: Equatable, Sendable {
    let modelID: String
    let ending: DownloadEnding
}

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

    // Why: `@Observable` only instruments stored properties: this one reads no observable state, so a view
    // built on it never invalidates
    /// Computed on demand with a main-thread fetch per access; read `activeCount` / `hasActiveDownloads` from
    /// views instead.
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
        // Single seam for the sleep assertion across all three backends; keyed off the aggregate count so a leaked
        // key cannot pin the machine awake.
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

    /// Active record IDs keyed by `"<backend>:<modelIdentifier>"`. Published separately from `activeSpeeds`
    /// because the speed dictionary only fills once the sampler has enough data, whereas this flips the moment a
    /// bridge sees `isDownloading = true`.
    var activeRecordIDsByKey: [String: UUID] = [:]

    // MARK: - Per-backend active record tracking
    // Services only know "am I currently pulling?", not a UUID per download; the bridge assigns one when the
    // service flips to `isPulling = true` and uses it for every later update.

    @ObservationIgnored private var ollamaActiveID: UUID?
    @ObservationIgnored private var mlxActiveID: UUID?
    @ObservationIgnored private var whisperActiveID: UUID?

    // Progress throttlers (1% delta) — one per backend. Reset on start.
    @ObservationIgnored private var ollamaThrottler = ProgressThrottler()
    @ObservationIgnored private var mlxThrottler = ProgressThrottler()
    @ObservationIgnored private var whisperThrottler = ProgressThrottler()

    // Speed samplers keyed by record UUID rather than backend, so concurrent downloads would work; cleared on
    // terminal transitions.
    @ObservationIgnored private var samplers: [UUID: SpeedSampler] = [:]

    /// Pre-seeded total byte counts keyed by `"<backend>:<modelIdentifier>"`; MLX writes here from
    /// `DownloadCoordinator` (which queries the HF API before the pull) so the bridge can attach a correct size.
    /// Consumed once on download start, then evicted.
    @ObservationIgnored private var pendingTotalBytes: [String: Int64] = [:]

    @ObservationIgnored private var ollamaObserver: ObservationStream?
    @ObservationIgnored private var mlxObserver: ObservationStream?
    @ObservationIgnored private var whisperObserver: ObservationStream?

    private init() {
        bindOllama()
        bindMLX()
        bindWhisper()
        // Why: this singleton is built before `DownloadHistoryStore.configureContainer` runs, so a fetch here hits
        // an unconfigured container
        // `activeCount` is not primed here; `DevgenticApp` calls `primeActiveCount()` once the container is up and
        // orphans are reconciled.
    }

    /// Seeds `activeCount` after the SwiftData container is configured. Call once at launch,
    /// after `DownloadHistoryStore.reconcileOrphans()`.
    func primeActiveCount() {
        refreshActiveCount()
    }

    // MARK: - Pre-seed hook for coordinators

    /// Called by `DownloadCoordinator` before a download when the total size is known up front (MLX fetches it
    /// from the HF API); the bridge reads it on the next `isDownloading = true` transition and seeds the record's
    /// `fileSizeBytes`.
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

    /// Unified progress handler for all three bridges: feeds the speed sampler, publishes an `activeSpeeds`
    /// snapshot once it has enough data, and persists (throttled) to SwiftData. `completedBytes` is optional
    /// because MLX reports only a fraction; bytes are rebuilt from the pre-seeded `totalBytes`.
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

    // Why: `isDownloading` stays true when one pull is superseded by another in the same MainActor turn, so
    // progress would be persisted into the old record
    /// True when `recordID`'s persisted `modelIdentifier` still matches the model the service reports as in
    /// flight; a missing record counts as a mismatch so the bridge re-opens rather than write into nothing.
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

    /// Logs how a terminal transition was classified, so a download recorded as failed shows which signal
    /// produced the verdict.
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

    /// Surfaces a finished download through the notification channel (called from `logTerminal`, which every
    /// backend funnels through). Only completion and failure notify (cancel and pause are user-initiated);
    /// success is suppressed while the app is frontmost, failure is not.
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
                // Mirrors ActiveStreamManager's rule: the QuickAccess panel can be key while `NSApp.isActive` is false, so
                // check both or a watched completion notifies on top of what the user is looking at.
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

    /// Terminal cleanup for a record: removes the sampler and speed snapshot and clears the backend-specific
    /// active ID and public active lookup; called from each bridge's reconcile when the service flips
    /// `isDownloading = false`.
    private func clearTransients(recordID: UUID, backend: ModelBackendType, modelIdentifier: String) {
        samplers.removeValue(forKey: recordID)
        activeSpeeds.removeValue(forKey: recordID)
        activeRecordIDsByKey.removeValue(forKey: Self.presseedKey(backend, modelIdentifier))
        refreshActiveCount()
    }

    /// Public lookup used by `ModelDownloadStatusView`: the currently-active record for a (backend, model) pair,
    /// if any. Observable-safe because it reads the stored `activeRecordIDsByKey`.
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
                _ = service.pullTerminalState
            },
            onChange: { [weak self] in
                self?.reconcileOllama(
                    isPulling: service.isPullingModel,
                    progress: service.pullProgress,
                    modelName: service.modelToPull,
                    errorMessage: service.modelPullError,
                    completedBytes: service.pullCompletedBytes,
                    totalBytes: service.pullTotalBytes,
                    terminalState: service.pullTerminalState
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
        totalBytes: Int64?,
        terminalState: OllamaService.PullTerminalState? = nil
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
            // Why: the refresh must be the unguarded `performLocalModelRefresh()`: `loadLocalModels()` returns early
            // while `isPullingModel` is true
            // Prefers backend truth over a percentage threshold: after a successful pull `OllamaService` awaits its
            // refresh before flipping `isPullingModel = false`, so `localModels` is fresh at the transition.
            let isInstalledNow = OllamaService.shared.localModels.contains { $0.name == modelIdentifier }
            let classification = Self.classifyOllamaPull(terminalState: terminalState, errorMessage: errorMessage,
                                                         isInstalledNow: isInstalledNow)
            switch classification {
            case .failed:    _ = DownloadHistoryStore.shared.markFailed(id: id, message: errorMessage ?? "The pull failed.")
            case .completed: _ = DownloadHistoryStore.shared.markCompleted(id: id, fileSizeBytes: totalBytes)
            default:         _ = DownloadHistoryStore.shared.markCancelled(id: id, reason: nil)
            }
            logTerminal(backend: .ollama, recordID: id, modelIdentifier: modelIdentifier,
                        classification: classification, progress: progress,
                        isInstalledNow: isInstalledNow, errorMessage: errorMessage)
            clearTransients(recordID: id, backend: .ollama, modelIdentifier: modelIdentifier)
            ollamaActiveID = nil
        }
    }

    // Why: Ollama reports progress per layer and a cancel clears the error, so a pull cancelled near a layer's
    // end would look finished
    /// How a finished Ollama pull is recorded. The service's own terminal state decides; without one, only an
    /// error or the installed list decides, never the percentage.
    static func classifyOllamaPull(terminalState: OllamaService.PullTerminalState?, errorMessage: String?,
                                   isInstalledNow: Bool) -> DownloadTerminalClassification {
        switch terminalState {
        case .succeeded?: return .completed
        case .cancelled?: return .cancelled
        case .failed?:    return .failed
        case .started?, nil:
            if let err = errorMessage, !err.isEmpty { return .failed }
            return isInstalledNow ? .completed : .cancelled
        }
    }

    // Why: progress is no evidence of how a download stopped: a success the installed scan does not list would
    // be recorded as cancelled
    /// How a finished MLX or Whisper download is recorded. The service's own `lastDownloadEnding` decides;
    /// without one for this model, only the error, the pause marker and the installed list decide, never the
    /// percentage.
    static func classifyEndedDownload(
        backend: ModelBackendType, modelIdentifier: String, ending: RecordedDownloadEnding?,
        errorMessage: String?, isInstalledNow: Bool, isPausedNow: Bool
    ) -> DownloadTerminalClassification {
        if let ending, ending.modelID == modelIdentifier {
            switch ending.ending {
            case .succeeded:
                if !isInstalledNow {
                    classifierLogger.warning("[DOWNLOAD] \(backend.rawValue) '\(modelIdentifier)' finished successfully but is NOT in the installed list. CONSEQUENCE: recorded as completed, because the download did complete; if the model does not appear in the picker, its folder layout is not one the scanner recognises.")
                }
                return .completed
            case .failed:    return .failed
            case .cancelled: return .cancelled
            case .paused:    return .paused
            }
        }
        if let ending {
            classifierLogger.error("[DOWNLOAD] \(backend.rawValue) ending for '\(ending.modelID)' does not belong to the record for '\(modelIdentifier)'. CONSEQUENCE: it is ignored, and this record is classified from the error, pause marker and installed list.")
        }
        if let err = errorMessage, !err.isEmpty { return .failed }
        if isInstalledNow { return .completed }
        return isPausedNow ? .paused : .cancelled
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
                // MLX exposes no completed bytes: `applyProgress` derives bytes from progress × totalBytes, using the size
                // pre-seeded on the record.
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
            // `MLXModelService` refreshes the installed list before flipping `isDownloading`, so `installedModels` is
            // fresh here; the shared identity comparator handles non-`mlx-community` publishers.
            let isInstalledNow = MLXModelService.shared.isInstalled(repoId: modelIdentifier)
            // A pause and a cancel both stop the task; only the pause keeps the bytes, so
            // recording it as cancelled would tell the user their progress was discarded.
            let classification = Self.classifyEndedDownload(
                backend: .mlx, modelIdentifier: modelIdentifier,
                ending: MLXModelService.shared.lastDownloadEnding,
                errorMessage: errorMessage, isInstalledNow: isInstalledNow,
                isPausedNow: MLXModelService.shared.pausedRepoId == modelIdentifier)
            switch classification {
            case .failed:    _ = DownloadHistoryStore.shared.markFailed(id: id, message: errorMessage ?? "Download failed")
            case .completed: _ = DownloadHistoryStore.shared.markCompleted(id: id, fileSizeBytes: totalBytes)
            case .paused:    _ = DownloadHistoryStore.shared.markPaused(id: id)
            case .cancelled: _ = DownloadHistoryStore.shared.markCancelled(id: id, reason: nil)
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
                // Whisper's `completedBytes` / `totalBytes` are file counts (WhisperKit progress is per file), so bytes are
                // derived from `fileSizeBytes × fractionalProgress` using the pre-seeded catalog size.
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
            // `WhisperModelDownloadService` refreshes `downloadedModelIds` before `resetDownloadState` flips
            // `isDownloading = false`, so this is the authoritative "installed?" check.
            let isInstalledNow = WhisperModelDownloadService.shared.downloadedModelIds.contains(modelIdentifier)
            let classification = Self.classifyEndedDownload(
                backend: .whisper, modelIdentifier: modelIdentifier,
                ending: WhisperModelDownloadService.shared.lastDownloadEnding,
                errorMessage: errorMessage, isInstalledNow: isInstalledNow, isPausedNow: false)
            switch classification {
            case .failed:    _ = DownloadHistoryStore.shared.markFailed(id: id, message: errorMessage ?? "Download failed")
            case .completed: _ = DownloadHistoryStore.shared.markCompleted(id: id, fileSizeBytes: recordTotal)
            case .paused:    _ = DownloadHistoryStore.shared.markPaused(id: id)
            case .cancelled: _ = DownloadHistoryStore.shared.markCancelled(id: id, reason: nil)
            }
            logTerminal(backend: .whisper, recordID: id, modelIdentifier: modelIdentifier,
                        classification: classification, progress: progress,
                        isInstalledNow: isInstalledNow, errorMessage: errorMessage)
            clearTransients(recordID: id, backend: .whisper, modelIdentifier: modelIdentifier)
            whisperActiveID = nil
        }
    }
}
