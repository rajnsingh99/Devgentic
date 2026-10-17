// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
//
//  WhisperModelDownloadService.swift
//  Devgentic
//
//  Manages Whisper model download state: cache detection, download with
//  progress tracking, deletion, and cancellation. Owns the download/delete
//  lifecycle so that WhisperRecognitionService only deals with loading
//  cached models.
//

import Foundation
import WhisperKit
import Hub
import os

@MainActor
@Observable
final class WhisperModelDownloadService {

    static let shared = WhisperModelDownloadService()

    // MARK: - Published State

    /// IDs of models whose files are present in the local HuggingFace cache.
    private(set) var downloadedModelIds: Set<String> = []

    /// Whether a download is currently in progress.
    private(set) var isDownloading = false

    /// How the most recent download ended (DownloadManager's history classification reads it).
    /// Cleared when a download starts; set on every terminal path before `isDownloading` flips.
    private(set) var lastDownloadEnding: RecordedDownloadEnding?

    /// 0.0 … 1.0 fraction of the current download.
    private(set) var downloadProgress: Double = 0

    /// The model ID currently being downloaded (e.g. "medium.en").
    private(set) var downloadingModelId: String?

    /// Non-nil when the most recent download failed. Cleared on next download start.
    private(set) var downloadError: String?

    /// Bytes downloaded so far for the current pull, mirrored from the
    /// `Progress` object WhisperKit hands the progress callback. Nil when
    /// Progress hasn't emitted a usable value yet (e.g. during the initial
    /// handshake where `totalUnitCount` is -1).
    private(set) var downloadCompletedBytes: Int64?

    /// Total bytes the Progress object reports for the current pull. Nil
    /// until Progress settles on a real total (can happen a second or two
    /// after the download starts).
    private(set) var downloadTotalBytes: Int64?

    /// Non-nil when the most recent delete failed. Cleared on next delete.
    private(set) var deleteError: String?

    /// True while a delete operation is in progress — blocks concurrent downloads.
    private(set) var isDeleting = false

    // MARK: - Private

    private let repo = "argmaxinc/whisperkit-coreml"

    /// Where WhisperKit models are stored: Application Support, beside the MLX model store.
    ///
    /// ⚠️⚠️ EVERY `HubApi` / `WhisperKit` CALL MUST PASS THIS. Their default is
    /// `~/Documents/huggingface`, and merely checking that path raises the macOS "access your
    /// Documents folder" prompt. This service is built with the composer at launch, so the default
    /// put that prompt on every first launch, before the user had touched voice input.
    nonisolated static let downloadBase = URL.applicationSupportDirectory
        .appending(path: "huggingface/whisperkit", directoryHint: .isDirectory)

    private var downloadTask: Task<Void, Never>?

    /// Minimum number of `.mlmodelc`/`.mlpackage` files required for a model
    /// to be considered fully downloaded (MelSpectrogram + AudioEncoder + TextDecoder).
    private let minimumModelFileCount = 3

    private let logger = DGLogger(category: "WhisperModelDownloadService")

    // MARK: - Init

    private init() {
        refreshDownloadedModels()
    }

    // MARK: - Cache Detection

