// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
//
//  DownloadCoordinator.swift
//  Devgentic
//
//  Created by Raj Singh.
//

import Foundation

private let logger = DGLogger(category: "DownloadCoordinator")

/// Holds an `NSProcessInfo` activity for the lifetime of a download so the system does not idle-sleep mid-transfer.
/// Only idle system sleep is suppressed: the display still dims and the machine still sleeps when the lid closes.
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
            // Make sure history reflects reality: if the user failed or cancelled this model earlier, mark it completed so
            // "Installed" badges match server state.
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

        // `pullModel` refuses silently while another pull is in flight and its result is never inspected, so check the
        // service's actual state here (the in-flight check above is scoped to the same identifier).
        if ollama.isRemovingModel {
            return .failed("Can't start a download while another model is being removed.")
        }
        // The slot is claimed here, before the support lookup's await: checking `isPullingModel` and claiming later lets two
        // quick clicks both start a pull.
        guard let reservation = ollama.reservePull() else {
            return .failed(ollama.isPullingModel
                ? "\(ollama.modelToPull) is still downloading — Ollama pulls one model at a time."
                : "Another Ollama download is starting — Ollama pulls one model at a time.")
        }

        // Authoritative "can we run this" check, only possible for `hf.co/<owner>/<repo>` names (the one form with
        // pre-download metadata). A failed lookup proceeds, so an offline blip never refuses a valid pull.
        if let repoId = ModelSupportPolicy.huggingFaceRepoId(fromOllamaName: trimmed),
           let reason = await MLXModelService.shared.unsupportedReason(forRepo: repoId) {
            ollama.releasePullReservation(reservation)
            return .failed("Not supported. \(reason)")
        }

        // OllamaService.pullModel is async; fire-and-forget so callers get
        // the outcome synchronously. Progress flows via @Observable state.
        Task { await ollama.pullModel(name: trimmed, baseURL: ollama.ollamaBaseURL, reservation: reservation) }
        return outcomeForHistory
    }

    // MARK: - MLX

    /// - Parameter force: skip the "already installed" short-circuit and re-pull.
    /// A forced pull is a genuine repair: `HubFileDownloader` verifies etag/SHA-256 per file and re-fetches only mismatches.
    @discardableResult
    static func startMLXDownloadIfNeeded(
        repoId: String,
        profileID: UUID? = nil,
        force: Bool = false
    ) async -> DownloadStartOutcome {
        let trimmed = repoId.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return .failed("Repo ID is empty") }

        let mlx = MLXModelService.shared
        // Wait for the scan before the install check: it runs off-actor, so an early call could see an empty list and
        // re-pull a model the user already has.
        await mlx.ensureLoaded()
        // Identity goes through `MLXModelIdentity` so models from publishers other than `mlx-community`, and profiles that
        // stored a bare author-less name, still resolve.
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

        // MLX has a single download slot and `MLXModelService.downloadModel` refuses rather than pre-empting an in-flight
        // pull; detect that here so the caller can show a `.failed` toast explaining why nothing happened.
        if mlx.isDownloading, !mlx.currentDownloadName.isEmpty, mlx.currentDownloadName != trimmed {
            return .failed("\(mlx.currentDownloadName) is still downloading — cancel it before starting another.")
        }

        let outcomeForHistory = pruneStaleIfCompletedButMissing(
            backend: .mlx,
            modelIdentifier: trimmed,
            isPresentOnDisk: false
        )

        // Pre-fetch total bytes from HuggingFace so the speed/ETA display has an authoritative denominator from the first
        // progress tick; nil on failure.
        let totalBytes = await mlx.getTotalBytesForModel(repoId: trimmed)

        // Disk preflight on what will actually be fetched (total minus bytes already on disk), so a forced repair of a
        // present-but-corrupt model stays reachable. Unknown free space proceeds rather than blocks.
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

        // MLX service's `downloadModel` is synchronous: it schedules the pull on an internal Task and returns false if it
        // refused the request (a pull started between our check above and this call).
        guard mlx.downloadModel(repoId: trimmed) else {
            return .failed("Couldn't start the download — another model is already downloading.")
        }
        return outcomeForHistory
    }

    /// Resumes a paused or interrupted MLX download from the bytes already on disk. Separate from
    /// `startMLXDownloadIfNeeded`: a resume continues work already paid for, so it skips the install short-circuit and
    /// only needs the remaining bytes to fit.
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

        // WhisperKit's `Progress` reports a file count, not bytes, so the speed sampler would compute ~0 B/s; pre-seed a
        // byte total from the model catalog (nil for unknown model IDs: no speed display).
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

    /// When the backend says installed but the history doesn't, or the record is stuck in a non-completed state, promotes
    /// the most recent record to `.completed` so the "Installed" badge and history agree. No-op if no record exists.
    private static func promoteStaleRecordIfNeeded(
        backend: ModelBackendType,
        modelIdentifier: String
    ) {
        let store = DownloadHistoryStore.shared
        guard let record = store.fetchMostRecent(backend: backend, modelIdentifier: modelIdentifier),
              record.status != .completed else { return }
        _ = store.markCompleted(id: record.id, fileSizeBytes: record.fileSizeBytes)
    }

    /// Handles "record says completed but disk says missing": deletes the stale record so the fresh pull starts cleanly
    /// without tripping the `alreadyInstalled` short-circuit. Returns `.resumedFromHistory` if it pruned something,
    /// `.startedFresh` otherwise.
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
