// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
//
//  MLXModelService.swift
//  Devgentic
//
//  Created by Raj Singh.
//

import Foundation
import SwiftUI
import AppKit
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

    /// Which store category `availableModels` was actually fetched for; callers compare it before rendering.
    /// A failed fetch leaves the previous category's payload in place, which must not be re-filtered for the new category.
    var availableModelsCategory: String?

    // Why: The category alone is not the payload's identity: two cached store view models share this array with different sorts.
    // Record every field the query varied by, or 'is this payload mine?' cannot be answered.
    /// The server ranking and search term that produced `availableModels`, alongside the category.
    var availableModelsSort: String?
    var availableModelsSearch: String?

    /// Why the last remote fetch failed, or nil if it succeeded.
    /// Rendered instead of the generic empty state so rate-limited, offline, gated and empty results look different.
    var remoteLoadError: HFRequestError?

    /// Monotonic token identifying the newest fetch. Responses from older generations are
    /// discarded rather than allowed to overwrite newer results.
    @ObservationIgnored private var requestGeneration: UInt64 = 0
    /// How many fetches are outstanding, so a single completion can't clear the spinner
    /// while another is still running.
    @ObservationIgnored private var inFlightFetches: Int = 0

    /// Max simultaneous HuggingFace size requests.
    /// `?blobs=true` enumerates every file in a repo; an unbounded fan-out per page draws a 429 from the anonymous rate
    /// limit.
    @ObservationIgnored private static let maxConcurrentSizeFetches = 5

    // Download State
    var downloadProgress: Double = 0.0
    var isDownloading: Bool = false
    var currentDownloadName: String = ""
    var errorMessage: String?

    // The in-flight download task, kept for cancellation.
    // Internal rather than private so tests can install an in-flight download and exercise the pause and late-unwind paths.
    @ObservationIgnored var downloadTask: Task<Void, Never>?

    // Why: A cancelled task's terminal handlers run after the slot may have changed hands; Pause then Resume reuses the repo id.
    // Without the token a late unwind clears the new download's handles.
    /// Monotonic token identifying the current occupant of the single download slot.
    /// Bumped by whoever takes the slot (`downloadModel`) or releases it (`pauseDownload`); `cancelDownload` does not bump.
    @ObservationIgnored var downloadGeneration: UInt64 = 0

    // Cache of model sizes by repo id, read on every remote map to avoid re-fetching.
    var modelSizes: [String: String] = [:]
    /// Raw byte totals, keyed the same way. Sorting and fit assessment use these.
    var modelSizeBytes: [String: Int64] = [:]

    /// On-disk size of each installed model, keyed by canonical repo id.
    /// Computed off the MainActor after each scan and published when it lands; empty until the first sizing pass completes.
    var installedSizeBytes: [String: Int64] = [:]

    /// Total bytes occupied by installed models. Nil until the first sizing pass completes.
    var totalInstalledBytes: Int64? {
        installedSizeBytes.isEmpty ? nil : installedSizeBytes.values.reduce(0, +)
    }

    @ObservationIgnored private var sizingTask: Task<Void, Never>?
    /// In-flight disk scan, so concurrent callers coalesce onto one walk instead of racing.
    @ObservationIgnored private var scanTask: Task<Void, Never>?
    /// Whether at least one scan has published. `ensureLoaded()` keys on this rather than on
    /// the list being non-empty, so an empty library doesn't re-walk on every request.
    @ObservationIgnored private var hasCompletedInitialScan = false

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

    /// The model's trained context window (from `config.json` via the cached cognitive profile), looked up by display name.
    /// Nil when the model is not installed or its config exposes no context length.
    func trainedContextWindow(forModelName name: String) -> Int? {
        guard let item = installedModel(named: name) else { return nil }
        return cachedCognitiveProfile(for: item).metadata?.contextWindow
    }

    /// The single lookup that turns a stored model name into an installed model.
    /// Goes through `MLXModelIdentity`, so a bare author-less name still resolves and an ambiguous fallback is logged.
    func installedModel(named name: String) -> MLXModelItem? {
        if let exact = installedModels.first(where: {
            MLXModelIdentity.match(installed: $0.displayName, candidate: name) == .exact
        }) {
            return exact
        }
        return installedModels.first(where: {
            MLXModelIdentity.matches(installed: $0.displayName, candidate: name)
        })
    }

    /// Whether `repoId` is installed on disk right now.
    func isInstalled(repoId: String) -> Bool {
        installedModel(named: repoId) != nil
    }


    // Debounce guard against rapid-fire filesystem scans (e.g. init plus onAppear).
    // The 2 s window only needs to absorb that double-fire; a long window would make explicit refreshes no-ops.
    private var lastScanTime: Date? = nil
    private let scanDebounceInterval: TimeInterval = 2.0
    /// Exposed so a test can assert the window stays short enough not to swallow a user's
    /// explicit Refresh — the failure this constant caused was invisible, not a crash.
    var scanDebounceIntervalForTesting: TimeInterval { scanDebounceInterval }
    /// Model count from the last scan, to skip no-op refreshes.
    private var lastScanModelCount: Int = 0
    /// Number of disk walks STARTED, ever. Two uses: the field log can tell a coalesced join
    /// from a real walk, and a test can assert that a forcing caller actually caused a new one
    /// rather than being satisfied by a walk that predates its mutation.
    @ObservationIgnored private(set) var scanCount: Int = 0
    
    // MARK: - Configuration
    
    /// Overrides the download root. Non-nil only in tests, so the partial-cleanup and
    /// folder-derivation paths can be exercised against a temp directory instead of the
    /// user's real Application Support tree (where a mistake deletes multi-GB models).
    @ObservationIgnored private let modelsRootOverride: URL?

    var modelsDirectory: URL {
        let fileManager = FileManager.default
        // Test override, then the user's custom location, then the default.
        // `MLXModelsLocation` logs each fallback: a wrong directory here re-downloads gigabytes.
        let mlxPath = modelsRootOverride
            ?? MLXModelsLocation.effectiveDirectory()
            // Last resort; `MLXModelsLocation` has already logged why both other paths failed. Avoids a force-unwrap trap.
            ?? fileManager.temporaryDirectory.appendingPathComponent("devgentic-models")

        if !fileManager.fileExists(atPath: mlxPath.path) {
            do {
                try fileManager.createDirectory(at: mlxPath, withIntermediateDirectories: true)
            } catch {
                logger.error("[MLXSTORE] Could not create the models directory at \(mlxPath.path): \(error.localizedDescription). CONSEQUENCE: downloads will fail and the installed scan will find nothing until this is resolved.")
            }
        }
        return mlxPath
    }

    /// Switches the models directory and rescans. Existing models are NOT moved — they stay
    /// where they are and simply stop being listed, which the settings UI states plainly.
    func setModelsDirectory(_ url: URL) async -> Bool {
        guard MLXModelsLocation.setCustomDirectory(url) else { return false }
        await forceRefreshInstalledModelsAsync()
        return true
    }

    func resetModelsDirectory() async {
        MLXModelsLocation.clearCustomDirectory()
        await forceRefreshInstalledModelsAsync()
    }

    // Why: An instance with a `modelsRootOverride` (a test) gets `{ nil }` instead of the Keychain reader.
    // Reading the real login keychain can raise a modal prompt that a headless test run cannot dismiss.
    /// Supplies the HuggingFace token for `hub`.
    @ObservationIgnored private let hfTokenProvider: () -> String?

    var hub: HubApi {
        // Pass the token explicitly: `HubApi`'s own fallback reads `HF_TOKEN` from the process environment,
        // which a .app launched from Finder, Spotlight or Sparkle does not inherit.
        HubApi(downloadBase: modelsDirectory, hfToken: hfTokenProvider())
    }

    init(modelsRootOverride: URL? = nil) {
        self.modelsRootOverride = modelsRootOverride
        self.hfTokenProvider = modelsRootOverride == nil
            ? { HuggingFaceTokenStore.shared.token }
            : { nil }
        // Why: The walk starts here synchronously, not from a deferred Task, so `scanTask` is set before init returns
        // and every early caller joins this one walk instead of starting another.
        // Starts the first scan without blocking init; `installedModels` is empty until it lands, and `ensureLoaded()` waits
        // for it.
        let initial = beginWalk()
        Task { [weak self] in
            await initial.value
            guard let self, self.scanTask == initial else { return }
            self.scanTask = nil
        }
    }
    
    // MARK: - Local Discovery (Deep Scan)
    
    /// Forces a fresh filesystem scan, bypassing the debounce timer.
    /// Use after downloads or deletions where the model list is known to have changed.
    func forceRefreshInstalledModels() {
        lastScanTime = nil
        Task { await refreshInstalledModelsAsync(force: true) }
    }

    /// Awaitable force-refresh. Callers that must see the new state before continuing — a
    /// completed download deciding its terminal status, a delete updating the list — use this
    /// rather than the fire-and-forget variant.
    func forceRefreshInstalledModelsAsync() async {
        lastScanTime = nil
        await refreshInstalledModelsAsync(force: true)
    }

