// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
//
//  MLXModelService.swift
//  Devgentic
//
//  Created by Raj Singh on 04/02/26.
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

    /// Which store category `availableModels` was actually fetched for. A failed fetch used
    /// to leave the previous category's payload in place, and the view model then re-filtered
    /// THAT for the new category — presenting a plausible but wrong list with no indication
    /// the network had failed. Callers compare this before rendering.
    var availableModelsCategory: String?

    /// The server ranking and search term that produced `availableModels`, alongside the category.
    ///
    /// ⚠️ THE CATEGORY ALONE IS NOT THE PAYLOAD'S IDENTITY. `DestinationCoordinator` caches TWO
    /// store view models for the app lifetime — one filtered for tool-capable models, one not —
    /// and they share THIS array. Each keeps its own sort, search and page count, so the agent
    /// store fetching `.all` by downloads silently replaces the general store's `.all` ranked by
    /// date. The category matched, so the general store rendered the other instance's rows and
    /// then paged its own offset into them. Every field the query varied by has to be recorded, or
    /// "is this payload mine?" cannot be answered.
    var availableModelsSort: String?
    var availableModelsSearch: String?

    /// Why the last remote fetch failed, or nil if it succeeded. The store renders this
    /// instead of the generic "No models found" empty state, which previously made
    /// rate-limited, offline, gated and genuinely-empty look identical.
    var remoteLoadError: HFRequestError?

    /// Monotonic token identifying the newest fetch. Responses from older generations are
    /// discarded rather than allowed to overwrite newer results.
    @ObservationIgnored private var requestGeneration: UInt64 = 0
    /// How many fetches are outstanding, so a single completion can't clear the spinner
    /// while another is still running.
    @ObservationIgnored private var inFlightFetches: Int = 0

    /// Max simultaneous HuggingFace size requests. `?blobs=true` enumerates every file in a
    /// repo, and this used to fan out one task per model with no bound — 30 per page, re-run
    /// on every tab click and every debounce pause (a tab sweep was ~155 requests in seconds),
    /// which reliably drew a 429 from the anonymous rate limit. 5 keeps a page responsive
    /// while staying well inside it.
    @ObservationIgnored private static let maxConcurrentSizeFetches = 5

    // Download State
    var downloadProgress: Double = 0.0
    var isDownloading: Bool = false
    var currentDownloadName: String = ""
    var errorMessage: String?

    // Task management for cancellation.
    // Internal rather than private so tests can install an in-flight download and exercise
    // the pause / late-unwind paths — the flagship pause invariant previously had no coverage
    // because there was no way to put the service into a genuinely downloading state.
    @ObservationIgnored var downloadTask: Task<Void, Never>?

    /// Monotonic token identifying the current occupant of the single download slot.
    ///
    /// ⚠️ A download task's terminal handlers run LONG after the slot may have changed hands.
    /// `pauseDownload` cancels the task and releases the slot synchronously, but the cancelled
    /// task keeps unwinding — and `resumeDownload` calls straight back into `downloadModel`,
    /// so Pause→Resume is the fast path into that window. Without a token the late unwind's
    /// `clearDownloadHandles()` wiped the NEW download's `downloadTask` and
    /// `currentDownloadName`, leaving it running with a dead Cancel button, self-suppressing
    /// progress ticks, a bridge that recorded it as cancelled, and a freed interlock that
    /// admitted a third concurrent `hub.snapshot` into the same folder.
    ///
    /// A repo-id comparison is NOT sufficient: Pause→Resume has the same id on both sides.
    /// Bumped by whoever TAKES the slot (`downloadModel`) or RELEASES it (`pauseDownload`).
    /// `cancelDownload` deliberately does not bump — it leaves `isDownloading` true, so the
    /// slot stays occupied until the task's own handler runs and legitimately clears it.
    @ObservationIgnored var downloadGeneration: UInt64 = 0

    // Cache for model sizes to avoid re-fetching. Read on every remote map (it used to be
    // written and never read, so every page re-fetched sizes it already had).
    var modelSizes: [String: String] = [:]
    /// Raw byte totals, keyed the same way. Sorting and fit assessment use these.
    var modelSizeBytes: [String: Int64] = [:]

    /// On-disk size of each INSTALLED model, keyed by canonical repo id.
    ///
    /// Computed off the MainActor after each scan and published when it lands — deliberately
    /// not part of the scan itself, which already runs synchronously on the main thread and
    /// walks the whole tree (see the audit's A15). Empty until the first sizing pass
    /// completes; the UI simply shows no figure until then.
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

    /// The model's trained context window (read from its `config.json` via the cached
    /// cognitive profile), looked up by display name. Nil when the model isn't installed
    /// or its config exposes no context length. Used to heal MLX profiles that were saved
    /// before the window was read into metadata (they'd otherwise show the 8K fallback).
    func trainedContextWindow(forModelName name: String) -> Int? {
        guard let item = installedModel(named: name) else { return nil }
        return cachedCognitiveProfile(for: item).metadata?.contextWindow
    }

    /// The single lookup every consumer should use to turn a stored model name into an
    /// installed model. Goes through `MLXModelIdentity` so a profile saved before the
    /// canonical-id fix (which stored a bare, author-less name) still resolves — and so the
    /// ambiguous fallback is logged rather than silently guessing.
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


    // Debounce guard to prevent rapid-fire filesystem scans (e.g. init + onAppear).
    //
    // 2s, not 30s. The old 30s window made every explicit refresh a no-op — the store's
    // Refresh button, the store's category switch and the picker's `.onAppear` all silently
    // did nothing for half a minute after any prior scan, so adding or removing a model
    // folder in Finder appeared to have no effect. The interval only needs to absorb the
    // init + onAppear double-fire: the measured scan cost is 5-7ms for the walk and
    // 10-18ms for the profile rebuild on an 18-model, 76GB library.
    private var lastScanTime: Date? = nil
    private let scanDebounceInterval: TimeInterval = 2.0
    /// Exposed so a test can assert the window stays short enough not to swallow a user's
    /// explicit Refresh — the failure this constant caused was invisible, not a crash.
    var scanDebounceIntervalForTesting: TimeInterval { scanDebounceInterval }
    /// Snapshot of model count from last scan — used to skip no-op refreshes
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
        // Test override → user's custom location → default. `MLXModelsLocation` logs whenever
        // it falls back, because a silently-wrong directory here re-downloads gigabytes and
        // points the partial-download cleanup somewhere it shouldn't be.
        let mlxPath = modelsRootOverride
            ?? MLXModelsLocation.effectiveDirectory()
            // Last resort. `MLXModelsLocation` has already logged why both other paths failed;
            // this keeps the app functional rather than trapping on a force-unwrap the way the
            // old `urls(for:).first!` did.
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

    /// Supplies the HuggingFace token for `hub`.
    ///
    /// ⚠️ An instance created with a `modelsRootOverride` — i.e. a test — gets `{ nil }`
    /// instead of the Keychain reader. Any path through `hub` otherwise reaches
    /// `SecItemCopyMatching` against the real login keychain, which can raise a modal prompt
    /// that no headless test run can dismiss; the run then dies ~340s later as a "runner hung
    /// before establishing connection", which reads as a crash rather than a permission stall.
    @ObservationIgnored private let hfTokenProvider: () -> String?

    var hub: HubApi {
        // ⚠️ Pass the token explicitly. `HubApi`'s own fallback is `hfTokenFromEnv()`, which
        // reads `HF_TOKEN` from the process environment — and a .app launched from Finder,
        // Spotlight or Sparkle inherits no shell environment, so that is always nil in the
        // shipped product regardless of what the user has in their shell profile.
        HubApi(downloadBase: modelsDirectory, hfToken: hfTokenProvider())
    }

    init(modelsRootOverride: URL? = nil) {
        self.modelsRootOverride = modelsRootOverride
        self.hfTokenProvider = modelsRootOverride == nil
            ? { HuggingFaceTokenStore.shared.token }
            : { nil }
        // Kick off the first scan without blocking init. `installedModels` is empty until it
        // lands; `ensureLoaded()` is how callers wait for it.
        forceRefreshInstalledModels()
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
        // Fire-and-forget launcher. The scan itself is off-actor (see `scanDisk`), so this
        // returns immediately and `installedModels` is published when the walk lands.
        // Callers that need the result must `await ensureLoaded()`.
        Task { await refreshInstalledModelsAsync() }
    }

    /// Scans disk and publishes the result.
    ///
    /// ⚠️ The walk and the per-model profile parsing run OFF the MainActor. Previously both
    /// ran synchronously on it, reachable from four request-path consumers: a recursive
    /// enumerator over an 81 GB tree plus `detectCognitiveProfile` per model, blocking the UI
    /// while a user turn waited. Only the final publish is main-actor work.
    func refreshInstalledModelsAsync(force: Bool = false) async {
        // ⚠️ Coalesce BEFORE the debounce, not after.
        //
        // Several surfaces (init, onAppear, a completing download, a category switch) can ask
        // at once. Joining an in-flight walk is cheaper than racing a second one over the same
        // tree — but more importantly it is the only correct answer for a caller that needs
        // the result. With the debounce checked first, a caller arriving moments after init
        // started its scan was told "too soon" and returned on an EMPTY list, which reads as
        // "no models installed" and fails a turn with a 404 for a model that is present.
        if let inflight = scanTask {
            await inflight.value
            // ⚠️ Joining is NOT sufficient for a forcing caller. `force: true` means "I just
            // changed the disk", and the walk we joined may have read it BEFORE that change —
            // it was already running when we arrived. Returning here handed a delete its own
            // model back as still installed, and handed a completed download a list without
            // it, which the bridge then classified as cancelled. A forcing caller must see a
            // walk that started after its mutation, so it falls through to start one.
            if !force { return }

            // Unless another forcing caller already started one while we were joined: that
            // walk also began after our mutation (we called before `inflight` finished), so
            // joining it is correct and avoids a third pass over a multi-gigabyte tree.
            // (`Task` is a struct but conforms to `Hashable` on the underlying task identity,
            // so `!=` is the identity comparison here.)
            if let newer = scanTask, newer != inflight {
                await newer.value
                return
            }
        }

        if !force, let lastScan = lastScanTime, Date().timeIntervalSince(lastScan) < scanDebounceInterval {
            logger.info("[MLXSTORE] Skipping redundant model scan — the last one was \(String(format: "%.1f", Date().timeIntervalSince(lastScan)))s ago (debounce \(String(format: "%.0f", self.scanDebounceInterval))s). CONSEQUENCE: the installed list is unchanged; pass force:true when the caller knows disk changed.")
            return
        }

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
        await task.value
        // ⚠️ Clear only our own handle. A forcing caller that joined this walk falls through
        // and installs its own task here; an unconditional nil would drop that reference and
        // stop everyone arriving afterwards from coalescing onto it.
        if scanTask == task { scanTask = nil }
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
        // ⚠️ Compare the ITEMS, not the name set. `MLXModelItem` carries mutable per-model
        // state — `revision`, `localPath`, `createdAt` — and a name-set diff is blind to all
        // of it. A re-download changes the commit but never the names, so the freshly scanned
        // array was discarded: `checkForModelUpdates` kept re-reading the old hash and the
        // "Update available" badge never cleared for the rest of the session. The same branch
        // skipped `recomputeInstalledSizes()`, so a model that grew or shrank in place kept
        // its old size too. Membership was only ever a proxy for "did anything change".
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
    
    /// Fetches remote models with support for pagination, search, and category filtering.
    /// - Parameter sort: the HuggingFace `sort=` field to rank by. nil keeps `defaultSortField`.
    ///   ⚠️ `offset` indexes into THIS ranking — a caller that changes `sort` must restart at 0,
    ///   or it appends page 4 of one result set on top of pages 1-3 of another.
    func fetchRemoteModels(limit: Int = 30, offset: Int = 0, tags: [String]? = nil, search: String? = nil, append: Bool = false, category: String? = nil, sort: String? = nil) async {

        // Generation token (A11). Category switches and the 500ms search debounce can leave
        // several fetches in flight at once; without this the SLOWEST response won, so a
        // stale "All" page could replace the "Vision" results the user is looking at, and
        // an append from an abandoned query could interleave into the new list.
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

            // Drop models the MLX runtime cannot load as an LLM before they ever reach a
            // card. Verified live: results 1, 2 and 29 of the top 30 were `parakeet-tdt`
            // speech-recognition models, each rendered with a "Chat" badge because anything
            // unrecognised fell through to the `.textGeneration` default — a first-run user's
            // top two recommendations were a 2.5 GB download that fails at inference.
            let usable = rawModels.filter { raw in
                guard MLXPipelineFilter.shouldExclude(pipelineTag: raw.pipeline_tag) else { return true }
                self.logger.info("[MLXSTORE] Excluding '\(raw.id)' from the store — pipeline '\(raw.pipeline_tag ?? "?")' is not something MLXService can run as an LLM. CONSEQUENCE: it is hidden from results rather than offered with a misleading Chat badge.")
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
                    capabilities: caps,
                    tags: raw.tags ?? [],
                    downloads: raw.downloads,
                    likes: raw.likes,
                    description: nil,
                    // HuggingFace exposes `lastModified`; without it every remote model had
                    // a nil date, so "Recent" compared .distantPast against itself and the
                    // non-stable sort permuted the list arbitrarily on every tick.
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
                // ⚠️ The identity must be stamped on the FAILURE path too. Leaving a stale sort
                // or search here means the next `loadMore` compares against the query that
                // succeeded before this one failed, and decides the empty payload is its own.
                availableModelsSort = sort ?? Self.defaultSortField
                availableModelsSearch = search
            }
            finishFetch(generation: generation, error: error)
        } catch {
            logger.error("[MLXSTORE] HF fetch gen=\(generation) FAILED: \(error.localizedDescription) (url=\(url.absoluteString)). CONSEQUENCE: the store shows an error state for this query.")
            finishFetch(generation: generation, error: .malformedResponse(error.localizedDescription))
        }
    }

    /// Builds the HuggingFace listing URL.
    ///
    /// ⚠️ `URLComponents`, never string interpolation. `.urlQueryAllowed` — the character set
    /// the old code escaped with — PERMITS `&`, `=`, `+` and `#`, so a search for
    /// `a&limit=9999&filter=evil` injected extra query parameters into the request.
    ///
    /// `nonisolated static` so this is reachable from a test without standing up the service:
    /// the B7 test previously rebuilt a `URLComponents` in its own body and asserted that
    /// Foundation percent-encodes, which is true of Foundation whatever this function does.
    /// HuggingFace's default ranking for this store, and the fallback for any `SortOption` the
    /// API cannot rank by (repo bytes are not a field on the models listing).
    nonisolated static let defaultSortField = "downloads"

    nonisolated static func listingURL(
        search: String?, tags: [String]?, limit: Int, offset: Int,
        sort: String? = nil
    ) -> URL? {
        var components = URLComponents(string: "https://huggingface.co/api/models")
        var filters = ["mlx"]
        if let tags { filters.append(contentsOf: tags) }
        var items = [
            // ⚠️ `direction` stays -1 for every field sent — downloads, lastModified and likes
            // are all "more/newer first". An ascending sort would have to vary this with the
            // field, so do not add one without revisiting this line.
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
        // ⚠️ The spinner is derived from the COUNTER, not from any one request's identity, so
        // it must settle even for a superseded generation. With this behind the guard below, a
        // stale fetch completing LAST left `isLoadingRemoteModels` true forever — the spinner
        // never stopped and "Load More Models" stayed disabled for the rest of the session.
        // The cancellation path above already settles it unguarded; these two disagreed.
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

    /// What a model's cached update status becomes once a download resolves it to `resolved`.
    ///
    /// `nil` means "drop the entry" — assigning nil through a dictionary subscript removes the
    /// key, so the badge disappears and the next sweep re-derives the answer from scratch.
    ///
    /// ⚠️ ONLY claims `.upToDate` when the freshly-resolved commit IS the one the last check
    /// reported as published. Any other outcome drops the entry rather than asserting a state
    /// nothing verified: the publisher can push again between the check and the download, and
    /// a badge that lies about being current is worse than no badge.
    ///
    /// Pure and static so the rule is testable without constructing the service, whose `init`
    /// kicks off a filesystem scan.
    nonisolated static func statusAfterDownload(
        previous: MLXModelRevision.UpdateStatus?,
        resolved: String?
    ) -> MLXModelRevision.UpdateStatus? {
        guard let previous, let resolved else { return nil }
        guard case .updateAvailable(let installed, let latest) = previous else { return nil }
        if resolved == latest { return .upToDate(revision: resolved) }
        // ⚠️ UNCHANGED MEANS NOTHING WAS FETCHED — keep the badge. `HubApi.snapshot` takes an
        // offline branch when the repo folder is complete: it verifies local hashes and returns
        // normally, with no throw, no network and no bytes. The success path then ran in full and
        // re-read the OLD commit, so dropping the entry here made the badge vanish on an update
        // that never happened. The update really is still available.
        if resolved == installed { return previous }
        // Some third commit: the publisher pushed again between the check and the download, so
        // the previous comparison no longer describes anything. Drop it and let the next sweep
        // re-derive rather than assert a currency nothing verified.
        return nil
    }

    /// Re-points a model's cached update status once its download lands.
    ///
    /// ⚠️ `updateStatus` was written in exactly ONE place and cleared NOWHERE, so a user who
    /// acted on "Update available" kept seeing it for the rest of the session — the one signal
    /// that the update had worked was the one signal missing.
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
    ///
    /// ⚠️ Explicit, not automatic. One request per installed model is exactly the unbounded
    /// fan-out A9 fixed — doing it on every store open would re-create that. This runs when the
    /// user asks, bounded by the same concurrency window as the size lookups, and abandons the
    /// sweep the moment HuggingFace starts rate-limiting.
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

    /// Fetches the full model card for the detail sheet.
    ///
    /// Deliberately NOT called from the list path — that would reintroduce the N+1 fan-out A9
    /// fixed. One request, on demand, when the user opens a model.
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
            // ⚠️ AN AUTHENTICATED RESPONSE MAY NOT COME FROM, OR GO INTO, A URL-KEYED CACHE.
            // `URLCache` ignores the `Authorization` header, so an anonymous 200 cached while
            // browsing signed-out could answer the very next signed-in request — and vice versa.
            // The new "Add Token…" flow makes that sequence routine: hit a 401, add a token, and
            // `refresh()` re-requests the same listing URL that was just cached anonymously.
            // The token check sets this explicitly for the same reason; here it covers every
            // other token-bearing call.
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

    /// Public counterpart to `getSizeForModel` that returns the raw byte
    /// total instead of a formatted string. Used by `DownloadCoordinator`
    /// to pre-seed `DownloadRecord.fileSizeBytes` before kicking off an
    /// MLX pull, so the speed/ETA display has an authoritative denominator
    /// from the first progress tick onward. Returns nil on any error
    /// (unknown repo, network issue, malformed response) — the download
    /// still proceeds, the UI just falls back to "— MB/s".
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
        // This used to call `cancelDownload()` unconditionally, silently pre-empting any
        // in-flight pull. That discarded the running model's bytes with no toast and no
        // log, AND corrupted the DownloadManager bridge: `isDownloading` never returned to
        // false between the two, so the new model's progress was written into the OLD
        // model's DownloadRecord, and when the pre-empted task's terminal branch fired it
        // nil'd `mlxActiveID` — leaving the new download with no record, no sidebar row and
        // no cancel button. Both sibling services already refuse rather than pre-empt
        // (`WhisperModelDownloadService.downloadModel`, `OllamaService.pullModel`).
        //
        // Deliberately does NOT set `errorMessage`: the bridge reads that field to classify
        // the ACTIVE download's terminal state, so writing a refusal there would mark the
        // still-running model as failed when it later completes.
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
                // mlx-swift-lm 3.x dropped `MLXLMCommon.downloadModel`. Download directly via
                // swift-transformers' `HubApi.snapshot` which gives us the same progress callback
                // and destination-directory contract. Empty `matching: []` downloads everything
                // in the repo (weights, tokenizer, config JSONs) — mirrors the old default.
                _ = try await hub.snapshot(from: repoId) { progress in
                    let fraction = progress.fractionCompleted
                    // One unstructured Task per tick: HubApi fires this frequently and the
                    // hops are unordered, so a tick from a download that has since been
                    // cancelled or superseded can still land after the slot changed hands.
                    // Re-checked against the slot's GENERATION, not the repo id — a
                    // Pause→Resume of the same model shares the id, so a name comparison
                    // would let the dead task drive the live download's progress bar. Weak
                    // self so a torn-down service isn't kept alive by a queue of pending ticks.
                    Task { @MainActor [weak self, generation] in
                        guard let self, self.downloadGeneration == generation else { return }
                        self.downloadProgress = fraction
                    }
                }

                // ⚠️ A cancel that lands BETWEEN files does not throw: `HubApi.snapshot`
                // returns `repoDestination` normally after its `if Task.isCancelled` check.
                // Classifying only on the thrown error therefore ran the SUCCESS handler for
                // a user-cancelled download — logging "finished successfully" and letting the
                // bridge see the partial repo as installed and record it COMPLETED.
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
                // Awaited: the DownloadManager bridge reads `installedModels` to classify the
                // terminal state, so a fire-and-forget refresh would race it and record a
                // successful pull as cancelled.
                await self.forceRefreshInstalledModelsAsync()
                // A pause whose `task.cancel()` lost the race to a completing snapshot leaves
                // the repo marked paused while it is in fact fully installed — the sidebar
                // would offer Resume and Discard for a finished model.
                if self.pausedRepoId == repoId {
                    self.logger.notice("[MLXSTORE] '\(repoId)' completed despite being paused (the cancel lost the race to the final file). CONSEQUENCE: clearing its paused marker so it presents as installed, not resumable.")
                    self.pausedRepoId = nil
                }
                self.finishTerminal(repoId: repoId, generation: generation, classification: "completed")

            } catch {
                // ⚠️ swift-transformers surfaces a cancel as `URLError(.cancelled)` — its
                // `Downloader.cancel()` broadcasts `.failed(URLError(.cancelled))` and
                // `HubFileDownloader` rethrows it verbatim — NOT as `CancellationError`.
                // The old `catch where error is CancellationError` arm was therefore dead,
                // and every user cancel was logged at fault level and persisted as
                // "Failed: cancelled". Key off the cancellation FLAG first, then either
                // error type, and log which classification won and why.
                if Task.isCancelled || Self.isCancellation(error) {
                    self.finishCancelled(repoId: repoId, generation: generation, reason: "\(error)")
                    return
                }
                self.finishFailed(repoId: repoId, generation: generation, error: error)
            }
        }
        return true
    }

    /// Terminal transition for a genuine failure. **Keeps every downloaded byte.**
    ///
    /// ⚠️ Timeout inventory D-27: this used to run `removePartialDownload`, so a 20 GB pull that
    /// failed at 95% — a dropped connection, a full disk — deleted the finished shards too and
    /// the user started again from zero. A failed record is already `isResumable`, so keeping the
    /// bytes is what makes its Resume button honest. The bytes are no longer invisible either: the
    /// failed row shows their size with Resume and Discard next to it, and the leftover scan
    /// counts them.
    func finishFailed(repoId: String, generation: UInt64, error: Error) {
        logger.fault("[MLXSTORE] Download of '\(repoId)' FAILED: \(error.localizedDescription).")
        // ⚠️ Gated on still holding the slot. Unguarded, a superseded task's failure wrote
        // `errorMessage` — which the bridge reads to classify the ACTIVE download, marking a
        // healthy running pull as failed.
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

    /// Clears the in-flight handles. ⚠️ Must run on EVERY terminal branch that still OWNS the
    /// slot — callers gate on `stillOwnsSlot(_:)` first.
    /// Previously only the cancel branch cleared `currentDownloadName`, and NOTHING ever
    /// cleared `downloadTask` — so after model A completed successfully, its stale handle
    /// made the next `downloadModel(B)` call `cancelDownload()`, which captured A's name
    /// and ran `removePartialDownload(repoId: A)` against the fully-installed model A.
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
        clearDownloadHandles()
        isDownloading = false
        refreshPartialDownloads()
    }

    /// Terminal transition for a user cancel. Clears `errorMessage` so the bridge
    /// classifies the record as cancelled rather than failed — mirrors `OllamaService`.
    func finishCancelled(repoId: String, generation: UInt64, reason: String) {
        guard stillOwnsSlot(generation, repoId: repoId, phase: "cancellation") else { return }
        logger.notice("[MLXSTORE] Download of '\(repoId)' CANCELLED (\(reason)). CONSEQUENCE: the record is marked cancelled, not failed; partial files are reclaimed by the cleanup pass.")
        clearDownloadHandles()
        downloadProgress = 0.0
        errorMessage = nil
        isDownloading = false
    }
    
    /// True while a cancelled download's partial files are being removed from disk.
    /// UI observes this to show a "Cleaning up…" indicator, since the scanner
    /// would otherwise misidentify the orphaned `config.json` as "Installed".
    /// The repo whose partial files are being reclaimed right now, or nil.
    ///
    /// ⚠️ Carries the identity deliberately. This was a bare `Bool`, and the views gating on it
    /// did not compare against their own model — so cancelling one download flipped EVERY
    /// visible MLX card to "Cleaning up…", including installed ones and unrelated available
    /// ones.
    var cancellingRepoId: String?

    /// True while `repoId`'s partial files are being removed. Views must pass their own
    /// identifier; a global "is any cleanup running" answer is what caused C1.
    func isCancellingDownload(repoId: String) -> Bool {
        cancellingRepoId == repoId
    }

    /// The repo the user paused, if any.
    ///
    /// Read by the `DownloadManager` bridge so the terminal transition is classified `.paused`
    /// rather than `.cancelled` — the distinction matters because cancelled discards the
    /// partial bytes and paused deliberately keeps them.
    var pausedRepoId: String?

    /// Stops the in-flight download but **keeps every downloaded byte**.
    ///
    /// This is the whole feature: swift-transformers already resumes from `.incomplete` files
    /// via a `Range: bytes=N-` header (`Downloader.incompleteFileSize(at:)`), so resuming is
    /// just re-entering `hub.snapshot`. The only thing that made resume impossible was that
    /// the sole stop control ran `removePartialDownload`, deleting the repo folder — and the
    /// `.incomplete` files live inside it, at `<repo>/.cache/huggingface/download/`.
    ///
    /// Returns false when there is nothing to pause.
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
        // ⚠️ Releasing the slot synchronously while the cancelled task is still unwinding is
        // what makes the generation bump mandatory: `resumeDownload` calls straight back into
        // `downloadModel`, so a new occupant can be installed before the old task's terminal
        // handler ever runs. Bumping here retires that handler — see `downloadGeneration`.
        downloadGeneration &+= 1
        clearDownloadHandles()
        downloadProgress = 0.0
        errorMessage = nil
        isDownloading = false
        // ⚠️ Deliberately no `removePartialDownload` here. That is the entire difference
        // between Pause and Cancel.
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

    /// Abandons a paused/interrupted download and reclaims its bytes.
    ///
    /// Returns false when the bytes were NOT reclaimed — the folder turned out to be a
    /// complete install, or the delete failed. The caller must not drop the history record
    /// on a false: that record is the only remaining handle on those bytes, and deleting it
    /// would strand them with no way back.
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

    /// Resolve the on-disk folder that HubApi writes into for a given repo id.
    ///
    /// ⚠️ Derived from the library's OWN resolver — never reconstruct this path by hand.
    /// `HubApi.localRepoLocation` is `downloadBase/<repo.type.rawValue>/<repo.id>`, and
    /// `RepoType.models.rawValue == "models"`, so the real layout carries a *doubled*
    /// component: `<modelsDirectory>/models/<author>/<name>`. This function previously
    /// rebuilt it as `<modelsDirectory>/<author>/<name>`, omitting that component, which
    /// made `removePartialDownload` a permanent silent no-op — every cancelled download
    /// leaked its partial folder, invisible to the UI because `hasWeights` then filtered
    /// it out of the installed scan. Delegating removes the drift entirely.
    ///
    /// Returns nil for malformed repo ids (anything that isn't exactly `author/name`).
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

    /// Remove a partial-download folder from disk so the scanner doesn't
    /// misidentify it as installed and so the bytes are reclaimed.
    /// Idempotent — safe to call before starting a fresh download too.
    ///
    /// This is a recursive delete of a potentially multi-gigabyte folder, so it refuses
    /// any repo that resolves to a COMPLETED install. The cleanup path is reachable with
    /// a stale repo id (see `cancelDownload`), and without this guard a stale id deletes
    /// a model the user successfully downloaded.
    /// Returns true when the repo's bytes are gone — either reclaimed here or never there.
    /// False means bytes remain on disk (refused as an install, or the delete failed), and
    /// the caller must keep whatever record still points at them.
    @discardableResult
    func removePartialDownload(repoId: String) -> Bool {
        guard let folder = partialDownloadFolder(for: repoId) else { return false }

        let target = folder.standardizedFileURL

        // Primary guard: ask the filesystem, not the in-memory list. `installedModels` is
        // populated by a debounced scan, so it can be stale exactly when it matters — and a
        // stale list would let this recursive delete run against a real install.
        //
        // ⚠️ The test is COMPLETENESS, not "has weights". `containsWeights` alone was the
        // guard here, and it made this function a no-op for every sharded repo: HubApi moves
        // each finished shard to its FINAL path before fetching the next, so an interrupted
        // sharded download is *precisely* a folder containing weights. Cancelling a 5-shard
        // pull half way therefore stranded gigabytes that no UI could reach — the exact leak
        // this function exists to prevent. The comment that "A2 covers that case" was wrong:
        // `shardCompleteness` only detects truncation, it never reclaims.
        if Self.isCompleteInstall(at: target) {
            logger.error("[MLXSTORE] REFUSING to remove '\(repoId)' at \(target.path) — it is a COMPLETE install, not partial-download residue. CONSEQUENCE: cleanup skipped (the safe outcome) and the model keeps its Delete button; a stale repo id reached the cleanup path and should be investigated.")
            return false
        }

        // Secondary guard: the scan may know it as installed under a different path.
        if let installed = installedModels.first(where: {
            // ⚠️ `sameLocationLexically`, not `==`. `localPath` comes from
            // `deletingLastPathComponent()` (trailing slash) while `target` comes from
            // `appendingPathComponent` (none), so URL equality misses — and missing HERE means
            // a recursive delete runs against a completed install.
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
    ///
    /// ⚠️ This is a NECESSARY but not sufficient condition for "installed" — one shard of
    /// four satisfies it. Anything deciding whether a folder is a real install (rather than
    /// residue safe to delete) must use `isCompleteInstall`.
    nonisolated static func containsWeights(at url: URL) -> Bool {
        !weightFiles(at: url).isEmpty
    }

    /// The single definition of "this directory is a usable install, not download residue".
    ///
    /// Composed from exactly the primitives `scanDisk` applies, so the two can never
    /// disagree — and that agreement is the invariant that matters: **anything this returns
    /// true for is surfaced in the installed list and therefore has a Delete button, and
    /// anything it returns false for is invisible residue that cleanup must be free to
    /// reclaim.** When these drifted apart, half-downloaded sharded repos fell into the gap:
    /// hidden from the list (so no Delete) *and* refused by cleanup (so never reclaimed).
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

    /// Whether every shard a sharded repo declares is actually present.
    ///
    /// ⚠️ `containsWeights` is satisfied by ONE weights file, which is not completeness.
    /// HubApi downloads files sequentially and moves each finished shard into place, so a
    /// pull killed after shard 2 of 4 leaves two valid `.safetensors` beside `config.json` —
    /// enough to pass the old check. The model then showed as Installed with a green badge
    /// across relaunches and failed only at load time with a raw framework shard-lookup
    /// error. Every sharded repo ships `model.safetensors.index.json` enumerating the full
    /// set; this consults it.
    ///
    /// Returns `(isComplete, expected, present)`. Unsharded repos (no index file) report
    /// complete — there is nothing to compare against, and `containsWeights` already
    /// established that weights exist.
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
            // No task, but a leftover name means a terminal branch didn't clean up.
            // Clear it here so the invariant "no task ⇒ no in-flight name" always holds:
            // a stale name is what let the old code schedule cleanup against the wrong repo.
            if !currentDownloadName.isEmpty {
                logger.error("[MLXSTORE] cancelDownload: no in-flight task but '\(self.currentDownloadName)' was still recorded as downloading — a terminal branch failed to clear it. CONSEQUENCE: clearing the stale name now; no cleanup is run, since the repo it names may be a completed install.")
                clearDownloadHandles()
            } else {
                logger.info("[MLXSTORE] cancelDownload: no in-flight task — nothing to cancel.")
            }
            return
        }
        // A completed download used to leave `downloadTask` populated and
        // `currentDownloadName` set, so this path could run with a STALE repo id and
        // schedule a cleanup against the previous, fully-installed model. The terminal
        // branches now clear both, but keep the guard: it is the last line of defence in
        // front of a recursive multi-gigabyte delete.
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

        // Wait for the in-flight task to observe cancellation (so it stops writing new
        // files), then reclaim the partial folder from disk.
        //
        // NOTE: the original rationale documented here — "otherwise the orphaned
        // config.json makes the scanner report the model as installed" — is wrong.
        // `refreshInstalledModels`' `hasWeights` check already filters a config-only
        // folder. The real justification is the disk leak: without this the partial
        // bytes stay forever, and because `hasWeights` hides the folder there is no
        // Delete button anywhere in the UI to reclaim them.
        Task { [weak self] in
            _ = await task.value
            await MainActor.run {
                guard let self else { return }

                // Corner case: user restarted the download for the SAME repo
                // while we were awaiting cleanup. Don't delete the folder the
                // new task is writing to, and don't stomp its state flags.
                let newTaskForSameRepo = self.downloadTask != nil && self.currentDownloadName == modelName

                if modelName.isEmpty {
                    self.logger.error("[MLXSTORE] Cancel cleanup skipped — the cancelled download had an empty repo id. CONSEQUENCE: its partial files (if any) are not reclaimed.")
                } else if newTaskForSameRepo {
                    self.logger.info("[MLXSTORE] Cancel cleanup skipped for '\(modelName)' — a new download for the same repo is already in flight and is writing to that folder.")
                } else {
                    self.removePartialDownload(repoId: modelName)
                }

                if self.downloadTask == nil {
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
    ///
    /// Each model is a multi-gigabyte tree, so this is a real walk — it must never run on the
    /// MainActor alongside the scan. Cancels any in-flight pass so rapid successive refreshes
    /// don't stack.
    private func recomputeInstalledSizes() {
        sizingTask?.cancel()
        let targets = installedModels.map { ($0.displayName, $0.localPath) }
        guard !targets.isEmpty else {
            installedSizeBytes = [:]
            return
        }
        // ⚠️ Hold the DETACHED task itself rather than an outer wrapper around it. A detached
        // task does not inherit cancellation, so with the walk buried inside
        // `await Task.detached { … }.value` the `sizingTask?.cancel()` above reached only the
        // wrapper: the loop's `Task.isCancelled` check was dead code and every superseded pass
        // ran to completion anyway. Published values stayed correct (the outer guard did work),
        // but rapid refreshes stacked full walks over a multi-gigabyte tree. Cancellation now
        // lands on the task actually doing the walking.
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

    /// Validates a folder the user picked and copies it into the store.
    ///
    /// ⚠️ Copies rather than symlinks or references-in-place, deliberately. An in-place
    /// reference would put a folder the app doesn't own inside `installedModels`, where
    /// `deleteModel` — a recursive delete — would happily remove the user's own directory, and
    /// where the partial-download cleanup reasons about paths it didn't create. Copying costs
    /// disk but keeps one clear ownership boundary.
    ///
    /// `repoId` names where it lands in the store, so an imported model is indistinguishable
    /// from a downloaded one afterwards.
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

        // ⚠️ Both the sizing walk and the copy run OFF the MainActor. `MLXModelService` is
        // `@MainActor`, so leaving them inline froze the whole UI for the duration of a
        // multi-gigabyte tree copy — Not Responding, with any concurrent download's progress
        // hops queued behind it. This is the same hang A15 moved the scan off the actor to
        // remove; import was written afterwards and inherited none of that. Note the size is
        // computed eagerly for the log line, so it must be hoisted too — a recursive walk
        // hidden inside a string interpolation is still a recursive walk.
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

    /// Free space on the volume that holds the models directory, in bytes.
    ///
    /// Uses `volumeAvailableCapacityForImportantUsageKey`, which is what macOS will actually
    /// let a user-initiated download consume — it accounts for purgeable space, unlike
    /// `volumeAvailableCapacityKey`. Nil when the volume can't be queried; callers treat that
    /// as "unknown" and proceed rather than blocking a download on a failed stat.
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

    /// Headroom kept free beyond the download itself.
    ///
    /// Models land on the boot volume, and macOS degrades badly (and sometimes
    /// unrecoverably) as the startup disk approaches full — swap, snapshots and app state all
    /// need room. 5 GB is enough to keep the system healthy while staying small relative to
    /// the multi-gigabyte downloads this guards.
    static let diskHeadroomBytes: Int64 = 5 * 1024 * 1024 * 1024

    /// Whether `requiredBytes` fits on the models volume with headroom to spare.
    /// Returns nil when free space is unknown — the caller should proceed, not block.
    func hasRoomForDownload(ofBytes requiredBytes: Int64) -> (fits: Bool, free: Int64)? {
        guard requiredBytes > 0,
              let free = Self.availableBytes(onVolumeContaining: modelsDirectory) else { return nil }
        return (free - requiredBytes >= Self.diskHeadroomBytes, free)
    }

    // MARK: - Partial downloads on disk

    /// A folder under the download root that is not a complete install — what a paused,
    /// interrupted, failed or crashed pull leaves behind. `refreshInstalledModels` deliberately
    /// filters these out of `installedModels`, so on their own they have no Delete button.
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

    /// Re-scans off the main actor and publishes the result. Called after every terminal
    /// transition, pause and reclaim. Overlapping calls coalesce: only the newest scan publishes.
    ///
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
                // Reclaimable means "not a complete install". A partially-sharded folder
                // IS reclaimable residue — it holds weights but is hidden from the installed
                // list, so it has no Delete button and this scan is the only thing that can
                // account for it. Gating on `containsWeights` skipped exactly those folders,
                // which is how they became invisible AND unreclaimable at the same time.
                // An empty folder is not worth reporting.
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
    ///
    /// Returns false when the delete was refused or failed; the caller should surface that.
    /// Previously this ran unconditionally and silently: it did not check whether the model
    /// was currently LOADED (MLXService would keep serving it, and a lazy reload would try to
    /// read a path that no longer exists), left the `DownloadRecord` claiming "completed", and
    /// swallowed any failure into an `errorMessage` nothing rendered.
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
        if await MLXService.shared.isModelLoaded(at: path) {
            logger.error("[MLXSTORE] REFUSING to delete '\(item.displayName)' — it is currently loaded in MLXService. CONSEQUENCE: delete skipped; unload or switch models first, otherwise a lazy reload would target a path that no longer exists.")
            errorMessage = "\(item.displayName) is currently loaded. Switch to another model before deleting it."
            return false
        }

        do {
            // ⚠️ Deliberately INLINE, unlike the sizing walk above and unlike import's copy.
            // The two guards immediately above are `await`s, so every suspension added between
            // them and this line widens the window in which a generation can start and then
            // read weights that are being unlinked underneath it. An APFS recursive unlink is
            // cheap where a recursive size walk is not, so the trade favours keeping the
            // guarded region tight. Revisit only with a real hitch measurement.
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
    ///
    /// ⚠️ Without this the setting outlived the model: every later compaction logged
    /// `IC context-window lookup MISSED`, fell back to a 4096-token window, and still reported an
    /// IC model as selected — so synthesis and compaction kept being planned around a model that
    /// could not load. Checked AFTER the refresh and through `installedModel(named:)` (the same
    /// resolution every IC reader uses), so a selection another installed copy still satisfies is
    /// left alone; only one that no longer resolves is cleared.
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
///
/// Every HF call used to discard its `URLResponse` with `let (data, _) = …`, so a 429, 401,
/// 500 or Cloudflare interstitial all arrived as a *successful* `data(from:)` whose body
/// merely failed to decode. Rate-limited, offline, gated and genuinely-empty were therefore
/// indistinguishable — all four rendered "No models found", and the log said "the data
/// couldn't be read because it isn't in the correct format", pointing a maintainer at a
/// schema bug rather than at throttling.
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

    /// One bounded retry with jittered backoff. Deliberately small: the failures worth
    /// retrying here are transient 5xx and dropped connections, and retrying a 429 is what
    /// deepens a rate limit — so `.rateLimited` is never retried, only surfaced.
    /// - Parameter cachePolicy: defaults to the policy every listing call wants.
    ///   ⚠️ Overridden ONLY by the token check: `URLCache` keys on the URL, NOT on the
    ///   `Authorization` header, so a cached 200 for a shared URL can answer a request made with
    ///   a DIFFERENT credential — which would let a revoked token verify as valid.
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
        // The list endpoint's top-30 payload is highly cacheable; let URLSession revalidate
        // instead of re-downloading an identical body every time the store opens.
        //
        // ⚠️ BUT AN AUTHENTICATED RESPONSE MAY NOT SHARE A URL-KEYED CACHE. `URLCache` ignores the
        // `Authorization` header, so an anonymous 200 cached while browsing signed-out can answer
        // the very next signed-in request — and vice versa. The "Add Token…" flow makes exactly
        // that sequence routine: hit a 401, add a token, and `refresh()` re-requests the listing
        // URL that was just cached anonymously, so the user adds a working token and sees the
        // same signed-out results. The caller's policy still wins when there is no token.
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

    /// Parsed form used to make the "Recent" sort meaningful for remote results.
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
        /// Stored tensor-element count. ⚠️ For a quantized repo this is NOT the logical
        /// parameter count — weights are packed — so it is presented as "tensor elements"
        /// rather than dressed up as a parameter count it isn't.
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
