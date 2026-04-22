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

        // OllamaService.pullModel is async; fire-and-forget so callers get
        // the outcome synchronously. Progress flows via @Observable state.
        Task { await ollama.pullModel(name: trimmed, baseURL: ollama.ollamaBaseURL) }
        return outcomeForHistory
    }

    // MARK: - MLX

    @discardableResult
    static func startMLXDownloadIfNeeded(
        repoId: String,
        profileID: UUID? = nil
    ) async -> DownloadStartOutcome {
        let trimmed = repoId.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return .failed("Repo ID is empty") }

        let mlx = MLXModelService.shared
        // MLX store uses `displayName` as the canonical identifier (matches
        // the HF repo ID format after directory-name reconstruction). No
        // separate `repoId` field exists on the item.
        let isInstalled = mlx.installedModels.contains { $0.displayName == trimmed }

        if isInstalled {
            promoteStaleRecordIfNeeded(backend: .mlx, modelIdentifier: trimmed)
            return .alreadyInstalled
        }

        if let active = DownloadHistoryStore.shared.fetchMostRecent(
            backend: .mlx,
            modelIdentifier: trimmed
        ), active.isActive {
            return .alreadyInProgress(recordID: active.id)
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
        DownloadManager.shared.preSeedTotalBytes(
            backend: .mlx,
            modelIdentifier: trimmed,
            bytes: totalBytes
        )

        // MLX service's `downloadModel` is synchronous — it schedules the
        // actual pull on an internal Task and flips @Observable state from
        // there.
        mlx.downloadModel(repoId: trimmed)
        return outcomeForHistory
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
