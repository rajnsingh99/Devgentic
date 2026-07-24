//
//  MLXModelService.swift
//  Devgentic
//
//  Created by Raj Singh on 04/02/26.
//

import Foundation
import SwiftUI
import Hub          // From swift-transformers / mlx-swift-lm dependencies
import MLXLLM
import MLXLMCommon
import os

/// Manages the lifecycle of local MLX models and fetches remote metadata from Hugging Face.
@Observable @MainActor
class MLXModelService {
    static let shared = MLXModelService()

    @ObservationIgnored private let logger = DGLogger(category: "MLXModelService")

    // MARK: - Observable State

    /// Local models found on disk
    var installedModels: [MLXModelItem] = []

    /// Remote models fetched from the store (with rich metadata)
    var availableModels: [MLXDisplayModel] = []
    var isLoadingRemoteModels: Bool = false

    // Download State
    var downloadProgress: Double = 0.0
    var isDownloading: Bool = false
    var currentDownloadName: String = ""
    var errorMessage: String?

    // Task management for cancellation
    @ObservationIgnored private var downloadTask: Task<Void, Never>?

    // Cache for model sizes to avoid re-fetching
    var modelSizes: [String: String] = [:]

    // MARK: - Cognitive Profile Cache
    /// Caches CognitiveProfile results keyed by model display name.
    /// Invalidated automatically when the installed model list changes.
    /// Eliminates redundant file I/O from repeated detectCognitiveProfile calls.
    private var profileCache: [String: CognitiveProfile] = [:]

    /// Returns a cached CognitiveProfile for the given model, computing and caching it on first access.
    func cachedCognitiveProfile(for model: MLXModelItem) -> CognitiveProfile {
        if let cached = profileCache[model.displayName] {
            return cached
        }
        let profile = MLXTokenizerAnalyzer.detectCognitiveProfile(for: model.localPath, modelName: model.displayName)
        profileCache[model.displayName] = profile
        return profile
    }

    /// The model's trained context window (read from its `config.json` via the cached
    /// cognitive profile), looked up by display name. Nil when the model isn't installed
    /// or its config exposes no context length. Used to heal MLX profiles that were saved
    /// before the window was read into metadata (they'd otherwise show the 8K fallback).
    func trainedContextWindow(forModelName name: String) -> Int? {
        guard let item = installedModels.first(where: { $0.displayName == name }) else { return nil }
        return cachedCognitiveProfile(for: item).metadata?.contextWindow
    }

    /// Pre-computes and caches profiles for all installed models in one pass.
    /// Call after refreshInstalledModels() completes to warm the cache.
    private func rebuildProfileCache() {
        profileCache.removeAll(keepingCapacity: true)
        for model in installedModels {
            let profile = MLXTokenizerAnalyzer.detectCognitiveProfile(for: model.localPath, modelName: model.displayName)
            profileCache[model.displayName] = profile
        }
        logger.debug("Profile cache rebuilt for \(self.installedModels.count) model(s).")
    }

    // Debounce guard to prevent rapid-fire filesystem scans (e.g. init + onAppear)
    private var lastScanTime: Date? = nil
    private let scanDebounceInterval: TimeInterval = 30.0
    /// Snapshot of model count from last scan — used to skip no-op refreshes
    private var lastScanModelCount: Int = 0
    
    // MARK: - Configuration
    
    private var modelsDirectory: URL {
        let fileManager = FileManager.default
        let appSupport = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let mlxPath = appSupport.appendingPathComponent("huggingface/models")
        
        if !fileManager.fileExists(atPath: mlxPath.path) {
            try? fileManager.createDirectory(at: mlxPath, withIntermediateDirectories: true)
        }
        return mlxPath
    }
    
    private var hub: HubApi {
        return HubApi(downloadBase: modelsDirectory)
    }
    
    init() {
        // Force-refresh on first launch to populate both the model list and profile cache
        forceRefreshInstalledModels()
    }
    
    // MARK: - Local Discovery (Deep Scan)
    