func refreshInstalledModels() {
        // Fire-and-forget launcher: the scan is off-actor and `installedModels` is published when it lands.
        // Callers that need the result must `await ensureLoaded()`.
        Task { await refreshInstalledModelsAsync() }
    }

    /// Scans disk and publishes the result.
    /// The walk and per-model profile parsing run off the MainActor; only the final publish is main-actor work.
    func refreshInstalledModelsAsync(force: Bool = false) async {
        // Coalesce before the debounce: several surfaces can ask at once, and joining an in-flight walk is the only correct
        // answer for a caller that needs the result; a debounced caller would see an empty list as 'no models installed'.
        if let inflight = scanTask {
            await inflight.value
            // A forcing caller must see a walk that started after its mutation, so it does not return after joining:
            // the walk it joined may have read the disk before the change.
            if !force { return }

            // Unless another forcing caller already started a walk after our mutation; joining it avoids a third pass.
            // `Task` conforms to `Hashable` on the underlying task identity, so `!=` is an identity comparison.
            if let newer = scanTask, newer != inflight {
                await newer.value
                return
            }
        }

        if !force, let lastScan = lastScanTime, Date().timeIntervalSince(lastScan) < scanDebounceInterval {
            logger.info("[MLXSTORE] Skipping redundant model scan — the last one was \(String(format: "%.1f", Date().timeIntervalSince(lastScan)))s ago (debounce \(String(format: "%.0f", self.scanDebounceInterval))s). CONSEQUENCE: the installed list is unchanged; pass force:true when the caller knows disk changed.")
            return
        }

        let task = beginWalk()
        await task.value
        // Clear only our own handle: a forcing caller that joined this walk may have installed its own task here.
        if scanTask == task { scanTask = nil }
    }

    /// Starts a disk walk and installs it as `scanTask`, synchronously, so any caller arriving
    /// after this returns joins it. The caller owns clearing `scanTask` once it lands.
    private func beginWalk() -> Task<Void, Never> {
        lastScanTime = Date()
        scanCount += 1
        let scanRoot = modelsDirectory

        let task = Task { [weak self] in
            let scanned = await Task.detached(priority: .userInitiated) {
                let models = MLXModelService.scanDisk(root: scanRoot)
                return (models, MLXModelService.computeProfiles(for: models))
            }.value
            guard let self, !Task.isCancelled else { return }
            self.publish(models: scanned.0, profiles: scanned.1)
        }
        scanTask = task
        return task
    }

    /// Awaits at least one completed scan. Request-path consumers use this instead of reading
    /// `installedModels` straight after a fire-and-forget refresh — the list is empty until
    /// the first walk lands, and an empty list is indistinguishable from "nothing installed".
    func ensureLoaded() async {
        // Keyed on "a scan has completed", NOT on the list being non-empty: a genuinely empty
        // library would otherwise force a fresh walk on every call.
        if hasCompletedInitialScan { return }
        if let inflight = scanTask {
            await inflight.value
            return
        }
        // Force: reaching here means nothing has landed yet, so the debounce must not apply.
        await refreshInstalledModelsAsync(force: true)
    }

    /// Main-actor publish step — the only part that must run here.
    private func publish(models: [MLXModelItem], profiles: [String: CognitiveProfile]) {
        hasCompletedInitialScan = true
        // Compare the items, not the name set: `MLXModelItem` carries mutable state (`revision`, `localPath`, `createdAt`)
        // that a name diff misses; a re-download changes the commit but not the names.
        if models != installedModels {
            self.installedModels = models
            self.profileCache = profiles
            recomputeInstalledSizes()
            logger.info("Scan complete. Models changed — rebuilt cache. Models ready: \(models.count)")
        } else {
            // Identical items, so only the parsed profiles can differ (a config edited in
            // place under an unchanged path and revision).
            self.profileCache = profiles
            logger.info("Scan complete. Models unchanged (\(models.count)). Cache refreshed.")
        }
        lastScanModelCount = models.count
    }

    // MARK: - Off-actor scan

    /// Pure filesystem walk. `nonisolated` so it can run on a background executor.
    nonisolated static func scanDisk(root: URL) -> [MLXModelItem] {
        let logger = DGLogger(category: "MLXModelService")
        logger.info("Starting Deep Scan (Config-based) at: \(root.path)")

        var foundModels: [MLXModelItem] = []
        let fileManager = FileManager.default
        let keys: [URLResourceKey] = [.isDirectoryKey, .nameKey, .creationDateKey]

        guard let enumerator = fileManager.enumerator(
            at: root,
            includingPropertiesForKeys: keys,
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) else { return [] }

        for case let fileURL as URL in enumerator {
            guard fileURL.lastPathComponent == "config.json" else { continue }
            let modelDir = fileURL.deletingLastPathComponent()

            // Completeness check: a folder with only `config.json` and no weights is a
            // partial/aborted download (HubApi writes config early).
            guard containsWeights(at: modelDir) else {
                logger.debug("Skipping incomplete download at \(modelDir.lastPathComponent) — no weights file present")
                continue
            }

            // Sharded repos need every shard, not just one.
            let shards = shardCompleteness(at: modelDir)
            guard shards.isComplete else {
                logger.error("[MLXSTORE] Skipping TRUNCATED model at \(modelDir.path) — \(shards.present) of \(shards.expected) shards present. CONSEQUENCE: it is hidden from the installed list (it would fail at load time with a raw shard-lookup error); re-download it to repair.")
                continue
            }

            // Canonical `author/name` — the identity key everywhere. See `MLXModelIdentity`.
            let displayName = MLXModelIdentity.canonicalRepoId(forModelAt: modelDir, downloadBase: root)
            let createdAt = try? fileURL.resourceValues(forKeys: [.creationDateKey]).creationDate

            if let existing = foundModels.first(where: { $0.displayName == displayName }) {
                logger.error("[MLXSTORE] Duplicate model id '\(displayName)': keeping \(existing.localPath.path), HIDING \(modelDir.path). CONSEQUENCE: the hidden copy cannot be selected, deleted or resolved anywhere in the app, but still occupies disk — remove it manually.")
            } else {
                foundModels.append(MLXModelItem(
                    id: displayName, displayName: displayName, localPath: modelDir,
                    createdAt: createdAt,
                    // HubApi already wrote the commit it fetched; nothing had ever read it back.
                    revision: MLXModelRevision.installedRevision(atModelFolder: modelDir)
                ))
            }
        }
        return foundModels.sorted { $0.displayName < $1.displayName }
    }

    /// Per-model cognitive profiles. Also `nonisolated` — this is the expensive half
    /// (`detectCognitiveProfile` parses several JSON sidecars per model).
    nonisolated static func computeProfiles(for models: [MLXModelItem]) -> [String: CognitiveProfile] {
        var result: [String: CognitiveProfile] = [:]
        for model in models {
            result[model.displayName] = MLXTokenizerAnalyzer.detectCognitiveProfile(
                for: model.localPath, modelName: model.displayName
            )
        }
        return result
    }
    
    // MARK: - Remote Discovery (Metadata & Store)
    
    /// Fetches remote models with pagination, search and category filtering.
    /// - Parameter sort: the HuggingFace `sort=` field to rank by; nil keeps `defaultSortField`.
    ///   `offset` indexes into this ranking, so a caller that changes `sort` must restart at 0.
    func fetchRemoteModels(limit: Int = 30, offset: Int = 0, tags: [String]? = nil, search: String? = nil, append: Bool = false, category: String? = nil, sort: String? = nil) async {

        // Generation token: category switches and the search debounce can leave several fetches in flight,
        // so a stale response must not replace the current results or interleave an abandoned query's append.
        requestGeneration &+= 1
        let generation = requestGeneration
        inFlightFetches += 1
        isLoadingRemoteModels = true
        remoteLoadError = nil

        guard let url = Self.listingURL(search: search, tags: tags, limit: limit, offset: offset, sort: sort) else {
            logger.error("[MLXSTORE] HF fetch: could not build a URL (search=\(search ?? "<none>")). CONSEQUENCE: the store shows no results for this query.")
            finishFetch(generation: generation, error: .invalidURL)
            return
        }

        logger.info("[MLXSTORE] HF fetch gen=\(generation) → \(url.absoluteString) (append=\(append))")

        do {
            let rawModels = try await HFRequest.get([HFRawModel].self, from: url)
            logger.info("[MLXSTORE] HF fetch gen=\(generation) ← \(rawModels.count) models")


            guard generation == requestGeneration else {
                logger.info("[MLXSTORE] Discarding HF response gen=\(generation) — superseded by gen=\(self.requestGeneration). CONSEQUENCE: none; the newer query owns the list.")
                inFlightFetches = max(0, inFlightFetches - 1)
                if inFlightFetches == 0 { isLoadingRemoteModels = false }
                return
            }

            // Drops models the MLX runtime cannot load as an LLM before they reach a card (e.g. speech-recognition models
            // that would otherwise fall through to the `.textGeneration` default).
            let usable = rawModels.filter { raw in
                // Uses `ModelSupportPolicy`, the same policy as the pasted-repo-ID path and the card's 'Not supported' pill,
                // so the listing and the download button agree about what is runnable.
                guard ModelSupportPolicy.unsupportedReason(pipelineTag: raw.pipeline_tag, tags: raw.tags ?? []) != nil else { return true }
                self.logger.info("[MLXSTORE] Excluding '\(raw.id)' from the store — pipeline '\(raw.pipeline_tag ?? "?")' is not something MLXService can run as an LLM (decision/classifier, speech, image or embedding model). CONSEQUENCE: it is hidden from results rather than offered with a misleading Chat badge.")
                return false
            }
            if usable.count != rawModels.count {
                self.logger.info("[MLXSTORE] Hid \(rawModels.count - usable.count) of \(rawModels.count) result(s) as non-LLM pipelines.")
            }

            // Map raw JSON to our smart Domain Model
            let displayModels = usable.map { raw -> MLXDisplayModel in
                let caps = self.classifyCapabilities(tags: raw.tags ?? [], pipeline: raw.pipeline_tag, id: raw.id)
                return MLXDisplayModel(
                    id: raw.id,
                    size: self.modelSizes[raw.id],   // honor the cache (A9)
                    sizeBytes: self.modelSizeBytes[raw.id],
                    quantization: MLXQuantization.parse(fromRepoId: raw.id),
                    isGated: (raw.gated?.isGated ?? false) || (raw.private ?? false),
                    pipelineTag: raw.pipeline_tag,
                    capabilities: caps,
                    tags: raw.tags ?? [],
                    downloads: raw.downloads,
                    likes: raw.likes,
                    description: nil,
                    // HuggingFace exposes `lastModified`; without it every remote model has a nil date and 'Recent' sorting is arbitrary.
                    createdAt: raw.lastModifiedDate
                )
            }

            if append {
                let newUnique = displayModels.filter { new in
                    !self.availableModels.contains(where: { $0.id == new.id })
                }
                self.availableModels.append(contentsOf: newUnique)
                self.logger.info("[MLXSTORE] HF append: +\(newUnique.count) new (\(displayModels.count - newUnique.count) dupes) → total=\(self.availableModels.count)")
                if newUnique.isEmpty && !displayModels.isEmpty {
                    self.logger.warning("[MLXSTORE] HF pagination returned only duplicates at offset=\(offset) — likely end of result set; Load More will keep returning nothing.")
                } else if displayModels.isEmpty {
                    self.logger.warning("[MLXSTORE] HF pagination returned 0 models at offset=\(offset) — end of result set.")
                }
            } else {
                self.availableModels = displayModels
                self.availableModelsCategory = category
                self.availableModelsSort = sort ?? Self.defaultSortField
                self.availableModelsSearch = search
                self.logger.info("[MLXSTORE] HF replace: total=\(self.availableModels.count) category=\(category ?? "<none>") sort=\(self.availableModelsSort ?? "<none>") search=\(search ?? "<none>")")
            }
            finishFetch(generation: generation, error: nil)

            // Only fetch sizes we don't already have (A9).
            await fetchSizes(for: displayModels.filter { $0.size == nil }.map(\.id), generation: generation)

        } catch is CancellationError {
            inFlightFetches = max(0, inFlightFetches - 1)
            if inFlightFetches == 0 { isLoadingRemoteModels = false }
        } catch let error as HFRequestError {
            logger.error("[MLXSTORE] HF fetch gen=\(generation) FAILED: \(error.logLabel) (url=\(url.absoluteString)). CONSEQUENCE: the store shows an error state for this query instead of an empty list.")
            if !append, generation == requestGeneration {
                // Drop the previous category's payload rather than let it be re-filtered
                // and presented as this category's results.
                availableModels = []
                availableModelsCategory = category
                // The identity is stamped on the failure path too: a stale sort or search would let the next `loadMore`
                // treat the empty payload as its own.
                availableModelsSort = sort ?? Self.defaultSortField
                availableModelsSearch = search
            }
            finishFetch(generation: generation, error: error)
        } catch {
            logger.error("[MLXSTORE] HF fetch gen=\(generation) FAILED: \(error.localizedDescription) (url=\(url.absoluteString)). CONSEQUENCE: the store shows an error state for this query.")
            finishFetch(generation: generation, error: .malformedResponse(error.localizedDescription))
        }
    }

    // Why: `listingURL` uses `URLComponents`, never string interpolation: `.urlQueryAllowed` permits `&`, `=`, `+`, `#`,
    // so a search like `a&limit=9999` would inject query parameters.
    /// HuggingFace's default ranking for this store, and the fallback for any `SortOption` the API cannot rank by.
    nonisolated static let defaultSortField = "downloads"

    nonisolated static func listingURL(
        search: String?, tags: [String]?, limit: Int, offset: Int,
        sort: String? = nil
    ) -> URL? {
        var components = URLComponents(string: "https://huggingface.co/api/models")
        var filters = ["mlx"]
        if let tags { filters.append(contentsOf: tags) }
        var items = [
            // `direction` stays -1 for every field sent (downloads, lastModified, likes are all 'more/newer first').
            // An ascending sort must vary it with the field.
            URLQueryItem(name: "sort", value: sort ?? Self.defaultSortField),
            URLQueryItem(name: "direction", value: "-1"),
            URLQueryItem(name: "limit", value: String(limit)),
            URLQueryItem(name: "skip", value: String(offset)),
            URLQueryItem(name: "filter", value: filters.joined(separator: ","))
        ]
        if let search, !search.isEmpty {
            items.append(URLQueryItem(name: "search", value: search))
        }
        components?.queryItems = items
        return components?.url
    }

    /// Settles loading/error state for a fetch, ignoring anything a newer query superseded.
    /// `isLoadingRemoteModels` was a bare `Bool`, so with two fetches in flight the first to
    /// return cleared it while the second was still running.
    private func finishFetch(generation: UInt64, error: HFRequestError?) {
        inFlightFetches = max(0, inFlightFetches - 1)
        // The spinner is derived from the counter, not any one request's identity, so it settles even for a superseded
        // generation.
        if inFlightFetches == 0 { isLoadingRemoteModels = false }
        // Only the ERROR is generation-scoped: a superseded query's failure must not be
        // presented as the current query's result.
        guard generation == requestGeneration else { return }
        remoteLoadError = error
    }
    
    /// Heuristic logic to determine badges based on tags and naming conventions
    func classifyCapabilities(tags: [String], pipeline: String?, id: String) -> Set<MLXModelCapability> {
        var caps: Set<MLXModelCapability> = []
        let lowerId = id.lowercased()
        
        // 1. Vision
        if pipeline == "image-text-to-text" || tags.contains("vision") || lowerId.contains("vision") || lowerId.contains("pixtral") || lowerId.contains("llava") || lowerId.contains("qwen2-vl") {
            caps.insert(.vision)
        }
        
        // Reasoning (chain of thought): `ModelCapabilityHeuristics` detection plus generic Hugging Face tags
        // and the 'reasoning' keyword some publishers add to the model id.
        if tags.contains("reasoning") || tags.contains("chain-of-thought") ||
           lowerId.contains("reasoning") ||
           ModelCapabilityHeuristics.isReasoningOnly(nameCandidates: id) {
            caps.insert(.reasoning)
        }
        
        // Tool use / function calling: explicit HF tags first, then family-name heuristics for tool-capable families.
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
    
    /// Fetches sizes with a bounded window, skipping anything already cached, and abandons
    /// the batch as soon as HuggingFace starts rate-limiting — hammering a 429 wall only
    /// deepens it, and every failed size disables that card's RAM-fit advisory.
    private func fetchSizes(for repoIds: [String], generation: UInt64) async {
        let pending = repoIds.filter { modelSizes[$0] == nil }
        guard !pending.isEmpty else { return }

        var index = 0
        var rateLimited = false
        var failures = 0

        await withTaskGroup(of: (String, Result<ModelSize, HFRequestError>).self) { group in
            // Prime the window, then add one task per completion.
            while index < pending.count && index < Self.maxConcurrentSizeFetches {
                let id = pending[index]
                group.addTask { await self.sizeForModel(repoId: id) }
                index += 1
            }

            while let (id, result) = await group.next() {
                switch result {
                case .success(let size):
                    modelSizes[id] = size.formatted
                    modelSizeBytes[id] = size.bytes
                    if let position = availableModels.firstIndex(where: { $0.id == id }) {
                        availableModels[position].size = size.formatted
                        availableModels[position].sizeBytes = size.bytes
                    }
                case .failure(let error):
                    failures += 1
                    if case .rateLimited = error { rateLimited = true }
                }

                // Stop early on throttling or once the query is superseded.
                guard !rateLimited, generation == requestGeneration else { break }

                if index < pending.count {
                    let next = pending[index]
                    group.addTask { await self.sizeForModel(repoId: next) }
                    index += 1
                }
            }
            group.cancelAll()
        }

        if rateLimited {
            logger.warning("[MLXSTORE] HuggingFace rate-limited the size lookups; abandoned the remaining \(pending.count - index) of \(pending.count). CONSEQUENCE: those cards show no size and their RAM-fit verdict is 'unknown' rather than a fit estimate.")
        } else if failures > 0 {
            logger.warning("[MLXSTORE] \(failures) of \(pending.count) size lookups failed. CONSEQUENCE: those cards show no size and report an unknown RAM fit.")
        }
    }

    /// Both representations travel together so no caller has to parse the formatted string
    /// back into a number.
    struct ModelSize { let bytes: Int64; let formatted: String }

    private func sizeForModel(repoId: String) async -> (String, Result<ModelSize, HFRequestError>) {
        do {
            let bytes = try await Self.totalBytes(forRepo: repoId)
            let formatter = ByteCountFormatter()
            formatter.allowedUnits = [.useGB, .useMB]
            formatter.countStyle = .file
            return (repoId, .success(ModelSize(bytes: bytes, formatted: formatter.string(fromByteCount: bytes))))
        } catch let error as HFRequestError {
            // Was a bare `return (repoId, nil)` with no log — the single most likely
            // production failure left no trace at all.
            logger.info("[MLXSTORE] Size lookup failed for '\(repoId)': \(error.logLabel).")
            return (repoId, .failure(error))
        } catch {
            return (repoId, .failure(.malformedResponse(error.localizedDescription)))
        }
    }

    /// Fetches sizes for the curated catalog so its cards show real numbers rather than the
    /// indicative constants baked into `CuratedMLXCatalog`. Bounded by the same window as the
    /// listing path.
    func fetchSizesForCuratedModels() async {
        await fetchSizes(for: CuratedMLXCatalog.models.map(\.id), generation: requestGeneration)
    }

    // MARK: - Update checking (G8)

    /// Update status per installed model, keyed by canonical repo id. Populated by
    /// `checkForModelUpdates()`; empty until then.
    var updateStatus: [String: MLXModelRevision.UpdateStatus] = [:]
    /// True while an update sweep is running, so the UI can show progress.
    var isCheckingForUpdates: Bool = false

    /// What a model's cached update status becomes once a download resolves it to `resolved`; nil drops the entry.
    /// Claims `.upToDate` only when the resolved commit is the one the last check reported as published.
    /// Pure and static so the rule is testable without constructing the service.
    nonisolated static func statusAfterDownload(
        previous: MLXModelRevision.UpdateStatus?,
        resolved: String?
    ) -> MLXModelRevision.UpdateStatus? {
        guard let previous, let resolved else { return nil }
        guard case .updateAvailable(let installed, let latest) = previous else { return nil }
        if resolved == latest { return .upToDate(revision: resolved) }
        // Unchanged means nothing was fetched, so keep the badge: `HubApi.snapshot` takes an offline branch for a
        // complete repo folder and returns normally with no network.
        if resolved == installed { return previous }
        // Some third commit: the publisher pushed again between the check and the download.
        // Drop the entry and let the next sweep re-derive rather than assert currency nothing verified.
        return nil
    }

    /// Re-points a model's cached update status once its download lands, so 'Update available' clears after the user acts
    /// on it.
    func noteRevisionAfterDownload(repoId: String, resolved: String?) {
        // No cached entry means no badge to clear; never invent one for a first install.
        guard let previous = updateStatus[repoId] else { return }

        let next = Self.statusAfterDownload(previous: previous, resolved: resolved)
        updateStatus[repoId] = next

        if let next, case .upToDate(let revision) = next {
            logger.notice("[MLXSTORE] '\(repoId)' is now at the published revision \(MLXModelRevision.shortForm(revision)). CONSEQUENCE: its 'Update available' badge clears.")
        } else {
            logger.info("[MLXSTORE] Dropped the cached update status for '\(repoId)' after its download completed — the installed revision changed, so the previous comparison no longer holds. CONSEQUENCE: the badge clears and the next Check for Updates re-derives it.")
        }
    }

    /// Compares every installed model's downloaded revision against what HuggingFace publishes.
    /// Runs only when the user asks (one request per model), bounded like the size lookups, and stops on rate limiting.
    func checkForModelUpdates() async {
        await ensureLoaded()
        let models = installedModels
        guard !models.isEmpty else { return }

        isCheckingForUpdates = true
        defer { isCheckingForUpdates = false }
        logger.info("[MLXSTORE] Checking \(models.count) installed model(s) for updates.")

        var index = 0
        var rateLimited = false
        var updatesFound = 0

        await withTaskGroup(of: (String, MLXModelRevision.UpdateStatus, Bool).self) { group in
            func addTask(_ model: MLXModelItem) {
                group.addTask {
                    let (latest, wasRateLimited) = await Self.publishedRevision(forRepo: model.displayName)
                    return (
                        model.displayName,
                        MLXModelRevision.compare(installed: model.revision, latest: latest),
                        wasRateLimited
                    )
                }
            }
            while index < models.count && index < Self.maxConcurrentSizeFetches {
                addTask(models[index]); index += 1
            }
            while let (repoId, status, wasRateLimited) = await group.next() {
                updateStatus[repoId] = status
                if status.needsUpdate { updatesFound += 1 }
                if wasRateLimited { rateLimited = true }
                guard !rateLimited else { break }
                if index < models.count { addTask(models[index]); index += 1 }
            }
            group.cancelAll()
        }

        if rateLimited {
            logger.warning("[MLXSTORE] Update check abandoned — HuggingFace is rate-limiting. CONSEQUENCE: \(models.count - index) model(s) were not checked and show an unknown update status.")
        } else {
            logger.notice("[MLXSTORE] Update check complete: \(updatesFound) of \(models.count) installed model(s) have a newer revision published.")
        }
    }

    /// The commit HuggingFace currently publishes for a repo, plus whether the call was
    /// throttled (so the caller can stop rather than hammer a 429 wall).
    nonisolated private static func publishedRevision(forRepo repoId: String) async -> (String?, Bool) {
        guard let url = URL(string: "https://huggingface.co/api/models/\(repoId)") else { return (nil, false) }
        do {
            let detail = try await HFRequest.get(HFRepoRevision.self, from: url)
            return (detail.sha, false)
        } catch let error as HFRequestError {
            if case .rateLimited = error { return (nil, true) }
            return (nil, false)
        } catch {
            return (nil, false)
        }
    }

    /// Why Devgentic cannot run `repoId`, or nil when it can or when that cannot be determined.
    /// One model-info GET with no README; a failed lookup returns nil so an offline blip never blocks a valid download.
    func unsupportedReason(forRepo repoId: String) async -> String? {
        guard let url = URL(string: "https://huggingface.co/api/models/\(repoId)") else { return nil }
        do {
            let response = try await HFRequest.get(HFModelDetail.self, from: url)
            return ModelSupportPolicy.unsupportedReason(pipelineTag: response.pipeline_tag, tags: response.tags ?? [])
        } catch {
            logger.info("[MLXSTORE] Support pre-check for '\(repoId)' failed (\(error.localizedDescription)). CONSEQUENCE: the pasted-repo button stays enabled; the authoritative check runs again when the user presses it.")
            return nil
        }
    }

    func fetchModelDetail(repoId: String) async -> Result<MLXModelDetail, HFRequestError> {
        guard var components = URLComponents(string: "https://huggingface.co/api/models/\(repoId)") else {
            return .failure(.invalidURL)
        }
        components.queryItems = nil
        guard let url = components.url else { return .failure(.invalidURL) }

        do {
            let response = try await HFRequest.get(HFModelDetail.self, from: url)
            var detail = MLXModelDetail(repoId: repoId, response: response)
            detail.readme = await Self.fetchReadme(repoId: repoId)
            logger.info("[MLXSTORE] Loaded detail for '\(repoId)': license=\(detail.license ?? "unknown") quant=\(detail.quantizationSummary ?? "unknown") files=\(detail.fileCount) gated=\(detail.isGated) readme=\(detail.readme == nil ? "none" : "\(detail.readme?.count ?? 0) chars").")
            return .success(detail)
        } catch let error as HFRequestError {
            logger.warning("[MLXSTORE] Detail fetch failed for '\(repoId)': \(error.logLabel). CONSEQUENCE: the sheet shows an error instead of the model card; the Download button still works.")
            return .failure(error)
        } catch {
            return .failure(.malformedResponse(error.localizedDescription))
        }
    }

    /// The model card prose. A missing README is normal (many MLX conversions ship none), so a
    /// failure here degrades to nil rather than failing the whole sheet.
    nonisolated private static func fetchReadme(repoId: String) async -> String? {
        guard let url = URL(string: "https://huggingface.co/\(repoId)/raw/main/README.md") else { return nil }
        var request = URLRequest(url: url)
        request.timeoutInterval = 15
        request.cachePolicy = .useProtocolCachePolicy
        if let token = await MainActor.run(body: { HuggingFaceTokenStore.shared.token }) {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            // An authenticated response must not come from, or go into, a URL-keyed cache: `URLCache` ignores the
            // `Authorization` header, so an anonymous cached 200 could answer a signed-in request and vice versa.
            request.cachePolicy = .reloadIgnoringLocalCacheData
        }
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode),
              let text = String(data: data, encoding: .utf8) else { return nil }
        return HFModelCard.excerpt(from: text)
    }

    /// Shared by the size display and the download pre-seed.
    nonisolated private static func totalBytes(forRepo repoId: String) async throws -> Int64 {
        var components = URLComponents(string: "https://huggingface.co/api/models/\(repoId)")
        components?.queryItems = [URLQueryItem(name: "blobs", value: "true")]
        guard let url = components?.url else { throw HFRequestError.invalidURL }
        let detail = try await HFRequest.get(HFModelDetail.self, from: url)
        return Int64(detail.siblings.compactMap { $0.size }.reduce(0, +))
    }

    /// Raw byte total of a repo, the counterpart of `getSizeForModel`; `DownloadCoordinator` uses it to pre-seed the file
    /// size.
    /// Returns nil on any error; the download still proceeds and the UI falls back to '— MB/s'.
    func getTotalBytesForModel(repoId: String) async -> Int64? {
        do {
            let totalBytes = try await Self.totalBytes(forRepo: repoId)
            return totalBytes > 0 ? totalBytes : nil
        } catch let error as HFRequestError {
            logger.warning("[MLXSTORE] Pre-download size fetch failed for '\(repoId)': \(error.logLabel). CONSEQUENCE: the download still proceeds, but with no authoritative total the speed/ETA readout stays on '— MB/s' until bytes accumulate.")
            return nil
        } catch {
            logger.warning("[MLXSTORE] Pre-download size fetch failed for '\(repoId)': \(error.localizedDescription). CONSEQUENCE: download proceeds without a speed/ETA denominator.")
            return nil
        }
    }
    
    // MARK: - Download Logic
    
    /// Returns false when the request was refused (another pull is in flight, or this
    /// exact repo is already downloading). Callers should surface the refusal — a silent
    /// no-op here reads to the user as a dead button.
    @discardableResult
    func downloadModel(repoId: String) -> Bool {
        // Refuses while another pull is in flight rather than pre-empting it, like the sibling download services.
        // Does not set `errorMessage`: the bridge reads it to classify the active download's terminal state.
        if isDownloading, !currentDownloadName.isEmpty {
            if currentDownloadName == repoId {
                logger.info("[MLXSTORE] Ignoring duplicate download request for '\(repoId)' — already in flight.")
            } else {
                logger.error("[MLXSTORE] REFUSING download of '\(repoId)' — '\(self.currentDownloadName)' is still in flight and MLX has a single download slot. CONSEQUENCE: the request is dropped; the caller must surface this so the user knows to cancel the active pull first.")
            }
            return false
        }

        isDownloading = true
        currentDownloadName = repoId
        downloadProgress = 0.0
        errorMessage = nil
        lastDownloadEnding = nil
        if pausedRepoId == repoId { pausedRepoId = nil }
        // Take the slot. Any handler still unwinding from a previous occupant is now stale.
        downloadGeneration &+= 1
        let generation = downloadGeneration

        let alreadyOnDisk = Self.resumableBytes(at: partialDownloadFolder(for: repoId))
        if alreadyOnDisk > 0 {
            logger.notice("[MLXSTORE] Starting download task for '\(repoId)' — \(ByteCountFormatter.string(fromByteCount: alreadyOnDisk, countStyle: .file)) already on disk will be re-used (HubApi resumes via a Range request).")
        } else {
            logger.notice("[MLXSTORE] Starting download task for '\(repoId)'.")
        }

        downloadTask = Task { [repoId, generation] in
            do {
                // Downloads via swift-transformers' `HubApi.snapshot`, which gives the progress callback and destination contract.
                // Empty `matching: []` downloads everything in the repo (weights, tokenizer, config JSONs).
                _ = try await hub.snapshot(from: repoId) { progress in
                    let fraction = progress.fractionCompleted
                    // One unstructured Task per tick; hops are unordered, so re-check against the slot's generation, not the repo id
                    // (Pause then Resume shares the id). Weak self so pending ticks do not keep a torn-down service alive.
                    Task { @MainActor [weak self, generation] in
                        guard let self, self.downloadGeneration == generation else { return }
                        self.downloadProgress = fraction
                    }
                }

                // A cancel that lands between files does not throw: `HubApi.snapshot` returns normally after its
                // `Task.isCancelled` check, so classify on the cancellation flag too.
                if Task.isCancelled {
                    self.finishCancelled(repoId: repoId, generation: generation, reason: "cancelled between files (snapshot returned without throwing)")
                    return
                }

                // Read back the commit HubApi resolved, so the install is identifiable and a
                // later update check has something to compare against.
                let resolved = self.partialDownloadFolder(for: repoId)
                    .flatMap { MLXModelRevision.installedRevision(atModelFolder: $0) }
                if let resolved {
                    self.logger.notice("[MLXSTORE] Download of '\(repoId)' finished successfully at revision \(MLXModelRevision.shortForm(resolved)).")
                    if let record = DownloadHistoryStore.shared.fetchMostRecent(backend: .mlx, modelIdentifier: repoId) {
                        record.revisionCommitHash = resolved
                    }
                } else {
                    self.logger.notice("[MLXSTORE] Download of '\(repoId)' finished successfully (no revision metadata found — update checks won't be available for it).")
                }
                // The badge that sent the user here has to go out when the work lands.
                self.noteRevisionAfterDownload(repoId: repoId, resolved: resolved)
                // Awaited: the DownloadManager bridge reads `installedModels` to classify the terminal state,
                // so a fire-and-forget refresh would record a successful pull as cancelled.
                await self.forceRefreshInstalledModelsAsync()
                // A pause whose cancel lost the race to a completing snapshot leaves the repo marked paused though fully installed.
                if self.pausedRepoId == repoId {
                    self.logger.notice("[MLXSTORE] '\(repoId)' completed despite being paused (the cancel lost the race to the final file). CONSEQUENCE: clearing its paused marker so it presents as installed, not resumable.")
                    self.pausedRepoId = nil
                }
                self.finishTerminal(repoId: repoId, generation: generation, classification: "completed")

            } catch {
                // swift-transformers surfaces a cancel as `URLError(.cancelled)`, not `CancellationError`.
                // Key off the cancellation flag first, then either error type, and log which classification won.
                if Task.isCancelled || Self.isCancellation(error) {
                    self.finishCancelled(repoId: repoId, generation: generation, reason: "\(error)")
                    return
                }
                self.finishFailed(repoId: repoId, generation: generation, error: error)
            }
        }
        return true
    }

    /// Terminal transition for a genuine failure; keeps every downloaded byte.
    /// A failed record is already resumable, so keeping the bytes makes its Resume button honest; the failed row shows
    /// their size.
    func finishFailed(repoId: String, generation: UInt64, error: Error) {
        logger.fault("[MLXSTORE] Download of '\(repoId)' FAILED: \(error.localizedDescription).")
        // Gated on still holding the slot: a superseded task's failure would write `errorMessage`, which the bridge reads
        // to classify the active download.
        guard stillOwnsSlot(generation, repoId: repoId, phase: "failure") else { return }
        errorMessage = "Download failed: \(error.localizedDescription)"
        let kept = Self.resumableBytes(at: partialDownloadFolder(for: repoId))
        logger.notice("[MLXSTORE] Keeping \(ByteCountFormatter.string(fromByteCount: kept, countStyle: .file)) already downloaded for '\(repoId)'. CONSEQUENCE: Resume continues from here; Discard on the failed row frees it.")
        finishTerminal(repoId: repoId, generation: generation, classification: "failed")
    }

    /// True for both cancellation shapes this download path can produce.
    /// `CancellationError` is the Swift-native one; `URLError.cancelled` is what
    /// swift-transformers actually throws when its `Downloader` is cancelled.
    static func isCancellation(_ error: Error) -> Bool {
        if error is CancellationError { return true }
        if let urlError = error as? URLError, urlError.code == .cancelled { return true }
        return false
    }

    /// Clears the in-flight handles; must run on every terminal branch that still owns the slot (callers gate on
    /// `stillOwnsSlot(_:)`).
    /// A stale `downloadTask` would make the next `downloadModel` cancel and clean up an already-installed model.
    private func clearDownloadHandles() {
        downloadTask = nil
        currentDownloadName = ""
    }

    /// Whether `generation` is still the download slot's owner. See `downloadGeneration`.
    /// Internal so the ownership rule itself is directly testable rather than inferred.
    func stillOwnsSlot(_ generation: UInt64, repoId: String, phase: String) -> Bool {
        guard generation == downloadGeneration else {
            logger.notice("[MLXSTORE] Ignoring \(phase) from SUPERSEDED download of '\(repoId)' (generation \(generation), slot is now \(self.downloadGeneration)). CONSEQUENCE: the current occupant keeps its task handle, name and progress; this late unwind changes no shared state.")
            return false
        }
        return true
    }

    /// Terminal transition for success/failure. `classification` is logged so the field
    /// log explains why a record became completed vs failed vs cancelled.
    func finishTerminal(repoId: String, generation: UInt64, classification: String) {
        guard stillOwnsSlot(generation, repoId: repoId, phase: "terminal(\(classification))") else { return }
        logger.info("[MLXSTORE] Terminal state for '\(repoId)': \(classification). Clearing in-flight handles.")
        lastDownloadEnding = RecordedDownloadEnding(modelID: repoId, ending: classification == "completed" ? .succeeded : .failed)
        clearDownloadHandles()
        isDownloading = false
        refreshPartialDownloads()
    }

    /// Terminal transition for a user cancel. Clears `errorMessage` so the bridge
    /// classifies the record as cancelled rather than failed — mirrors `OllamaService`.
    func finishCancelled(repoId: String, generation: UInt64, reason: String) {
        guard stillOwnsSlot(generation, repoId: repoId, phase: "cancellation") else { return }
        logger.notice("[MLXSTORE] Download of '\(repoId)' CANCELLED (\(reason)). CONSEQUENCE: the record is marked cancelled, not failed; partial files are reclaimed by the cleanup pass.")
        lastDownloadEnding = RecordedDownloadEnding(modelID: repoId, ending: .cancelled)
        clearDownloadHandles()
        downloadProgress = 0.0
        errorMessage = nil
        isDownloading = false
    }
    
    /// The repo whose partial files are being reclaimed right now, or nil.
    /// Carries the identity so views compare against their own model; the UI shows 'Cleaning up…' while it is set.
    var cancellingRepoId: String?

    /// True while `repoId`'s partial files are being removed. Views must pass their own
    /// identifier; a global "is any cleanup running" answer is what caused C1.
    func isCancellingDownload(repoId: String) -> Bool {
        cancellingRepoId == repoId
    }

    /// The repo the user paused, if any.
    /// The `DownloadManager` bridge reads it to classify the terminal transition as `.paused`, which keeps partial bytes,
    /// not `.cancelled`.
    var pausedRepoId: String?

    /// How the most recent download ended (DownloadManager's history classification reads it).
    /// Cleared when a download starts; set on every terminal path before `isDownloading` flips.
    private(set) var lastDownloadEnding: RecordedDownloadEnding?

    /// Stops the in-flight download but keeps every downloaded byte; returns false when there is nothing to pause.
    /// Resuming is re-entering `hub.snapshot`: swift-transformers resumes from `.incomplete` files via a `Range` header.
    @discardableResult
    func pauseDownload() -> Bool {
        guard let task = downloadTask, isDownloading, !currentDownloadName.isEmpty else {
            logger.info("[MLXSTORE] pauseDownload: nothing in flight to pause.")
            return false
        }
        let repoId = currentDownloadName
        pausedRepoId = repoId
        logger.notice("[MLXSTORE] PAUSING download of '\(repoId)' at \(Int(self.downloadProgress * 100))% — partial files are KEPT so the resume can continue from them via a Range request.")

        task.cancel()
        lastDownloadEnding = RecordedDownloadEnding(modelID: repoId, ending: .paused)
        // The slot is released synchronously while the cancelled task still unwinds, so the generation bump is mandatory:
        // `resumeDownload` can install a new occupant before the old handler runs. See `downloadGeneration`.
        downloadGeneration &+= 1
        clearDownloadHandles()
        downloadProgress = 0.0
        errorMessage = nil
        isDownloading = false
        // No `removePartialDownload` here: that is the whole difference between Pause and Cancel.
        // Re-scan once the cancelled task has stopped writing, so the paused row shows its size.
        Task { [weak self] in
            _ = await task.value
            self?.refreshPartialDownloads()
        }
        return true
    }

    /// Restarts a paused or interrupted download. HubApi picks up where it left off.
    @discardableResult
    func resumeDownload(repoId: String) -> Bool {
        let resumable = Self.resumableBytes(at: partialDownloadFolder(for: repoId))
        logger.notice("[MLXSTORE] RESUMING download of '\(repoId)' — \(ByteCountFormatter.string(fromByteCount: resumable, countStyle: .file)) already on disk will be re-used via a Range request.")
        if pausedRepoId == repoId { pausedRepoId = nil }
        return downloadModel(repoId: repoId)
    }

    /// Abandons a paused or interrupted download and reclaims its bytes.
    /// Returns false when the bytes were not reclaimed (a complete install, or the delete failed); the caller must then keep
    /// the history record, which is the only remaining handle on those bytes.
    @discardableResult
    func discardPartialDownload(repoId: String) -> Bool {
        logger.notice("[MLXSTORE] DISCARDING partial download of '\(repoId)' at the user's request.")
        let reclaimed = removePartialDownload(repoId: repoId)
        if reclaimed, pausedRepoId == repoId { pausedRepoId = nil }
        return reclaimed
    }

    /// Bytes already fetched for a repo that a resume would re-use — the `.incomplete` files
    /// HubApi writes under `<repo>/.cache/huggingface/download/`, plus any completed files
    /// already moved into place.
    nonisolated static func resumableBytes(at folder: URL?) -> Int64 {
        guard let folder else { return 0 }
        return directorySize(at: folder)
    }

    // Why: Derived from the library's own resolver: the real layout has a doubled `models/` component.
    // A hand-rebuilt path makes `removePartialDownload` a silent no-op.
    /// Resolves the on-disk folder `HubApi` writes into for a repo id; nil for ids that are not exactly `author/name`.
    func partialDownloadFolder(for repoId: String) -> URL? {
        let components = repoId.components(separatedBy: "/")
        guard components.count == 2,
              !components[0].isEmpty,
              !components[1].isEmpty else {
            logger.error("[MLXSTORE] Malformed repo id '\(repoId)' — cannot derive its download folder. CONSEQUENCE: any partial files for this repo are NOT reclaimed and stay on disk unreferenced.")
            return nil
        }
        return hub.localRepoLocation(Hub.Repo(id: repoId))
    }

    /// Removes a partial-download folder so the scanner does not report it as installed; idempotent.
    /// Refuses a completed install. Returns true when the bytes are gone, false (refused or failed) when they remain;
    /// the caller must then keep any record that still points at them.
    @discardableResult
    func removePartialDownload(repoId: String) -> Bool {
        guard let folder = partialDownloadFolder(for: repoId) else { return false }

        let target = folder.standardizedFileURL

        // Why: The test is completeness, not 'has weights': an interrupted sharded download is exactly a folder containing weights.
        // `shardCompleteness` only detects truncation; it never reclaims.
        // Primary guard asks the filesystem, not the in-memory list, which comes from a debounced scan and can be stale.
        if Self.isCompleteInstall(at: target) {
            logger.error("[MLXSTORE] REFUSING to remove '\(repoId)' at \(target.path) — it is a COMPLETE install, not partial-download residue. CONSEQUENCE: cleanup skipped (the safe outcome) and the model keeps its Delete button; a stale repo id reached the cleanup path and should be investigated.")
            return false
        }

        // Secondary guard: the scan may know it as installed under a different path.
        if let installed = installedModels.first(where: {
            // Use `sameLocationLexically`, not `==`: `localPath` has a trailing slash and `target` does not,
            // and a miss here lets a recursive delete run against a completed install.
            $0.localPath.sameLocationLexically(as: target) || $0.displayName == repoId
        }) {
            logger.error("[MLXSTORE] REFUSING to remove '\(repoId)' at \(target.path) — it is a completed install (\(installed.displayName)). CONSEQUENCE: cleanup skipped (the safe outcome).")
            return false
        }

        let fm = FileManager.default
        guard fm.fileExists(atPath: target.path) else {
            logger.info("[MLXSTORE] No partial folder to remove for '\(repoId)' at \(target.path) — nothing to reclaim.")
            return true
        }
        do {
            let reclaimed = Self.directorySize(at: target)
            try fm.removeItem(at: target)
            logger.notice("[MLXSTORE] 🗑️ Removed partial download for '\(repoId)' at \(target.path), reclaiming \(ByteCountFormatter.string(fromByteCount: reclaimed, countStyle: .file)).")
            refreshPartialDownloads()
            return true
        } catch {
            logger.error("[MLXSTORE] Failed to remove partial download for '\(repoId)' at \(target.path): \(error.localizedDescription). CONSEQUENCE: the partial files stay on disk and are invisible in the UI — the user can only reclaim them manually in Finder.")
            return false
        }
    }

    /// True when the folder holds at least one model weights file.
    /// Necessary but not sufficient for 'installed' (one shard of four satisfies it); use `isCompleteInstall` to decide.
    nonisolated static func containsWeights(at url: URL) -> Bool {
        !weightFiles(at: url).isEmpty
    }

    /// The single definition of 'this directory is a usable install, not download residue'.
    /// Composed from the primitives `scanDisk` applies: true means listed with a Delete button, false means residue cleanup
    /// may reclaim.
    nonisolated static func isCompleteInstall(at url: URL) -> Bool {
        guard FileManager.default.fileExists(
            atPath: url.appendingPathComponent("config.json").path
        ) else { return false }
        guard containsWeights(at: url) else { return false }
        return shardCompleteness(at: url).isComplete
    }

    nonisolated private static func weightFiles(at url: URL) -> [URL] {
        let contents = (try? FileManager.default.contentsOfDirectory(
            at: url,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        )) ?? []
        return contents.filter { file in
            let ext = file.pathExtension.lowercased()
            return ext == "safetensors" || ext == "npz" || ext == "bin" || ext == "gguf"
        }
    }

    // Why: `containsWeights` is satisfied by one weights file, so a pull killed mid-shards would otherwise show as Installed.
    /// Whether every shard a sharded repo declares is present, per `model.safetensors.index.json`.
    /// Returns `(isComplete, expected, present)`; unsharded repos (no index file) report complete.
    nonisolated static func shardCompleteness(at url: URL) -> (isComplete: Bool, expected: Int, present: Int) {
        let indexURL = url.appendingPathComponent("model.safetensors.index.json")
        guard let data = try? Data(contentsOf: indexURL),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let weightMap = json["weight_map"] as? [String: String] else {
            return (true, 0, 0)
        }
        let expected = Set(weightMap.values)
        guard !expected.isEmpty else { return (true, 0, 0) }

        let present = Set(weightFiles(at: url).map(\.lastPathComponent))
        let found = expected.intersection(present)
        return (found.count == expected.count, expected.count, found.count)
    }

    /// Recursive byte total for a folder. Used only for logging how much a cleanup
    /// reclaimed, so failures degrade to 0 rather than propagating.
    nonisolated static func directorySize(at url: URL) -> Int64 {
        guard let enumerator = FileManager.default.enumerator(
            at: url,
            includingPropertiesForKeys: [.totalFileAllocatedSizeKey, .fileAllocatedSizeKey]
        ) else { return 0 }
        var total: Int64 = 0
        for case let fileURL as URL in enumerator {
            let values = try? fileURL.resourceValues(forKeys: [.totalFileAllocatedSizeKey, .fileAllocatedSizeKey])
            total += Int64(values?.totalFileAllocatedSize ?? values?.fileAllocatedSize ?? 0)
        }
        return total
    }

    func cancelDownload() {
        guard let task = downloadTask else {
            // No task but a leftover name means a terminal branch did not clean up; clear it so 'no task implies no in-flight
            // name' holds.
            if !currentDownloadName.isEmpty {
                logger.error("[MLXSTORE] cancelDownload: no in-flight task but '\(self.currentDownloadName)' was still recorded as downloading — a terminal branch failed to clear it. CONSEQUENCE: clearing the stale name now; no cleanup is run, since the repo it names may be a completed install.")
                clearDownloadHandles()
            } else {
                logger.info("[MLXSTORE] cancelDownload: no in-flight task — nothing to cancel.")
            }
            return
        }
        // Last line of defence in front of a recursive multi-gigabyte delete: a stale repo id must not schedule cleanup
        // against a previous, fully installed model.
        guard isDownloading else {
            logger.error("[MLXSTORE] cancelDownload: task handle present but no download in flight (stale handle for '\(self.currentDownloadName)'). CONSEQUENCE: clearing the handle WITHOUT running partial cleanup — cleaning up here would target an already-installed model.")
            clearDownloadHandles()
            return
        }
        let modelName = currentDownloadName

        logger.notice("[MLXSTORE] Cancelling download of '\(modelName)'.")
        task.cancel()
        downloadTask = nil
        cancellingRepoId = modelName

        // Wait for the in-flight task to observe cancellation so it stops writing, then reclaim the partial folder.
        // The disk leak is the real reason: `hasWeights` hides the folder, so no Delete button could reclaim it.
        Task { [weak self] in
            _ = await task.value
            await MainActor.run {
                guard let self else { return }

                // The user restarted the download for the same repo while cleanup was awaited:
                // do not delete the folder the new task is writing to, and do not overwrite its state flags.
                let newTaskForSameRepo = self.downloadTask != nil && self.currentDownloadName == modelName

                if modelName.isEmpty {
                    self.logger.error("[MLXSTORE] Cancel cleanup skipped — the cancelled download had an empty repo id. CONSEQUENCE: its partial files (if any) are not reclaimed.")
                } else if newTaskForSameRepo {
                    self.logger.info("[MLXSTORE] Cancel cleanup skipped for '\(modelName)' — a new download for the same repo is already in flight and is writing to that folder.")
                } else {
                    self.removePartialDownload(repoId: modelName)
                }

                if self.downloadTask == nil {
                    if self.lastDownloadEnding?.modelID != modelName {
                        self.lastDownloadEnding = RecordedDownloadEnding(modelID: modelName, ending: .cancelled)
                    }
                    self.isDownloading = false
                    self.downloadProgress = 0.0
                    self.currentDownloadName = ""
                    self.errorMessage = nil
                }
                // Only clear if we still own the flag — a newer cancel for a different repo
                // must not have its indicator wiped by this one finishing.
                if self.cancellingRepoId == modelName { self.cancellingRepoId = nil }
            }
            // Outside the MainActor.run block because the scan is async now — the bridge
            // reads `installedModels` to classify this cancel's terminal state.
            await self?.forceRefreshInstalledModelsAsync()
        }
    }

    /// Recomputes per-model disk usage in the background.
    /// Each model is a multi-gigabyte tree, so this must not run on the MainActor; cancels any in-flight pass so refreshes
    /// do not stack.
    private func recomputeInstalledSizes() {
        sizingTask?.cancel()
        let targets = installedModels.map { ($0.displayName, $0.localPath) }
        guard !targets.isEmpty else {
            installedSizeBytes = [:]
            return
        }
        // Hold the detached task itself, not a wrapper: a detached task does not inherit cancellation,
        // so cancelling a wrapper would never reach the walk.
        sizingTask = Task.detached(priority: .utility) { [weak self] in
            var sized: [String: Int64] = [:]
            for (name, path) in targets {
                if Task.isCancelled { return }
                sized[name] = MLXModelService.directorySize(at: path)
            }
            if Task.isCancelled || sized.isEmpty { return }
            await MainActor.run {
                guard let self else { return }
                self.installedSizeBytes = sized
                let total = sized.values.reduce(0, +)
                self.logger.info("[MLXSTORE] Sized \(sized.count) installed model(s): \(ByteCountFormatter.string(fromByteCount: total, countStyle: .file)) total on disk.")
            }
        }
    }

    // MARK: - Import

    /// What went wrong when importing a folder, in terms the user can act on.
    enum ImportError: LocalizedError {
        case notADirectory
        case missingConfig
        case missingWeights
        case incompleteShards(present: Int, expected: Int)
        case copyFailed(String)
        case alreadyInstalled(String)

        var errorDescription: String? {
            switch self {
            case .notADirectory:
                return "That isn't a folder."
            case .missingConfig:
                return "That folder has no config.json, so it isn't an MLX model."
            case .missingWeights:
                return "That folder has no weights file (.safetensors, .npz, .bin or .gguf)."
            case .incompleteShards(let present, let expected):
                return "That model is incomplete — \(present) of \(expected) shards are present. Finish the download at its source first."
            case .copyFailed(let reason):
                return "Couldn't copy the model in: \(reason)"
            case .alreadyInstalled(let name):
                return "\(name) is already installed."
            }
        }
    }

    // Why: Copies rather than symlinks: an in-place reference would let `deleteModel` recursively delete the user's own
    // directory.
    /// Validates a folder the user picked and copies it into the store under `repoId`, indistinguishable from a download.
    func importModel(from source: URL, as repoId: String) async -> Result<String, ImportError> {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: source.path, isDirectory: &isDirectory),
              isDirectory.boolValue else {
            return .failure(.notADirectory)
        }
        guard FileManager.default.fileExists(
            atPath: source.appendingPathComponent("config.json").path
        ) else {
            return .failure(.missingConfig)
        }
        guard Self.containsWeights(at: source) else {
            return .failure(.missingWeights)
        }
        // Same completeness rule the scan applies (A2) — importing a truncated repo would
        // reproduce exactly the "shows as Installed, fails at load" bug.
        let shards = Self.shardCompleteness(at: source)
        guard shards.isComplete else {
            return .failure(.incompleteShards(present: shards.present, expected: shards.expected))
        }

        await ensureLoaded()
        if isInstalled(repoId: repoId) {
            return .failure(.alreadyInstalled(repoId))
        }

        guard let destination = partialDownloadFolder(for: repoId) else {
            return .failure(.copyFailed("'\(repoId)' is not a valid author/name identifier."))
        }

        // Both the sizing walk and the copy run off the MainActor; inline they would freeze the UI for a multi-gigabyte copy.
        // The size is hoisted out of the log line for the same reason.
        let sourceBytes = await Task.detached(priority: .utility) {
            MLXModelService.directorySize(at: source)
        }.value
        logger.notice("[MLXSTORE] Importing '\(repoId)' from \(source.path) → \(destination.path) (\(ByteCountFormatter.string(fromByteCount: sourceBytes, countStyle: .file))).")
        do {
            try await Task.detached(priority: .userInitiated) {
                try FileManager.default.createDirectory(
                    at: destination.deletingLastPathComponent(), withIntermediateDirectories: true
                )
                try FileManager.default.copyItem(at: source, to: destination)
            }.value
        } catch {
            logger.error("[MLXSTORE] Import of '\(repoId)' FAILED: \(error.localizedDescription). CONSEQUENCE: nothing was added; the source folder is untouched.")
            return .failure(.copyFailed(error.localizedDescription))
        }

        await forceRefreshInstalledModelsAsync()
        logger.notice("[MLXSTORE] Imported '\(repoId)' successfully.")
        return .success(repoId)
    }

    /// Best-effort repo id for a folder the user picked, from its own name and its parent.
    /// The import sheet shows this as an editable default rather than guessing silently.
    nonisolated static func suggestedRepoId(for source: URL) -> String {
        let name = source.lastPathComponent
        let parent = source.deletingLastPathComponent().lastPathComponent
        // A python-cache folder already encodes the full id.
        if name.hasPrefix("models--") {
            return name.replacingOccurrences(of: "models--", with: "")
                       .replacingOccurrences(of: "--", with: "/")
        }
        // A plausible author directory above it (mlx-community/Foo).
        if !parent.isEmpty, parent != "/", !parent.hasPrefix("."),
           parent != "models", parent != "Downloads", parent != "Desktop", parent != "Documents" {
            return "\(parent)/\(name)"
        }
        return "local/\(name)"
    }

    /// Opens a model's folder in Finder.
    func revealInFinder(_ item: MLXModelItem) {
        logger.info("[MLXSTORE] Revealing '\(item.displayName)' at \(item.localPath.path) in Finder.")
        NSWorkspace.shared.activateFileViewerSelecting([item.localPath])
    }

    /// Opens the models directory itself.
    func revealModelsDirectoryInFinder() {
        NSWorkspace.shared.activateFileViewerSelecting([modelsDirectory])
    }

    // MARK: - Disk capacity

    /// Free space on the volume holding the models directory, in bytes.
    /// Uses `volumeAvailableCapacityForImportantUsageKey`, which accounts for purgeable space; nil when the volume cannot
    /// be queried.
    nonisolated static func availableBytes(onVolumeContaining url: URL) -> Int64? {
        guard let values = try? url.resourceValues(
            forKeys: [.volumeAvailableCapacityForImportantUsageKey, .volumeAvailableCapacityKey]
        ) else { return nil }
        if let important = values.volumeAvailableCapacityForImportantUsage {
            return Int64(important)
        }
        if let plain = values.volumeAvailableCapacity {
            return Int64(plain)
        }
        return nil
    }

    /// Headroom kept free beyond the download itself, since macOS degrades badly as the startup disk nears full.
    static let diskHeadroomBytes: Int64 = 5 * 1024 * 1024 * 1024

    /// Whether `requiredBytes` fits on the models volume with headroom to spare.
    /// Returns nil when free space is unknown — the caller should proceed, not block.
    func hasRoomForDownload(ofBytes requiredBytes: Int64) -> (fits: Bool, free: Int64)? {
        guard requiredBytes > 0,
              let free = Self.availableBytes(onVolumeContaining: modelsDirectory) else { return nil }
        return (free - requiredBytes >= Self.diskHeadroomBytes, free)
    }

    // MARK: - Partial downloads on disk

    /// A folder under the download root that is not a complete install: what a paused, failed or crashed pull leaves behind.
    /// `refreshInstalledModels` filters these out of `installedModels`, so on their own they have no Delete button.
    struct OrphanedPartialDownload: Equatable, Identifiable, Sendable {
        let repoId: String
        let path: URL
        let bytes: Int64
        var id: String { repoId }
    }

    /// What the launch notice reports: how many partial downloads, and how much disk they use.
    struct LeftoverNotice: Equatable, Sendable {
        let count: Int
        let bytes: Int64
    }

    /// Below this, leftovers are not worth interrupting the user about. They are still listed.
    nonisolated static let leftoverNoticeThreshold: Int64 = 1_000_000_000

    /// Every partial download on disk as of the last scan — including the ones a paused,
    /// interrupted or failed history row still points at. The Downloads screen splits the two:
    /// rows show their own size, and `untracked(_:trackedRepoIds:downloading:)` is the rest.
    private(set) var partialDownloads: [OrphanedPartialDownload] = []

    /// Set once, by the launch scan, when the leftovers reach `leftoverNoticeThreshold`. The root
    /// view shows it as a toast and clears it.
    var pendingLeftoverNotice: LeftoverNotice?

    /// Drives the badge on the Downloads tab. Raised with the launch notice; cleared when the user
    /// opens a Downloads view, or when the leftovers drop below the threshold.
    private(set) var leftoverNeedsAttention = false

    @ObservationIgnored private var partialScanGeneration: UInt64 = 0
    /// Sticky across superseded scans, so a later refresh can't swallow the launch notice.
    @ObservationIgnored private var announceNextScan = false

    /// Bytes on disk for `repoId`'s partial download, or nil when the last scan found none.
    func partialBytes(for repoId: String) -> Int64? {
        partialDownloads.first { $0.repoId == repoId }?.bytes
    }

    /// The leftovers no history row accounts for — the ones that would otherwise have no
    /// handle in the app at all. Excludes the repo downloading right now.
    nonisolated static func untracked(
        _ partials: [OrphanedPartialDownload],
        trackedRepoIds: Set<String>,
        downloading: String?
    ) -> [OrphanedPartialDownload] {
        partials.filter { !trackedRepoIds.contains($0.repoId) && $0.repoId != downloading }
    }

    /// The notice to show for `partials`, or nil when they are too small to mention. The live
    /// download is not a leftover and is never counted.
    nonisolated static func leftoverNotice(
        for partials: [OrphanedPartialDownload],
        excluding downloading: String?
    ) -> LeftoverNotice? {
        let counted = partials.filter { $0.repoId != downloading }
        let total = counted.reduce(Int64(0)) { $0 + $1.bytes }
        guard !counted.isEmpty, total >= leftoverNoticeThreshold else { return nil }
        return LeftoverNotice(count: counted.count, bytes: total)
    }

    /// Scan for partial-download residue. **Read-only** and synchronous — for tests and callers
    /// that need the answer now. The UI reads `partialDownloads`, kept current by
    /// `refreshPartialDownloads`.
    @discardableResult
    func findOrphanedPartialDownloads() -> [OrphanedPartialDownload] {
        Self.scanForOrphans(under: modelsDirectory)
    }

    /// Re-scans off the main actor and publishes the result; overlapping calls coalesce, only the newest scan publishes.
    /// `announce` asks for the launch notice when the leftovers are large enough.
    func refreshPartialDownloads(announce: Bool = false) {
        if announce { announceNextScan = true }
        partialScanGeneration &+= 1
        let generation = partialScanGeneration
        let root = modelsDirectory
        Task { [weak self] in
            let found = await Task.detached(priority: .utility) {
                MLXModelService.scanForOrphans(under: root)
            }.value
            guard let self else { return }
            guard generation == self.partialScanGeneration else {
                self.logger.debug("[MLXSTORE] Partial-download scan \(generation) superseded by \(self.partialScanGeneration); discarding its result.")
                return
            }
            self.applyPartialScan(found)
        }
    }

    /// Publishes a scan result. Split out so the notice and badge rules are testable without a
    /// background scan.
    func applyPartialScan(_ found: [OrphanedPartialDownload]) {
        partialDownloads = found
        let notice = Self.leftoverNotice(for: found, excluding: isDownloading ? currentDownloadName : nil)
        if notice == nil { leftoverNeedsAttention = false }
        guard announceNextScan else { return }
        announceNextScan = false
        guard let notice else { return }
        pendingLeftoverNotice = notice
        leftoverNeedsAttention = true
        logger.notice("[MLXSTORE] Leftover notice: \(notice.count) unfinished download(s) using \(ByteCountFormatter.string(fromByteCount: notice.bytes, countStyle: .file)). The user is told once this launch and the Downloads tab is badged until they look.")
    }

    /// The user has seen the Downloads screen; stop badging it.
    func acknowledgeLeftovers() {
        leftoverNeedsAttention = false
    }

    /// Launch entry point. **Read-only**: it lists and announces, it never deletes. These
    /// folders are multi-gigabyte user data, a second app instance could be writing into one,
    /// and a user may have hand-placed files there — deleting stays an explicit user action.
    static func scanPartialDownloadsAtLaunch() {
        Task { @MainActor in
            MLXModelService.shared.refreshPartialDownloads(announce: true)
        }
    }

    /// Pure filesystem scan, isolated from the actor so it can run in the background.
    nonisolated static func scanForOrphans(under modelsDirectory: URL) -> [OrphanedPartialDownload] {
        let logger = DGLogger(category: "MLXModelService")
        let fm = FileManager.default
        // HubApi's layout is `<modelsDirectory>/models/<author>/<name>`.
        let root = modelsDirectory.appendingPathComponent(Hub.RepoType.models.rawValue)
        guard let authors = try? fm.contentsOfDirectory(
            at: root, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles]
        ) else {
            logger.info("[MLXSTORE] Orphan scan: no download root at \(root.path) — nothing to check.")
            return []
        }

        var orphans: [OrphanedPartialDownload] = []
        for author in authors {
            guard (try? author.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true else { continue }
            let repos = (try? fm.contentsOfDirectory(
                at: author, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles]
            )) ?? []
            for repo in repos {
                guard (try? repo.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true else { continue }
                let contents = (try? fm.contentsOfDirectory(
                    at: repo, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]
                )) ?? []
                // Reclaimable means 'not a complete install': a partially sharded folder holds weights but is hidden from the installed
                // list, so this scan is the only thing that accounts for it. An empty folder is not reported.
                guard !Self.isCompleteInstall(at: repo), !contents.isEmpty else { continue }
                orphans.append(OrphanedPartialDownload(
                    repoId: "\(author.lastPathComponent)/\(repo.lastPathComponent)",
                    path: repo,
                    bytes: Self.directorySize(at: repo)
                ))
            }
        }

        if orphans.isEmpty {
            logger.info("[MLXSTORE] Orphan scan: no partial-download residue under \(root.path).")
        } else {
            let total = orphans.reduce(Int64(0)) { $0 + $1.bytes }
            logger.notice("[MLXSTORE] Orphan scan: \(orphans.count) partial download(s) occupying \(ByteCountFormatter.string(fromByteCount: total, countStyle: .file)) — \(orphans.map { "\($0.repoId) (\(ByteCountFormatter.string(fromByteCount: $0.bytes, countStyle: .file)))" }.joined(separator: ", ")). They are listed in the Download Manager for the user to resume or delete.")
        }
        return orphans
    }

    /// Deletes one leftover at the user's request. Refuses the repo downloading right now, and —
    /// through `removePartialDownload` — anything that turns out to be a complete install.
    /// Returns false when the bytes are still on disk.
    @discardableResult
    func discardLeftover(_ leftover: OrphanedPartialDownload) -> Bool {
        guard !(isDownloading && leftover.repoId == currentDownloadName) else {
            logger.notice("[MLXSTORE] Not deleting '\(leftover.repoId)' — it is downloading right now. CONSEQUENCE: nothing removed; cancel the download to discard it.")
            return false
        }
        logger.notice("[MLXSTORE] DISCARDING leftover partial download '\(leftover.repoId)' (\(ByteCountFormatter.string(fromByteCount: leftover.bytes, countStyle: .file))) at the user's request.")
        let removed = removePartialDownload(repoId: leftover.repoId)
        if removed, pausedRepoId == leftover.repoId { pausedRepoId = nil }
        return removed
    }

    /// Deletes each of `leftovers` and returns the bytes freed. User-initiated only.
    @discardableResult
    func discardLeftovers(_ leftovers: [OrphanedPartialDownload]) -> Int64 {
        var reclaimed: Int64 = 0
        for leftover in leftovers where discardLeftover(leftover) {
            reclaimed += leftover.bytes
        }
        if reclaimed > 0 {
            logger.notice("[MLXSTORE] Leftover reclaim complete: freed \(ByteCountFormatter.string(fromByteCount: reclaimed, countStyle: .file)).")
        }
        return reclaimed
    }

    /// Deletes every partial download on disk. Kept for callers that want everything gone;
    /// the UI deletes an explicit list with `discardLeftovers(_:)` so it never touches a folder
    /// the user didn't see.
    @discardableResult
    func reclaimOrphanedPartialDownloads() -> Int64 {
        discardLeftovers(findOrphanedPartialDownloads())
    }

    /// Deletes an installed model from disk.
    /// Returns false when the delete was refused (e.g. the model is loaded) or failed; the caller should surface that.
    @discardableResult
    func deleteModel(_ item: MLXModelItem) async -> Bool {
        let path = item.localPath
        // Off the MainActor for the same reason import is — a recursive walk over a
        // multi-gigabyte model tree, here only to produce a log line.
        let reclaimable = await Task.detached(priority: .utility) {
            MLXModelService.directorySize(at: path)
        }.value
        logger.notice("[MLXSTORE] Deleting '\(item.displayName)' at \(path.path) (\(ByteCountFormatter.string(fromByteCount: reclaimable, countStyle: .file))).")

        // Never remove files underneath a running generation.
        if await MLXService.shared.hasActiveGenerations {
            logger.error("[MLXSTORE] REFUSING to delete '\(item.displayName)' — a generation is in flight. CONSEQUENCE: delete skipped; the running turn would otherwise read weights that had been removed mid-stream.")
            errorMessage = "Can't delete \(item.displayName) while it's generating a response."
            return false
        }
        // A run still registered with the local inference coordinator — holding the lock, waiting for
        // it, or parked on a human — expects this model; deleting it would fail that run later (U12).
        if LocalInferenceCoordinator.shared.modelsInUse(on: .mlx)
            .contains(where: { MLXModelIdentity.matches(installed: item.displayName, candidate: $0) }) {
            logger.error("[MLXSTORE] REFUSING to delete '\(item.displayName)' — a running, queued or parked run expects to use it. CONSEQUENCE: delete skipped; finish or stop that run first.")
            errorMessage = "\(item.displayName) is needed by a run that hasn't finished yet. Stop or finish it before deleting the model."
            return false
        }
        if await MLXService.shared.isModelLoaded(at: path) {
            logger.error("[MLXSTORE] REFUSING to delete '\(item.displayName)' — it is currently loaded in MLXService. CONSEQUENCE: delete skipped — deleting it would leave a lazy reload targeting a path that no longer exists. It unloads on MLX's 2-minute idle timer, or when a run on another local model takes the local lock.")
            // A status, not a remedy: switching conversations or models does not unload anything.
            errorMessage = "\(item.displayName) is still loaded in memory. It unloads by itself 2 minutes after its last use, or when a run on another local model starts."
            return false
        }

        do {
            // Deliberately inline, unlike the sizing walk and the import copy: the two guards above are awaits,
            // so extra suspension widens the window in which a generation could read weights being unlinked.
            try FileManager.default.removeItem(at: path)
        } catch {
            logger.error("[MLXSTORE] Delete FAILED for '\(item.displayName)' at \(path.path): \(error.localizedDescription). CONSEQUENCE: the model remains on disk and still occupies \(ByteCountFormatter.string(fromByteCount: reclaimable, countStyle: .file)).")
            errorMessage = "Failed to delete: \(error.localizedDescription)"
            return false
        }

        // Remove the now-empty author directory so the tree doesn't accumulate husks.
        let authorDir = path.deletingLastPathComponent()
        if let siblings = try? FileManager.default.contentsOfDirectory(
            at: authorDir, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]
        ), siblings.isEmpty {
            try? FileManager.default.removeItem(at: authorDir)
            logger.info("[MLXSTORE] Removed now-empty author directory \(authorDir.lastPathComponent).")
        }

        // Keep history honest — a "completed" record for a model that is gone is what makes
        // the coordinator's install check and the sidebar disagree.
        if let record = DownloadHistoryStore.shared.fetchMostRecent(backend: .mlx, modelIdentifier: item.displayName) {
            _ = DownloadHistoryStore.shared.delete(id: record.id)
            logger.info("[MLXSTORE] Removed the download record for '\(item.displayName)' so history matches disk.")
        }

        // Belt and braces: even though we refused above when it was loaded, make sure no
        // stale directory survives in MLXService to be lazily reloaded.
        await MLXService.shared.forgetModel(at: path)

        // Drop memoised sidecar reads for the now-deleted paths. (Edits are handled by the
        // cache's mtime key; deletions are not, since the key simply stops being asked for.)
        MLXTokenizerAnalyzer.clearSidecarCache()

        logger.notice("[MLXSTORE] Deleted '\(item.displayName)', reclaimed \(ByteCountFormatter.string(fromByteCount: reclaimable, countStyle: .file)).")
        // Awaited: callers (and the store's card list) must observe the model gone.
        await forceRefreshInstalledModelsAsync()
        clearIntelligenceCoreSelectionIfUnresolvable(afterDeleting: item)
        return true
    }

    /// Drops the Intelligence Core selection when the delete left it pointing at nothing.
    /// Checked after the refresh via `installedModel(named:)`, so a selection another installed copy satisfies is left alone.
    private func clearIntelligenceCoreSelectionIfUnresolvable(afterDeleting item: MLXModelItem) {
        let key = AppSettings.coreIntelligenceModelKey
        let selected = UserDefaults.standard.string(forKey: key) ?? ""
        guard !selected.isEmpty,
              MLXModelIdentity.matches(installed: item.displayName, candidate: selected),
              installedModel(named: selected) == nil else { return }
        UserDefaults.standard.removeObject(forKey: key)
        logger.notice("[MLXSTORE] Cleared the Intelligence Core selection '\(selected)' — its model was just deleted. CONSEQUENCE: IC features (compaction summaries, synthesis) report no model selected until one is chosen in Settings, instead of planning around a model that cannot load.")
    }
}