    /// Scans the HuggingFace Hub local cache for already-downloaded WhisperKit model variants.
    func refreshDownloadedModels() {
        let hubApi = HubApi(downloadBase: Self.downloadBase)
        let repoObj = Hub.Repo(id: repo, type: .models)
        let repoDir = hubApi.localRepoLocation(repoObj)

        guard FileManager.default.fileExists(atPath: repoDir.path) else {
            downloadedModelIds = []
            return
        }

        var found: Set<String> = []
        let fm = FileManager.default

        guard let contents = try? fm.contentsOfDirectory(
            at: repoDir,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else {
            downloadedModelIds = []
            return
        }

        // Model variant folders follow the pattern: openai_whisper-<variant>/
        // e.g. openai_whisper-base, openai_whisper-large-v3
        // NOTE: WhisperKit uses the SAME folder for both "base" and "base.en" —
        // the ".en" suffix is a runtime decoding option, not a separate download.
        for url in contents {
            guard (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true else { continue }
            let folderName = url.lastPathComponent

            for model in WhisperModelCatalog.availableModels {
                // Strip ".en" suffix for matching: "base.en" → "base", "medium.en" → "medium"
                // because WhisperKit stores both variants in the same folder (e.g. openai_whisper-base).
                let baseName = model.id.hasSuffix(".en")
                    ? String(model.id.dropLast(3))
                    : model.id

                // Anchored suffix match: folder must end with "-<baseName>"
                guard folderName.hasSuffix("-\(baseName)") || folderName == baseName else { continue }

                // Fix #7: Verify the folder has enough model files to be usable
                // (not a partial download). WhisperKit needs at minimum:
                // MelSpectrogram, AudioEncoder, TextDecoder — each as .mlmodelc/.mlpackage.
                if let files = try? fm.contentsOfDirectory(atPath: url.path) {
                    let modelFiles = files.filter { $0.hasSuffix(".mlmodelc") || $0.hasSuffix(".mlpackage") }
                    if modelFiles.count >= minimumModelFileCount {
                        found.insert(model.id)
                    }
                }
            }
        }

        downloadedModelIds = found
        logger.log("Downloaded models: \(found.sorted().joined(separator: ", "))")
    }

    /// Returns whether a given model ID is already cached locally.
    func isModelDownloaded(_ modelId: String) -> Bool {
        downloadedModelIds.contains(modelId)
    }

    // MARK: - Download

    /// Downloads a model variant with progress tracking.
    /// On success, refreshes the cache set and posts `speechModelChangedNotification`.
    func downloadModel(_ modelId: String) {
        guard !isDownloading else {
            logger.warning("Download already in progress for '\(self.downloadingModelId ?? "?")'")
            return
        }
        guard !isDeleting else {
            logger.warning("Cannot start download — a delete operation is in progress.")
            return
        }

        isDownloading = true
        downloadProgress = 0
        downloadingModelId = modelId
        downloadError = nil
        lastDownloadEnding = nil
        downloadCompletedBytes = nil
        downloadTotalBytes = nil

        downloadTask = Task { [weak self] in
            guard let self else { return }
            do {
                logger.log("Starting download for model '\(modelId)'")

                let _ = try await WhisperKit.download(
                    variant: modelId,
                    downloadBase: Self.downloadBase,
                    from: self.repo
                ) { [weak self] progress in
                    Task { @MainActor [weak self] in
                        guard let self, self.isDownloading else { return }
                        let fraction = progress.totalUnitCount > 0
                            ? Double(progress.completedUnitCount) / Double(progress.totalUnitCount)
                            : 0
                        self.downloadProgress = fraction
                        // Expose raw byte counts for DownloadManager's
                        // speed sampler. Progress can emit -1 for total
                        // during handshake; filter that.
                        self.downloadCompletedBytes = progress.completedUnitCount >= 0
                            ? progress.completedUnitCount
                            : nil
                        self.downloadTotalBytes = progress.totalUnitCount > 0
                            ? progress.totalUnitCount
                            : nil
                    }
                }

                guard !Task.isCancelled else {
                    self.lastDownloadEnding = RecordedDownloadEnding(modelID: modelId, ending: .cancelled)
                    self.resetDownloadState()
                    return
                }

                logger.log("Download completed for '\(modelId)'")

                // Refresh cache FIRST so isModelDownloaded() returns true
                // before the notification triggers switchModel().
                // refreshDownloadedModels() is synchronous (FileManager calls on MainActor),
                // so downloadedModelIds is fully updated before we proceed.
                self.refreshDownloadedModels()
                self.lastDownloadEnding = RecordedDownloadEnding(modelID: modelId, ending: .succeeded)
                self.resetDownloadState()

                // Persist the selection and notify the recognition service to load
                UserDefaults.standard.set(modelId, forKey: AppSettings.speechModelKey)
                NotificationCenter.default.post(
                    name: GlobalConstants.speechModelChangedNotification,
                    object: modelId
                )
            } catch {
                guard !Task.isCancelled else {
                    self.lastDownloadEnding = RecordedDownloadEnding(modelID: modelId, ending: .cancelled)
                    self.resetDownloadState()
                    return
                }
                logger.error("Download failed for '\(modelId)': \(error.localizedDescription)")
                self.lastDownloadEnding = RecordedDownloadEnding(modelID: modelId, ending: .failed)
                self.downloadError = error.localizedDescription
                self.isDownloading = false
                self.downloadingModelId = nil
            }
        }
    }

    /// Cancels the active download and waits for the task to finish tearing down.
    func cancelDownload() async {
        guard let task = downloadTask else { return }
        logger.log("Cancelling download for '\(self.downloadingModelId ?? "?")'")
        task.cancel()
        // Wait for the task to observe cancellation and clean up,
        // so callers (e.g. deleteModel) don't race against a half-written download.
        await task.value
        downloadTask = nil
        if let id = downloadingModelId, lastDownloadEnding?.modelID != id {
            lastDownloadEnding = RecordedDownloadEnding(modelID: id, ending: .cancelled)
        }
        resetDownloadState()
    }

    private func resetDownloadState() {
        isDownloading = false
        downloadProgress = 0
        downloadingModelId = nil
        downloadError = nil
        downloadCompletedBytes = nil
        downloadTotalBytes = nil
    }

    // MARK: - Delete

    /// Deletes a downloaded model from the local HuggingFace cache.
    ///
    /// - Cancels any active download of this model first (awaiting completion).
    /// - Tells `WhisperRecognitionService` to unload the model if it's currently loaded,
    ///   preventing stale in-memory references to deleted CoreML bundles.
    /// - Returns the ID of a remaining downloaded model to switch to, or nil if none remain.
    ///   Returns nil and sets `deleteError` if the filesystem operation fails.
    @discardableResult
    func deleteModel(_ modelId: String) async -> String? {
        // If we're currently downloading this model, cancel and wait for teardown
        if isDownloading && downloadingModelId == modelId {
            await cancelDownload()
        }
        guard !isDownloading else {
            logger.warning("Cannot delete — a download is in progress for '\(self.downloadingModelId ?? "?")'.")
            return nil
        }

        isDeleting = true
        deleteError = nil
        defer { isDeleting = false }

        // Unload the model from WhisperRecognitionService if it's the one in memory,
        // so we don't hold stale references to deleted CoreML bundles.
        let recognitionService = WhisperRecognitionService.shared
        if recognitionService.loadingState == .loaded {
            await recognitionService.unloadCurrentModel()
        }

        let hubApi = HubApi(downloadBase: Self.downloadBase)
        let repoObj = Hub.Repo(id: repo, type: .models)
        let repoDir = hubApi.localRepoLocation(repoObj)
        let fm = FileManager.default

        guard let contents = try? fm.contentsOfDirectory(
            at: repoDir,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else {
            deleteError = "Unable to read model cache directory."
            refreshDownloadedModels()
            return downloadedModelIds.first
        }

        var didDelete = false
        let baseName = modelId.hasSuffix(".en") ? String(modelId.dropLast(3)) : modelId
        for url in contents {
            guard (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true else { continue }
            let folderName = url.lastPathComponent
            guard folderName.hasSuffix("-\(baseName)") || folderName == baseName else { continue }

            do {
                try fm.removeItem(at: url)
                logger.log("Deleted model folder: \(folderName)")
                didDelete = true
            } catch {
                let msg = "Failed to delete '\(folderName)': \(error.localizedDescription)"
                logger.error("\(msg)")
                deleteError = msg
            }
        }

        if !didDelete && deleteError == nil {
            deleteError = "No matching model folder found for '\(modelId)'."
        }

        refreshDownloadedModels()

        // Return a fallback model to switch to (prefer base.en, then any remaining)
        if let fallback = downloadedModelIds.first(where: { $0 == "base.en" }) {
            return fallback
        }
        return downloadedModelIds.first
    }
}