    /// Forces a fresh filesystem scan, bypassing the debounce timer.
    /// Use after downloads or deletions where the model list is known to have changed.
    func forceRefreshInstalledModels() {
        lastScanTime = nil
        refreshInstalledModels()
    }

    func refreshInstalledModels() {
        // Debounce: skip if last scan was within the debounce interval (prevents init + onAppear double-fire)
        if let lastScan = lastScanTime, Date().timeIntervalSince(lastScan) < scanDebounceInterval {
            logger.debug("Skipping redundant Deep Scan — last scan was \(String(format: "%.1f", Date().timeIntervalSince(lastScan)))s ago.")
            return
        }
        lastScanTime = Date()

        logger.info("Starting Deep Scan (Config-based) at: \(self.modelsDirectory.path)")

        var foundModels: [MLXModelItem] = []
        let fileManager = FileManager.default
        let keys: [URLResourceKey] = [.isDirectoryKey, .nameKey, .creationDateKey]

        if let enumerator = fileManager.enumerator(
            at: modelsDirectory,
            includingPropertiesForKeys: keys,
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) {
            for case let fileURL as URL in enumerator {
                if fileURL.lastPathComponent == "config.json" {
                    let modelDir = fileURL.deletingLastPathComponent()
                    let parentDir = modelDir.deletingLastPathComponent()

                    // Completeness check: a folder with only `config.json` and no
                    // weights is a partial/aborted download (HubApi writes config
                    // early). Ignore those so they don't show up as "Installed".
                    let contents = (try? fileManager.contentsOfDirectory(
                        at: modelDir,
                        includingPropertiesForKeys: nil,
                        options: [.skipsHiddenFiles]
                    )) ?? []
                    let hasWeights = contents.contains { url in
                        let ext = url.pathExtension.lowercased()
                        return ext == "safetensors" || ext == "npz" || ext == "bin" || ext == "gguf"
                    }
                    guard hasWeights else {
                        logger.debug("Skipping incomplete download at \(modelDir.lastPathComponent) — no weights file present")
                        continue
                    }

                    var displayName = modelDir.lastPathComponent

                    // Reconstruct clean names from nested folders
                    if parentDir.lastPathComponent == "mlx-community" {
                        displayName = "\(parentDir.lastPathComponent)/\(modelDir.lastPathComponent)"
                    } else if modelDir.lastPathComponent.starts(with: "models--") {
                         displayName = modelDir.lastPathComponent
                            .replacingOccurrences(of: "models--", with: "")
                            .replacingOccurrences(of: "--", with: "/")
                    }

                    // Read creation date from the config.json file (reflects download time)
                    let createdAt = try? fileURL.resourceValues(forKeys: [.creationDateKey]).creationDate

                    // Deduplicate
                    if !foundModels.contains(where: { $0.displayName == displayName }) {
                        foundModels.append(MLXModelItem(id: displayName, displayName: displayName, localPath: modelDir, createdAt: createdAt))
                    }
                }
            }
        }

        let sorted = foundModels.sorted { $0.displayName < $1.displayName }

        // Only update and rebuild cache if the model list actually changed
        let newNames = Set(sorted.map(\.displayName))
        let oldNames = Set(installedModels.map(\.displayName))
        if newNames != oldNames {
            self.installedModels = sorted
            rebuildProfileCache()
            self.logger.info("Scan complete. Models changed — rebuilt cache. Models ready: \(self.installedModels.count)")
        } else {
            self.logger.info("Scan complete. Models unchanged (\(self.installedModels.count)). Cache retained.")
        }
        lastScanModelCount = sorted.count
    }
    
    // MARK: - Remote Discovery (Metadata & Store)
    