// MARK: - HuggingFace transport

/// A classified HuggingFace API failure.
/// Classifying the `URLResponse` separates rate-limited, offline, gated and genuinely-empty results from decode errors.
enum HFRequestError: LocalizedError, Equatable {
    case rateLimited(retryAfter: TimeInterval?)
    case unauthorized
    case notFound
    case serverError(status: Int)
    case offline
    case malformedResponse(String)
    case invalidURL

    var errorDescription: String? {
        switch self {
        case .rateLimited(let retryAfter):
            if let retryAfter, retryAfter > 0 {
                return "HuggingFace is rate-limiting requests. Try again in \(Int(retryAfter.rounded()))s."
            }
            return "HuggingFace is rate-limiting requests. Try again shortly."
        case .unauthorized:      return "This model needs a HuggingFace access token. Add one in Settings › General, and make sure you've accepted the model's licence on HuggingFace."
        case .notFound:          return "That model doesn't exist on HuggingFace."
        case .serverError(let status): return "HuggingFace is unavailable (HTTP \(status))."
        case .offline:           return "No internet connection."
        case .malformedResponse: return "HuggingFace returned an unexpected response."
        case .invalidURL:        return "Couldn't build a valid HuggingFace URL."
        }
    }

    /// Retrying immediately is what deepens a 429, so the UI suppresses its retry button.
    var isRateLimited: Bool {
        if case .rateLimited = self { return true }
        return false
    }

