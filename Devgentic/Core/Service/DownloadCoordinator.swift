// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2026 Raj Singh
//
//  DownloadCoordinator.swift
//  Devgentic
//
//  Created 2026-04-21.
//
//  Thin idempotent front-door for "start a download of model X" requests
//  coming from the Ollama / MLX / Whisper model managers and the Downloads
//  sidebar. Two jobs:
//
//    1. Decide whether a request should actually kick off a new download,
//       or short-circuit to "already installed" / "already in progress" /
//       "resumed from history".
//    2. When we do start, dispatch to the right backend service (which in
//       turn flips its own @Observable state; DownloadManager's bridges
//       then write the record).
//
//  Keeping the check here — rather than inside each service — means the
//  services stay focused on the actual transport (HTTP / HuggingFace
//  Hub / WhisperKit) and every UI surface gets the same "is this already
//  done?" semantics.
//

import Foundation

private let logger = DGLogger(category: "DownloadCoordinator")

/// Holds an `NSProcessInfo` activity for the lifetime of a download so the system does not
/// idle-sleep mid-transfer.
///
/// There was no power assertion anywhere in the app: a laptop on battery pulling a 30 GB
/// model hit its sleep timer and the transfer stalled, showing a frozen progress bar with no
/// explanation and no log line. Display sleep is deliberately still allowed — only *idle
/// system* sleep is suppressed, so the screen still dims and the machine still sleeps when
/// the lid closes.
@MainActor
final class DownloadPowerAssertion {

    static let shared = DownloadPowerAssertion()
    private init() {}

    private var tokens: [String: NSObjectProtocol] = [:]

    func begin(_ key: String, reason: String) {
        guard tokens[key] == nil else { return }
        tokens[key] = ProcessInfo.processInfo.beginActivity(
            options: [.idleSystemSleepDisabled, .userInitiated],
            reason: reason
        )
        logger.info("[DOWNLOAD] Holding a power assertion for \(key) — \(reason). The system will not idle-sleep until it ends.")
    }

    func end(_ key: String) {
        guard let token = tokens.removeValue(forKey: key) else { return }
        ProcessInfo.processInfo.endActivity(token)
        logger.info("[DOWNLOAD] Released the power assertion for \(key); normal idle sleep resumes.")
    }

    /// Releases every assertion. Called when no download is active, so a leaked key can
    /// never pin the machine awake indefinitely.
    func endAll() {
        for key in tokens.keys { end(key) }
    }
}

enum DownloadStartOutcome: Equatable {
    /// The model is present on disk right now — nothing to do. UI should
    /// show an "Already installed" toast (or silent no-op when triggered
    /// from an "Install" button that was mid-render stale).
    case alreadyInstalled

    /// There's already an in-flight download for this model; the caller
    /// should surface the existing progress, not start a duplicate.
    case alreadyInProgress(recordID: UUID)

    /// The history store thought it was installed, but the filesystem
    /// disagrees (user deleted outside the app, corruption, etc.). We
    /// marked the old record stale and kicked off a fresh pull.
    case resumedFromHistory

    /// Brand new download — no prior history or active session.
    case startedFresh

    /// Soft refusal — backend is unreachable, identifier invalid, etc.
    /// Includes a message suitable for toast display.
    case failed(String)
}

@MainActor
enum DownloadCoordinator {

    // MARK: - Ollama

    /// Triggers an Ollama model pull if the model isn't already on the
    /// server's `/api/tags` list. Ollama is the one backend that doesn't
    /// have a local filesystem check — the server is the truth.
    @discardableResult
    static func startOllamaDownloadIfNeeded(
        modelName: String,
        profileID: UUID? = nil
    ) async -> DownloadStartOutcome {
        let trimmed = modelName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return .failed("Model name is empty") }

        let ollama = OllamaService.shared

        // Installed? (server-sourced truth)
        if ollama.localModels.contains(where: { $0.name == trimmed }) {
            // Make sure history reflects reality — if the user previously
            // failed/cancelled this model, mark it completed retroactively
            // so "Installed" badges stay consistent with server state.
            promoteStaleRecordIfNeeded(backend: .ollama, modelIdentifier: trimmed)
            return .alreadyInstalled
        }