    /// Fetches remote models with support for pagination, search, and category filtering.
    func fetchRemoteModels(limit: Int = 30, offset: Int = 0, tags: [String]? = nil, search: String? = nil, append: Bool = false) async {
        
        await MainActor.run { self.isLoadingRemoteModels = true }
        
        // Construct URL
        var filters = ["mlx"]
        if let specificTags = tags {
            filters.append(contentsOf: specificTags)
        }
        let filterString = filters.joined(separator: ",")
        
        // Base URL
        var urlString = "https://huggingface.co/api/models?sort=downloads&direction=-1&limit=\(limit)&skip=\(offset)&filter=\(filterString)"
        
        // Append Search Query if provided
        if let search = search, !search.isEmpty {
            let encodedSearch = search.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? ""
            urlString += "&search=\(encodedSearch)"
        }
        
        guard let url = URL(string: urlString) else {
            logger.error("HF fetch: failed to construct URL from \(urlString)")
            await MainActor.run { self.isLoadingRemoteModels = false }
            return
        }

        logger.info("HF fetch → \(url.absoluteString) (append=\(append))")

        do {
            let (data, _) = try await URLSession.shared.data(from: url)
            let rawModels = try JSONDecoder().decode([HFRawModel].self, from: data)
            logger.info("HF fetch ← received \(rawModels.count) models")

            // Map raw JSON to our smart Domain Model
            let displayModels = rawModels.map { raw -> MLXDisplayModel in
                let caps = self.classifyCapabilities(tags: raw.tags ?? [], pipeline: raw.pipeline_tag, id: raw.id)
                return MLXDisplayModel(
                    id: raw.id,
                    size: nil,
                    capabilities: caps,
                    tags: raw.tags ?? [],
                    downloads: raw.downloads,
                    likes: raw.likes,
                    description: nil
                )
            }

            await MainActor.run {
                if append {
                    let newUnique = displayModels.filter { new in
                        !self.availableModels.contains(where: { $0.id == new.id })
                    }
                    self.availableModels.append(contentsOf: newUnique)
                    self.logger.info("HF fetch append: +\(newUnique.count) new (\(displayModels.count - newUnique.count) dupes) → total=\(self.availableModels.count)")
                    if newUnique.isEmpty && !displayModels.isEmpty {
                        self.logger.warning("HF pagination returned only duplicates at offset=\(offset) — likely end of result set")
                    } else if displayModels.isEmpty {
                        self.logger.warning("HF pagination returned 0 models at offset=\(offset) — end of result set")
                    }
                } else {
                    self.availableModels = displayModels
                    self.logger.info("HF fetch replace: total=\(self.availableModels.count)")
                }
                self.isLoadingRemoteModels = false
            }

            await fetchSizes(for: displayModels.map { $0.id })

        } catch {
            logger.error("HF fetch failed: \(error.localizedDescription) (url=\(url.absoluteString))")
            await MainActor.run { self.isLoadingRemoteModels = false }
        }
    }
    
    /// Heuristic logic to determine badges based on tags and naming conventions
    private func classifyCapabilities(tags: [String], pipeline: String?, id: String) -> Set<MLXModelCapability> {
        var caps: Set<MLXModelCapability> = []
        let lowerId = id.lowercased()
        
        // 1. Vision
        if pipeline == "image-text-to-text" || tags.contains("vision") || lowerId.contains("vision") || lowerId.contains("pixtral") || lowerId.contains("llava") || lowerId.contains("qwen2-vl") {
            caps.insert(.vision)
        }
        
        // 2. Reasoning (Chain of Thought)
        // Centralized reasoning-family detection via `ModelCapabilityHeuristics`
        // (catches deepseek-r1, qwq, magistral, gpt-oss, o1/o3/o4) plus the
        // generic Hugging Face tags and the "reasoning" keyword some publishers
        // add to their model id.
        if tags.contains("reasoning") || tags.contains("chain-of-thought") ||
           lowerId.contains("reasoning") ||
           ModelCapabilityHeuristics.isReasoningOnly(nameCandidates: id) {
            caps.insert(.reasoning)
        }
        
        // 3. Tool Use / Function Calling
        // Explicit HF tags take priority, then fall back to family-name heuristics
        // covering modern tool-capable families (Qwen2.5+, Llama-3.1+, Mistral Nemo/Small/
        // Large, Phi-3.5+, Command-R, Granite, Devstral, GLM-4, DeepSeek V2/V3, Kimi K2, etc.).
        // Reasoning-only distills are excluded by `isLikelyToolCapable`.
        if tags.contains("tool-use") || tags.contains("function-calling") ||
           ModelCapabilityHeuristics.isLikelyToolCapable(modelId: id) {
            caps.insert(.toolUse)
        }
        
        // 4. Coding
        if tags.contains("code") || lowerId.contains("coder") || lowerId.contains("codellama") || lowerId.contains("qwen2.5-coder") {
            caps.insert(.coding)
        }
        
        // Default to Chat
        if caps.isEmpty {
            caps.insert(.textGeneration)
        }
        
        return caps
    }
    