    /// Short form for logs — pairs with the url and repo id at the call site.
    var logLabel: String {
        switch self {
        case .rateLimited(let r):      return "429 rate-limited (retryAfter=\(r.map { String(Int($0)) } ?? "none"))"
        case .unauthorized:            return "401/403 unauthorized"
        case .notFound:                return "404 not found"
        case .serverError(let status): return "HTTP \(status)"
        case .offline:                 return "offline"
        case .malformedResponse(let d): return "malformed response (\(d))"
        case .invalidURL:              return "invalid URL"
        }
    }
}

/// One place where HuggingFace responses are turned into either a decoded value or a
/// classified error. Mirrors what `CloudRequestPipeline` already does for every cloud
/// provider rather than reimplementing status handling per call site.
enum HFRequest {

    // Why: `URLCache` keys on the URL, not `Authorization`, so a cached 200 could verify a revoked token as valid.
    /// One bounded retry with jittered backoff for transient 5xx and dropped connections; `.rateLimited` is never retried.
    /// - Parameter cachePolicy: defaults to the policy every listing call wants; only the token check overrides it.
    static func get<T: Decodable>(
        _ type: T.Type,
        from url: URL,
        cachePolicy: URLRequest.CachePolicy = .useProtocolCachePolicy,
        attempt: Int = 0
    ) async throws -> T {
        do {
            return try await perform(type, from: url, cachePolicy: cachePolicy)
        } catch let error as HFRequestError {
            let retriable: Bool
            switch error {
            case .serverError, .malformedResponse: retriable = true
            case .rateLimited, .unauthorized, .notFound, .offline, .invalidURL: retriable = false
            }
            guard retriable, attempt < 1 else { throw error }
            // Jitter so a page's worth of concurrent size lookups doesn't retry in lockstep.
            let backoff = UInt64((0.4 + Double.random(in: 0...0.4)) * 1_000_000_000)
            try await Task.sleep(nanoseconds: backoff)
            return try await get(type, from: url, cachePolicy: cachePolicy, attempt: attempt + 1)
        }
    }

