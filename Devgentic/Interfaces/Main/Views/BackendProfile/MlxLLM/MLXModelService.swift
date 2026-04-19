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
        
        guard let url = URL(string: urlString) else { return }
        
        do {
            let (data, _) = try await URLSession.shared.data(from: url)
            let rawModels = try JSONDecoder().decode([HFRawModel].self, from: data)
            
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
                } else {
                    self.availableModels = displayModels
                }
                self.isLoadingRemoteModels = false
            }
            
            await fetchSizes(for: displayModels.map { $0.id })
            
        } catch {
            logger.error("Failed to fetch remote models: \(error.localizedDescription)")
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
        if tags.contains("reasoning") || tags.contains("chain-of-thought") || lowerId.contains("deepseek-r1") || lowerId.contains("reasoning") {
            caps.insert(.reasoning)
        }
        
        // 3. Tool Use / Function Calling
        if tags.contains("tool-use") || tags.contains("function-calling") || lowerId.contains("hermes") || lowerId.contains("tool") {
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
                let config = ModelConfiguration(id: repoId)
                
                _ = try await MLXLMCommon.downloadModel(
                    hub: hub,
                    configuration: config
                ) { progress in
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
    
    func cancelDownload() {
        guard let task = downloadTask else { return }
        logger.notice("Cancelling current download...")
        task.cancel()
        downloadTask = nil
        isDownloading = false
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