    private func fetchSizes(for repoIds: [String]) async {
        await withTaskGroup(of: (String, String?).self) { group in
            for id in repoIds {
                group.addTask {
                    return await self.getSizeForModel(repoId: id)
                }
            }
            
            for await (id, sizeString) in group {
                if let size = sizeString {
                    await MainActor.run {
                        self.modelSizes[id] = size
                        if let index = self.availableModels.firstIndex(where: { $0.id == id }) {
                            self.availableModels[index].size = size
                        }
                    }
                }
            }
        }
    }
    
    private func getSizeForModel(repoId: String) async -> (String, String?) {
        let urlString = "https://huggingface.co/api/models/\(repoId)?blobs=true"
        guard let url = URL(string: urlString) else { return (repoId, nil) }

        do {
            let (data, _) = try await URLSession.shared.data(from: url)
            let detail = try JSONDecoder().decode(HFModelDetail.self, from: data)
            let totalBytes = detail.siblings.compactMap { $0.size }.reduce(0, +)

            let formatter = ByteCountFormatter()
            formatter.allowedUnits = [.useGB, .useMB]
            formatter.countStyle = .file
            return (repoId, formatter.string(fromByteCount: Int64(totalBytes)))
        } catch {
            return (repoId, nil)
        }
    }

    /// Public counterpart to `getSizeForModel` that returns the raw byte
    /// total instead of a formatted string. Used by `DownloadCoordinator`
    /// to pre-seed `DownloadRecord.fileSizeBytes` before kicking off an
    /// MLX pull, so the speed/ETA display has an authoritative denominator
    /// from the first progress tick onward. Returns nil on any error
    /// (unknown repo, network issue, malformed response) — the download
    /// still proceeds, the UI just falls back to "— MB/s".
    func getTotalBytesForModel(repoId: String) async -> Int64? {
        let urlString = "https://huggingface.co/api/models/\(repoId)?blobs=true"
        guard let url = URL(string: urlString) else { return nil }
        do {
            let (data, _) = try await URLSession.shared.data(from: url)
            let detail = try JSONDecoder().decode(HFModelDetail.self, from: data)
            let totalBytes = detail.siblings.compactMap { $0.size }.reduce(0, +)
            return totalBytes > 0 ? Int64(totalBytes) : nil
        } catch {
            logger.warning("HF size fetch failed for \(repoId): \(error.localizedDescription)")
            return nil
        }
    }
    
    // MARK: - Download Logic
    
    func downloadModel(repoId: String) {
        cancelDownload()
        
        isDownloading = true
        currentDownloadName = repoId
        downloadProgress = 0.0
        errorMessage = nil
        
        logger.notice("Starting download task for: \(repoId)")
        
        downloadTask = Task {
            do {
                // mlx-swift-lm 3.x dropped `MLXLMCommon.downloadModel`. Download directly via
                // swift-transformers' `HubApi.snapshot` which gives us the same progress callback
                // and destination-directory contract. Empty `matching: []` downloads everything
                // in the repo (weights, tokenizer, config JSONs) — mirrors the old default.
                _ = try await hub.snapshot(from: repoId) { progress in
                    Task { @MainActor in
                        self.downloadProgress = progress.fractionCompleted
                    }
                }

                logger.notice("Download finished successfully.")
                self.forceRefreshInstalledModels()
                self.isDownloading = false
                
            } catch where error is CancellationError {
                logger.info("Download cancelled by user.")
                self.isDownloading = false
                self.downloadProgress = 0.0
                self.currentDownloadName = ""
                
            } catch {
                logger.fault("Download error: \(error.localizedDescription)")
                self.errorMessage = "Download failed: \(error.localizedDescription)"
                self.isDownloading = false
            }
        }
    }
    