    private static func perform<T: Decodable>(
        _ type: T.Type,
        from url: URL,
        cachePolicy: URLRequest.CachePolicy
    ) async throws -> T {
        var request = URLRequest(url: url)
        // Authenticated requests see gated/private repos AND get a far higher rate limit —
        // anonymous throttling is part of why the size fan-out (A9) drew 429s so readily.
        let token = await MainActor.run(body: { HuggingFaceTokenStore.shared.token })
        if let token {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        // Bounded so the store cannot hang on URLSession's 60s default.
        request.timeoutInterval = 20
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        // The list endpoint's top-30 payload is cacheable, so let URLSession revalidate when there is no token.
        // An authenticated response must not share a URL-keyed cache: `URLCache` ignores `Authorization`.
        request.cachePolicy = token == nil ? cachePolicy : .reloadIgnoringLocalCacheData

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await URLSession.shared.data(for: request)
        } catch let error as URLError {
            switch error.code {
            case .notConnectedToInternet, .networkConnectionLost, .dataNotAllowed:
                throw HFRequestError.offline
            case .cancelled:
                throw CancellationError()
            default:
                throw HFRequestError.malformedResponse(error.localizedDescription)
            }
        }

        guard let http = response as? HTTPURLResponse else {
            throw HFRequestError.malformedResponse("non-HTTP response")
        }

        switch http.statusCode {
        case 200...299:
            break
        case 401, 403:
            throw HFRequestError.unauthorized
        case 404:
            throw HFRequestError.notFound
        case 429:
            let retryAfter = (http.value(forHTTPHeaderField: "Retry-After")).flatMap(TimeInterval.init)
            throw HFRequestError.rateLimited(retryAfter: retryAfter)
        case 500...599:
            throw HFRequestError.serverError(status: http.statusCode)
        default:
            throw HFRequestError.serverError(status: http.statusCode)
        }

        do {
            return try JSONDecoder().decode(T.self, from: data)
        } catch {
            throw HFRequestError.malformedResponse(error.localizedDescription)
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
    /// Whether the repo requires an access token. Dropped by the old decoder, so a gated repo
    /// rendered as an ordinary card with an ordinary Download button that could only fail.
    let gated: HFGatedFlag?
    let `private`: Bool?
    /// ISO-8601 timestamp from the HF API. Optional because not every listing includes it.
    let lastModified: String?

    /// Parsed form that makes the 'Recent' sort meaningful for remote results.
    var lastModifiedDate: Date? {
        guard let lastModified else { return nil }
        return ISO8601DateFormatter.hfFormatter.date(from: lastModified)
            ?? ISO8601DateFormatter.hfFractionalFormatter.date(from: lastModified)
    }
}

extension ISO8601DateFormatter {
    static let hfFormatter = ISO8601DateFormatter()
    static let hfFractionalFormatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()
}

/// Minimal shape for the update check — only the current commit is needed, so this avoids
/// decoding the full model card for every installed model.
struct HFRepoRevision: Decodable {
    let sha: String?
}

struct HFModelDetail: Decodable {
    struct Sibling: Decodable {
        /// Present only when the request passes `?blobs=true`.
        let size: Int?
        let rfilename: String?
    }
    let siblings: [Sibling]

    // Everything below is optional and comes free on the same call the size fetch already
    // makes — the response was being decoded and thrown away except for sibling sizes.
    let author: String?
    let downloads: Int?
    let likes: Int?
    let tags: [String]?
    let pipeline_tag: String?
    let library_name: String?
    let lastModified: String?
    let createdAt: String?
    /// True when the repo requires a HuggingFace token (see G4 — not yet supported).
    let gated: HFGatedFlag?
    /// Total bytes, without needing `?blobs=true`.
    let usedStorage: Int64?
    let cardData: CardData?
    let config: ModelConfig?
    let safetensors: Safetensors?

    struct CardData: Decodable {
        let license: String?
        let license_link: String?
        let base_model: HFStringOrArray?
        let language: HFStringOrArray?
    }

    struct ModelConfig: Decodable {
        let architectures: [String]?
        let model_type: String?
        let quantization_config: Quantization?

        struct Quantization: Decodable { let bits: Int? }
    }

    struct Safetensors: Decodable {
        /// Stored tensor-element count; for a quantized repo this is not the logical parameter count, so it is shown as 'tensor
        /// elements'.
        let total: Int64?
    }
}

/// `gated` is `false` for open repos and a string ("auto"/"manual") for gated ones.
enum HFGatedFlag: Decodable {
    case open
    case gated(String)

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let flag = try? container.decode(Bool.self) {
            self = flag ? .gated("yes") : .open
        } else if let kind = try? container.decode(String.self) {
            self = .gated(kind)
        } else {
            self = .open
        }
    }

    var isGated: Bool {
        if case .gated = self { return true }
        return false
    }
}

/// Several card fields are "string or array of strings" depending on the publisher.
enum HFStringOrArray: Decodable {
    case one(String)
    case many([String])

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let single = try? container.decode(String.self) {
            self = .one(single)
        } else {
            self = .many((try? container.decode([String].self)) ?? [])
        }
    }

    var values: [String] {
        switch self {
        case .one(let v):   return [v]
        case .many(let vs): return vs
        }
    }
}