        // Active in-flight?
        if let active = DownloadHistoryStore.shared.fetchMostRecent(
            backend: .ollama,
            modelIdentifier: trimmed
        ), active.isActive {
            return .alreadyInProgress(recordID: active.id)
        }

        // Prior record says completed but server disagrees → stale, prune.
        let outcomeForHistory = pruneStaleIfCompletedButMissing(
            backend: .ollama,
            modelIdentifier: trimmed,
            isPresentOnDisk: false
        )

        // `pullModel` refuses silently while another pull is in flight, and its result is
        // never inspected — so the coordinator used to report `.startedFresh` and the UI
        // toasted "Downloading B…" while nothing happened at all. The in-flight check above
        // is scoped to the SAME identifier, so pulling B during A sails past it. Check the
        // service's actual state here.
        if ollama.isPullingModel {
            return .failed("\(ollama.modelToPull) is still downloading — Ollama pulls one model at a time.")
        }
        if ollama.isRemovingModel {
            return .failed("Can't start a download while another model is being removed.")
        }

        // OllamaService.pullModel is async; fire-and-forget so callers get
        // the outcome synchronously. Progress flows via @Observable state.
        Task { await ollama.pullModel(name: trimmed, baseURL: ollama.ollamaBaseURL) }
        return outcomeForHistory
    }

    // MARK: - MLX

    /// - Parameter force: skip the "already installed" short-circuit and re-pull.
    ///   Without this, Re-download was a guaranteed no-op for any installed model: all three
    ///   re-download entry points funnel through here, the installed check reads the
    ///   filesystem, and deleting the history record (which is all `force` used to do)
    ///   changes nothing. A user with a truncated or corrupt model confirmed an alert
    ///   promising "Existing files will be overwritten" and got "already installed" instead.
    ///   A forced pull is a genuine repair: `HubFileDownloader` verifies etag/SHA-256 per
    ///   file and re-fetches only mismatches, so intact shards are not re-downloaded.
    @discardableResult
    static func startMLXDownloadIfNeeded(
        repoId: String,
        profileID: UUID? = nil,
        force: Bool = false
    ) async -> DownloadStartOutcome {
        let trimmed = repoId.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return .failed("Repo ID is empty") }

        let mlx = MLXModelService.shared
        // ⚠️ Wait for the scan before the install check. It is off-actor now, so an early
        // call can see an empty list, conclude "not installed", and re-pull a multi-gigabyte
        // model the user already has.
        await mlx.ensureLoaded()
        // Identity goes through `MLXModelIdentity` (see `isInstalled(repoId:)`) so models
        // from publishers other than `mlx-community` — and profiles that stored a bare,
        // author-less name before the canonical-id fix — still resolve.
        let isInstalled = mlx.isInstalled(repoId: trimmed)

        if isInstalled && !force {
            promoteStaleRecordIfNeeded(backend: .mlx, modelIdentifier: trimmed)
            return .alreadyInstalled
        }
        if isInstalled && force {
            logger.notice("[DOWNLOAD] Forced re-pull of already-installed MLX model '\(trimmed)' — HubApi will hash-verify each file and re-fetch only mismatches.")
        }

        if let active = DownloadHistoryStore.shared.fetchMostRecent(
            backend: .mlx,
            modelIdentifier: trimmed
        ), active.isActive {
            return .alreadyInProgress(recordID: active.id)
        }

        // MLX has a single download slot: `MLXModelService.downloadModel` now refuses
        // rather than pre-empting an in-flight pull (it used to silently cancel it and
        // corrupt the DownloadManager bridge's record bookkeeping). Detect that here so
        // the caller shows a `.failed` toast explaining WHY nothing happened — otherwise
        // the refusal reads to the user as a dead Download button.
        if mlx.isDownloading, !mlx.currentDownloadName.isEmpty, mlx.currentDownloadName != trimmed {
            return .failed("\(mlx.currentDownloadName) is still downloading — cancel it before starting another.")
        }

        let outcomeForHistory = pruneStaleIfCompletedButMissing(
            backend: .mlx,
            modelIdentifier: trimmed,
            isPresentOnDisk: false
        )

        // Pre-fetch total bytes from HuggingFace so the speed/ETA display
        // has an authoritative denominator from the first progress tick.
        // Nil on failure — the bridge handles that gracefully (MB/s may
        // show only after bytes begin to accumulate).
        let totalBytes = await mlx.getTotalBytesForModel(repoId: trimmed)

        // Disk preflight. The exact size is already in hand and was previously used ONLY as
        // an ETA denominator — nothing compared it to free space. The store's own top-30 MLX
        // listing includes a 657 GB repo, so on a 512 GB laptop the RAM advisory fires, the
        // user clicks "Download Anyway", and the pull fills the startup disk until macOS
        // starts failing. Unknown free space proceeds rather than blocks: a failed stat must
        // not stop a legitimate download.
        // ⚠️ Preflight what will actually be FETCHED, not the repo's full size. On a forced
        // re-download HubApi hash-verifies each file and re-fetches only mismatches (see the
        // log above), so charging the whole repo against free space made A7's repair path
        // unreachable exactly when it is needed: a 40 GB model that is corrupt but present
        // could not be repaired with 18 GB free, even though the repair might fetch one shard.
        // `resumeMLXDownload` already sizes the remainder this way.
        let alreadyOnDisk = MLXModelService.resumableBytes(at: mlx.partialDownloadFolder(for: trimmed))
        let bytesToFetch = totalBytes.map { max(0, $0 - alreadyOnDisk) }
        if let bytes = bytesToFetch, let room = mlx.hasRoomForDownload(ofBytes: bytes), !room.fits {
            let needed = ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
            let free = ByteCountFormatter.string(fromByteCount: room.free, countStyle: .file)
            let reuse = alreadyOnDisk > 0
                ? " (\(ByteCountFormatter.string(fromByteCount: alreadyOnDisk, countStyle: .file)) already on disk is re-used)"
                : ""
            logger.error("[DOWNLOAD] REFUSING MLX download of '\(trimmed)' — needs \(needed) plus \(ByteCountFormatter.string(fromByteCount: MLXModelService.diskHeadroomBytes, countStyle: .file)) headroom, only \(free) free\(reuse). CONSEQUENCE: the download is not started; it would otherwise fill the startup disk and fail partway, stranding every byte it had written.")
            return .failed("\(trimmed) needs \(needed) but only \(free) is free.")
        }

        DownloadManager.shared.preSeedTotalBytes(
            backend: .mlx,
            modelIdentifier: trimmed,
            bytes: totalBytes
        )

        // MLX service's `downloadModel` is synchronous — it schedules the
        // actual pull on an internal Task and flips @Observable state from
        // there. It returns false if it refused the request (a pull started
        // in the window between our check above and this call).
        guard mlx.downloadModel(repoId: trimmed) else {
            return .failed("Couldn't start the download — another model is already downloading.")
        }
        return outcomeForHistory
    }

    /// Resumes a paused or interrupted MLX download from the bytes already on disk.
    ///
    /// Deliberately separate from `startMLXDownloadIfNeeded`: that path's install check and
    /// disk preflight are about *starting* something new. A resume continues work already paid
    /// for, so it skips the install short-circuit and only needs the remaining bytes to fit.
    @discardableResult
    static func resumeMLXDownload(repoId: String) async -> DownloadStartOutcome {
        let trimmed = repoId.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return .failed("Repo ID is empty") }

        let mlx = MLXModelService.shared
        if mlx.isDownloading, !mlx.currentDownloadName.isEmpty, mlx.currentDownloadName != trimmed {
            return .failed("\(mlx.currentDownloadName) is still downloading — cancel it before resuming another.")
        }

        // Preflight on what is LEFT, not the whole model — most of it may already be on disk.
        let alreadyOnDisk = MLXModelService.resumableBytes(at: mlx.partialDownloadFolder(for: trimmed))
        if let total = await mlx.getTotalBytesForModel(repoId: trimmed) {
            let remaining = max(0, total - alreadyOnDisk)
            if let room = mlx.hasRoomForDownload(ofBytes: remaining), !room.fits {
                let needed = ByteCountFormatter.string(fromByteCount: remaining, countStyle: .file)
                let free = ByteCountFormatter.string(fromByteCount: room.free, countStyle: .file)
                logger.error("[DOWNLOAD] REFUSING to resume '\(trimmed)' — \(needed) still to fetch but only \(free) free. CONSEQUENCE: the resume is not started; the partial bytes are left intact.")
                return .failed("\(trimmed) needs \(needed) more but only \(free) is free.")
            }
            DownloadManager.shared.preSeedTotalBytes(backend: .mlx, modelIdentifier: trimmed, bytes: total)
        }

        guard mlx.resumeDownload(repoId: trimmed) else {
            return .failed("Couldn't resume — another model is already downloading.")
        }
        return .resumedFromHistory
    }

    // MARK: - Whisper

    @discardableResult
    static func startWhisperDownloadIfNeeded(
        modelId: String,
        profileID: UUID? = nil
    ) async -> DownloadStartOutcome {
        let trimmed = modelId.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return .failed("Model ID is empty") }

        let whisper = WhisperModelDownloadService.shared
        let isInstalled = whisper.downloadedModelIds.contains(trimmed)

        if isInstalled {
            promoteStaleRecordIfNeeded(backend: .whisper, modelIdentifier: trimmed)
            return .alreadyInstalled
        }

        if let active = DownloadHistoryStore.shared.fetchMostRecent(
            backend: .whisper,
            modelIdentifier: trimmed
        ), active.isActive {
            return .alreadyInProgress(recordID: active.id)
        }

        let outcomeForHistory = pruneStaleIfCompletedButMissing(
            backend: .whisper,
            modelIdentifier: trimmed,
            isPresentOnDisk: false
        )

        // Same disk preflight as MLX, using the catalog estimate — it is the only size
        // available before the pull starts.
        if let bytes = WhisperModelCatalog.estimatedBytes(for: trimmed),
           let room = MLXModelService.shared.hasRoomForDownload(ofBytes: bytes), !room.fits {
            let needed = ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
            let free = ByteCountFormatter.string(fromByteCount: room.free, countStyle: .file)
            logger.error("[DOWNLOAD] REFUSING Whisper download of '\(trimmed)' — needs \(needed), only \(free) free. CONSEQUENCE: the download is not started rather than filling the startup disk.")
            return .failed("\(trimmed) needs \(needed) but only \(free) is free.")
        }

        // WhisperKit's `Progress` callback reports a file count rather
        // than bytes (it's downloading several `.mlmodelc` files as a
        // unit), so the speed sampler would see 0→1→2→3 and compute
        // essentially 0 B/s. Pre-seed a canonical byte total from the
        // model catalog so the sampler can derive real bytes from the
        // fraction × total. Nil for unknown model IDs — the bridge still
        // works, just with no speed display.
        DownloadManager.shared.preSeedTotalBytes(
            backend: .whisper,
            modelIdentifier: trimmed,
            bytes: WhisperModelCatalog.estimatedBytes(for: trimmed)
        )

        // WhisperModelDownloadService.downloadModel is synchronous —
        // kicks off its own Task internally and flips state from there.
        whisper.downloadModel(trimmed)
        return outcomeForHistory
    }

    // MARK: - History reconciliation helpers

    /// When the backend says installed but the history doesn't, or the
    /// record is stuck in a non-completed state, promote the most recent
    /// record to `.completed` so the UI's "Installed" badge and the
    /// history row agree. No-op if no record exists.
    private static func promoteStaleRecordIfNeeded(
        backend: ModelBackendType,
        modelIdentifier: String
    ) {
        let store = DownloadHistoryStore.shared
        guard let record = store.fetchMostRecent(backend: backend, modelIdentifier: modelIdentifier),
              record.status != .completed else { return }
        _ = store.markCompleted(id: record.id, fileSizeBytes: record.fileSizeBytes)
    }

    /// Handles the "record says completed but disk says missing" case —
    /// deletes the stale record so the fresh pull starts cleanly without
    /// tripping the `alreadyInstalled` short-circuit on retry. Returns
    /// `.resumedFromHistory` if we pruned something, `.startedFresh` otherwise.
    private static func pruneStaleIfCompletedButMissing(
        backend: ModelBackendType,
        modelIdentifier: String,
        isPresentOnDisk: Bool
    ) -> DownloadStartOutcome {
        guard !isPresentOnDisk else { return .startedFresh }
        let store = DownloadHistoryStore.shared
        if let record = store.fetchMostRecent(backend: backend, modelIdentifier: modelIdentifier),
           record.status == .completed {
            _ = store.delete(id: record.id)
            return .resumedFromHistory
        }
        return .startedFresh
    }
}