    /// True while a cancelled download's partial files are being removed from disk.
    /// UI observes this to show a "Cleaning up…" indicator, since the scanner
    /// would otherwise misidentify the orphaned `config.json` as "Installed".
    var isCancellingDownload: Bool = false

    /// Resolve the on-disk folder that HubApi writes into for a given repo id.
    /// Layout: `<modelsDirectory>/<author>/<name>/` (e.g. `mlx-community/Qwen2.5-3B…`).
    /// Returns nil for malformed repo ids.
    private func partialDownloadFolder(for repoId: String) -> URL? {
        let components = repoId.components(separatedBy: "/")
        guard components.count == 2,
              !components[0].isEmpty,
              !components[1].isEmpty else { return nil }
        return modelsDirectory
            .appendingPathComponent(components[0])
            .appendingPathComponent(components[1])
    }

    /// Remove a partial-download folder from disk so the scanner doesn't
    /// misidentify it as installed. No-op if the folder doesn't exist.
    /// Idempotent — safe to call before starting a fresh download too.
    func removePartialDownload(repoId: String) {
        guard let folder = partialDownloadFolder(for: repoId) else { return }
        let fm = FileManager.default
        guard fm.fileExists(atPath: folder.path) else { return }
        do {
            try fm.removeItem(at: folder)
            logger.notice("🗑️ Removed partial download folder: \(folder.lastPathComponent)")
        } catch {
            logger.error("Failed to remove partial download \(folder.path): \(error.localizedDescription)")
        }
    }

    func cancelDownload() {
        guard let task = downloadTask else { return }
        let modelName = currentDownloadName

        logger.notice("Cancelling download: \(modelName)")
        task.cancel()
        downloadTask = nil
        isCancellingDownload = true

        // Wait for the in-flight task to observe cancellation (so it stops
        // writing new files), then delete the partial folder on disk. If we
        // skipped this step, HubApi's `config.json` would remain and the
        // filesystem scan would misidentify the canceled model as installed.
        Task { [weak self] in
            _ = await task.value
            await MainActor.run {
                guard let self else { return }

                // Corner case: user restarted the download for the SAME repo
                // while we were awaiting cleanup. Don't delete the folder the
                // new task is writing to, and don't stomp its state flags.
                let newTaskForSameRepo = self.downloadTask != nil && self.currentDownloadName == modelName

                if !modelName.isEmpty && !newTaskForSameRepo {
                    self.removePartialDownload(repoId: modelName)
                }

                if self.downloadTask == nil {
                    self.isDownloading = false
                    self.downloadProgress = 0.0
                    self.currentDownloadName = ""
                    self.errorMessage = nil
                    self.forceRefreshInstalledModels()
                }
                self.isCancellingDownload = false
            }
        }
    }
    
    func deleteModel(_ item: MLXModelItem) {
        do {
            try FileManager.default.removeItem(at: item.localPath)
            forceRefreshInstalledModels()
        } catch {
            self.errorMessage = "Failed to delete: \(error.localizedDescription)"
        }
    }
}

// MARK: - Internal Helper Structs for API

struct HFRawModel: Decodable {
    let id: String
    let downloads: Int
    let likes: Int
    let tags: [String]?
    let pipeline_tag: String?
}

struct HFModelDetail: Decodable {
    struct Sibling: Decodable { let size: Int? }
    let siblings: [Sibling]
}
