//
//  MLXModelStoreViewModel.swift
//  Devgentic
//
//  Created by Raj Singh on 04/02/26.
//

import Foundation
import SwiftUI

@Observable @MainActor
class MLXModelStoreViewModel {

    @ObservationIgnored private let logger = DGLogger(category: "MLXModelStore")

    let filterForTools: Bool

    // MARK: - Inputs (View Actions)
    var searchText: String = "" {
        didSet {
            searchDebounceTask?.cancel()
            searchDebounceTask = Task { [weak self] in
                try? await Task.sleep(for: .milliseconds(500))
                guard !Task.isCancelled, let self, self.isRemoteSearchEnabled else { return }
                // ⚠️ register A43 — `.filterChanged`, so the Installed tab re-filters without
                // re-walking the disk. Remote categories still issue their fetch: for those the
                // search text is a QUERY the server answers, not a client-side filter.
                self.refreshCategoryData(reason: .filterChanged)
            }
        }
    }
    var selectedCategory: StoreCategory = .all {
        didSet {
            if selectedCategory != oldValue {
                // ⚠️ Drop the quantization narrowing on a category switch. It was chosen
                // against a different result set, and the picker that undoes it only renders
                // when the NEW set offers more than one quantization — so carrying it over
                // could present an empty grid with no control to clear it, directly
                // contradicting the "3 installed · 12.4 GB" summary above it. This view model
                // is cached by `DestinationCoordinator` for the app lifetime, so leaving the
                // store did not reset it either. A filter the user cannot see is a filter
                // that enforces rather than describes.
                if let cleared = quantizationFilter {
                    logger.info("[MLXSTORE] Cleared the \(cleared.rawValue)-bit quantization filter on switching to the \(self.selectedCategory.rawValue) tab. CONSEQUENCE: the new tab shows all its models; the filter was chosen against the previous result set.")
                    quantizationFilter = nil
                }
                refreshCategoryData()
            }
        }
    }

    /// Toggle to switch between filtering local results or fetching new results from the server
    var isRemoteSearchEnabled: Bool = true {
        didSet {
            refreshCategoryData()
        }
    }

    /// Sorting preference
    var sortOption: SortOption = .popularity {
        didSet {
            // Re-apply filters and sort when option changes
            applyFilterAndSort()
        }
    }

    // MARK: - Outputs (View State)
    var displayedModels: [MLXDisplayModel] = []
    var isLoading: Bool = false

    /// Total on-disk size of installed models, formatted, or nil while the background
    /// sizing pass is still running.
    var installedStorageSummary: String? {
        guard let total = service.totalInstalledBytes, total > 0 else { return nil }
        return ByteCountFormatter.string(fromByteCount: total, countStyle: .file)
    }

    /// How many models are installed, irrespective of any active filter.
    var installedCount: Int { service.installedModels.count }

    /// True when the Installed tab is showing a filtered subset.
    var isFilteringInstalled: Bool {
        selectedCategory == .installed && !searchText.isEmpty
    }

    /// Update status for an installed card, or nil if no check has run for it.
    func updateStatus(for model: MLXDisplayModel) -> MLXModelRevision.UpdateStatus? {
        service.updateStatus[model.id]
    }

    var isCheckingForUpdates: Bool { service.isCheckingForUpdates }

    func checkForUpdates() {
        Task { await service.checkForModelUpdates() }
    }

    /// The on-disk item behind a card, when it is installed.
    func installedItem(for model: MLXDisplayModel) -> MLXModelItem? {
        service.installedModel(named: model.id)
    }

    /// Formatted size of one installed model, for the delete confirmation.
    func installedSize(of model: MLXDisplayModel) -> String? {
        guard let bytes = service.installedSizeBytes[model.id], bytes > 0 else { return nil }
        return ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }

    /// The last download failure, surfaced as a dismissible banner. A failed MLX download
    /// used to revert the card to a plain Download button with the reason shown nowhere in
    /// the store at all — `MLXModelService.errorMessage` had no reader.
    var downloadError: String?

    /// Why the last remote fetch failed. Mirrored from the service so the grid can explain
    /// itself: rate-limited, offline, gated and genuinely-empty previously all rendered the
    /// same "No models found" dead end with a reload button that re-provoked the failure.
    var loadError: HFRequestError?

    /// The sort the user had before the Installed tab forced `.recent`, so it can be put back.
    @ObservationIgnored private var sortBeforeInstalledTab: SortOption?

    // Pagination State
    @ObservationIgnored private var currentPage = 0
    @ObservationIgnored private let pageSize = 30

    // Download State
    var isDownloading: Bool = false
    var currentDownloadName: String = ""

    // MARK: - Dependencies
    @ObservationIgnored private let service = MLXModelService.shared
    @ObservationIgnored private var searchDebounceTask: Task<Void, Never>?
    
    // MARK: - Definitions
    
    enum StoreCategory: String, CaseIterable, Identifiable {
        case installed = "Installed"
        /// Hand-checked starting points. Default tab on a first run, when the raw popularity
        /// listing is at its least helpful. See `CuratedMLXCatalog`.
        case recommended = "Recommended"
        case all = "All"
        case reasoning = "Reasoning"
        case toolUse = "Tool Use"
        case coding = "Coding"
        case vision = "Vision"
        
        var id: String { rawValue }
        
            /// User-facing name. ⚠️ Separate from `rawValue` on purpose: `Text(x.rawValue)` binds to
            /// the non-localizing `StringProtocol` overload, so every rawValue-sourced label was
            /// invisible to the String Catalog extractor and would have shipped untranslated inside
            /// otherwise-translated chrome. `rawValue` stays for persistence and logging only.
        var localizedTitle: LocalizedStringKey {
            switch self {
            case .installed:   return "Installed"
            case .recommended: return "Recommended"
            case .all:         return "All"
            case .reasoning: return "Reasoning"
            case .toolUse:   return "Tool Use"
            case .coding:    return "Coding"
            case .vision:    return "Vision"
            }
        }

        var icon: String {
            switch self {
            case .recommended: return "sparkles"
            case .installed: return "externaldrive.fill.badge.checkmark"
            case .all: return "square.grid.2x2.fill"
            case .reasoning: return "brain.head.profile"
            case .toolUse: return "hammer.fill"
            case .coding: return "chevron.left.forwardslash.chevron.right"
            case .vision: return "eye.fill"
            }
        }
        
        /// Client-side capability to filter on for this category.
        /// We deliberately avoid forwarding capability tags to the HF filter because
        /// `filter=mlx,tool-use` is ANDed server-side — which eliminates most popular
        /// MLX models (Qwen2.5, Llama-3.x, etc.) since their authors rarely add the
        /// `tool-use` / `reasoning` HF tag. Instead, we fetch all MLX models and
        /// classify via `MLXDisplayModel.capabilities` (set by `classifyCapabilities`).
        var clientCapability: MLXModelCapability? {
            switch self {
            case .all, .installed, .recommended: return nil
            case .reasoning: return .reasoning
            case .toolUse: return .toolUse
            case .coding: return .coding
            case .vision: return .vision
            }
        }
    }
    
    /// ⚠️ Every category stays available even in tool-filtering mode.
    ///
    /// This used to return `[.installed, .toolUse]`, deleting the "All" tab — so a model the
    /// `classifyCapabilities` name heuristic failed to tag had NO browse path at all. Combined
    /// with the hard filter below and the picker's own filter, a heuristic false negative
    /// became a product lockout with no override: the user could not select or download their
    /// own tool-capable model in an Agent profile. Classification may label and group; it must
    /// never gate.
    var availableCategories: [StoreCategory] {
        StoreCategory.allCases
    }

    /// Show only this quantization, or nil for all. The store previously had no way to narrow
    /// to 4-bit even though the listing routinely returns the same model at four different
    /// quantizations as visually identical cards.
    var quantizationFilter: MLXQuantization? {
        didSet {
            if quantizationFilter != oldValue { applyFilterAndSort() }
        }
    }

    /// Quantizations actually present in the current results — no point offering a 2-bit
    /// filter for a page that has none.
    var availableQuantizations: [MLXQuantization] {
        let source = selectedCategory == .installed
            ? service.installedModels.compactMap { MLXQuantization.parse(fromRepoId: $0.displayName) }
            : service.availableModels.compactMap(\.quantization)
        var present = Set(source)
        // ⚠️ Always offer the ACTIVE filter, even when nothing in the current results matches
        // it. Otherwise the Picker has no tag for its own selection, renders blank, and the
        // user cannot clear the very filter that emptied the grid.
        if let quantizationFilter { present.insert(quantizationFilter) }
        return Array(present).sorted()
    }

    /// User-facing switch for the tool-capability filter. Defaults on so Agent profiles still
    /// lead with tool-capable models, but the user can always see everything — the heuristic
    /// is advice, not an authority.
    var showToolCapableOnly: Bool = true {
        didSet {
            if showToolCapableOnly != oldValue { applyFilterAndSort() }
        }
    }
    
    enum SortOption: String, CaseIterable, Identifiable {
        case popularity = "Popularity"
        case recent = "Recent"
        case sizeSmallest = "Size (Smallest)"
        case sizeLargest = "Size (Largest)"

        var id: String { rawValue }

        var localizedTitle: LocalizedStringKey {
            switch self {
            case .popularity:   return "Popularity"
            case .recent:       return "Recent"
            case .sizeSmallest: return "Size (Smallest)"
            case .sizeLargest:  return "Size (Largest)"
            }
        }

        var icon: String {
            switch self {
            case .popularity: return "arrow.down.circle"
            case .recent: return "clock.arrow.circlepath"
            case .sizeSmallest: return "arrow.up.arrow.down.square"
            case .sizeLargest: return "arrow.up.arrow.down.square.fill"
            }
        }
    }
    
    // MARK: - Initialization

    @ObservationIgnored private var serviceObserver: ObservationStream?

    init(filterForTools: Bool = false) {
        self.filterForTools = filterForTools
        // A first run — no models on disk — lands on the curated list. That is exactly when
        // the raw HuggingFace popularity listing is least helpful: its top results included
        // speech-recognition models badged "Chat" and a 657 GB repo.
        let hasModels = !MLXModelService.shared.installedModels.isEmpty
        self.selectedCategory = hasModels ? (filterForTools ? .installed : .all) : .recommended
        setupObserver()
        refreshCategoryData()
    }

    deinit {
        // Releasing `serviceObserver` triggers `ObservationStream.deinit`,
        // which flips its own `isActive` flag so any in-flight onChange task
        // short-circuits instead of writing to a zombie self.
    }

    /// Bridges MLXModelService (@Observable) changes into this @Observable view model.
    private func setupObserver() {
        serviceObserver = ObservationStream(
            track: { [weak self] in
                guard let self else { return }
                _ = self.service.availableModels
                _ = self.service.installedModels
                _ = self.service.installedSizeBytes
                _ = self.service.updateStatus
                _ = self.service.isCheckingForUpdates
                _ = self.service.isLoadingRemoteModels
                _ = self.service.remoteLoadError
                _ = self.service.isDownloading
                // ⚠️ `downloadProgress` is deliberately NOT tracked here. It ticks
                // continuously during a pull, and this observer's `onChange` runs
                // `applyFilterAndSort()` — a full re-filter and re-sort of the entire grid
                // per tick. The progress UI reads `DownloadManager`'s per-record state
                // directly, so nothing in this view model needs the value.
                _ = self.service.currentDownloadName
                _ = self.service.errorMessage
            },
            onChange: { [weak self] in
                guard let self else { return }
                // Mirror state from service
                self.isLoading = self.service.isLoadingRemoteModels
                self.loadError = self.service.remoteLoadError
                self.isDownloading = self.service.isDownloading
                self.currentDownloadName = self.service.currentDownloadName
                if let message = self.service.errorMessage, !message.isEmpty {
                    self.downloadError = message
                }
                self.applyFilterAndSort()
            }
        )
    }
    
    // MARK: - Logic

    /// Why `refreshCategoryData` is being called. Register A43.
    ///
    /// ⚠️ The Installed tab's forced disk scan is correct for a Refresh click, a tab switch and
    /// first load — all explicit requests for current data — and wrong for a keystroke in the
    /// filter field. `force: true` bypasses both the 2 s debounce AND the in-flight coalescing
    /// (a forcing caller joins the running walk and then deliberately starts a new one), so every
    /// typing pause guaranteed a fresh recursive `FileManager.enumerator` walk plus a full
    /// cognitive-profile rebuild — and none of it could change the result, because filtering the
    /// Installed tab happens entirely client-side in `filterAndSortModels`.
    private enum RefreshReason {
        /// Refresh button, tab switch, first load — re-read the disk.
        case userRequest
        /// A filter keystroke. The data is already current; only the projection changes.
        case filterChanged
    }

    private func refreshCategoryData(reason: RefreshReason = .userRequest) {
        currentPage = 0

        if selectedCategory == .recommended {
            logger.info("Refresh: category=recommended — serving \(CuratedMLXCatalog.models.count) curated model(s) locally")
            applyFilterAndSort()
            // Sizes still come from HuggingFace so the cards show real numbers and the RAM
            // verdict has a denominator; one bounded fetch, not the 30-per-page fan-out.
            Task { await service.fetchSizesForCuratedModels() }
        } else if selectedCategory == .installed {
            // Default the Installed tab to most-recent-first, remembering what to restore.
            // This used to flip the sort and never put it back, so returning to All left the
            // user on "Recent" — which is meaningless for remote results and, before the
            // comparator was made total, reshuffled the grid on every size-update tick.
            if sortOption == .popularity {
                sortBeforeInstalledTab = sortOption
                sortOption = .recent
            }
            // Force: this path is reached from the Refresh button and from switching to the
            // Installed tab, both of which are explicit user requests for current data. The
            // debounce exists to absorb the init + onAppear double-fire, not to ignore the
            // user. (The comment here used to say the window was <2s while the constant was
            // 30s — a refresh could silently do nothing for half a minute.)
            //
            // ⚠️ register A43 — but NOT for a filter keystroke, which this comment predates and
            // was never written for. Filtering is client-side, so the scan could not change what
            // the user sees; it was pure I/O per typing pause, and worse on a custom models
            // directory pointed at an external or network volume.
            if reason == .userRequest {
                logger.info("Refresh: category=installed — scanning local models")
                service.forceRefreshInstalledModels()
            } else {
                logger.info("Refresh: category=installed — filter changed, re-filtering without a disk scan")
            }
            // The observer only fires when the model list actually CHANGED, so re-filter
            // unconditionally to render the installed cards for this tab immediately.
            applyFilterAndSort()
        } else {
            if let restore = sortBeforeInstalledTab {
                sortOption = restore
                sortBeforeInstalledTab = nil
            }
            let search = (isRemoteSearchEnabled && !searchText.isEmpty) ? searchText : nil
            logger.info("Refresh: category=\(self.selectedCategory.rawValue) search=\(search ?? "<none>") clientCapability=\(self.selectedCategory.clientCapability?.rawValue ?? "<none>")")

            // Clear stale cards from the prior tab so the loading UI shows
            // instead of (incorrectly) rendering the previous category's
            // models until the remote fetch completes.
            //
            // `isLoading` is set here, synchronously, alongside the clear. The service sets
            // its own flag two actor hops later, so for those two hops the grid was empty
            // AND not-loading — which is exactly the "No models found" empty state. Every
            // category switch flashed it.
            isLoading = true
            loadError = nil
            displayedModels = []

            Task { [category = selectedCategory.rawValue] in
                await service.fetchRemoteModels(
                    limit: pageSize,
                    offset: 0,
                    tags: nil,
                    search: search,
                    append: false,
                    category: category
                )
            }
        }
    }
    
    /// Triggered manually or by publisher changes to update the displayed list
    private func applyFilterAndSort() {
        displayedModels = filterAndSortModels(
            remote: service.availableModels,
            local: service.installedModels,
            query: searchText,
            category: selectedCategory,
            sort: sortOption
        )
    }
    
    func loadMore() {
        guard selectedCategory != .installed else { return }

        currentPage += 1
        let offset = currentPage * pageSize
        let search = (isRemoteSearchEnabled && !searchText.isEmpty) ? searchText : nil
        logger.info("LoadMore: page=\(self.currentPage) offset=\(offset) search=\(search ?? "<none>") currentAvailable=\(self.service.availableModels.count)")

        Task { [category = selectedCategory.rawValue] in
            await service.fetchRemoteModels(
                limit: pageSize,
                offset: offset,
                tags: nil,
                search: search,
                append: true,
                category: category
            )
        }
    }
    
    private func filterAndSortModels(
        remote: [MLXDisplayModel],
        local: [MLXModelItem],
        query: String,
        category: StoreCategory,
        sort: SortOption
    ) -> [MLXDisplayModel] {
        
        var sourceModels: [MLXDisplayModel]

        // 1. Select Source
        if category == .recommended {
            let ramGB = Int(SystemHardwareProfiler.shared.profile.totalRAM / (1024 * 1024 * 1024))
            sourceModels = CuratedMLXCatalog.recommended(forSystemRAMGB: ramGB).map { curated in
                MLXDisplayModel(
                    id: curated.id,
                    size: service.modelSizes[curated.id] ?? curated.formattedSize,
                    sizeBytes: service.modelSizeBytes[curated.id] ?? curated.approximateBytes,
                    quantization: MLXQuantization.parse(fromRepoId: curated.id),
                    capabilities: service.classifyCapabilities(tags: [], pipeline: nil, id: curated.id),
                    tags: ["Recommended"],
                    downloads: 0,
                    likes: 0,
                    description: curated.rationale
                )
            }
        } else if category == .installed {
            sourceModels = local.map { item in
                
                // Use cached profile from MLXModelService instead of re-parsing files
                let profile = service.cachedCognitiveProfile(for: item)
                var caps: Set<MLXModelCapability> = []
                
                if profile.capability != .none {
                    caps.insert(.toolUse)
                }
                
                let lowerId = item.displayName.lowercased()
                // Reasoning badge: check the centralized heuristics (catches qwq, magistral,
                // gpt-oss, o1/o3/o4 families) plus the generic "reasoning" / "chain-of-thought"
                // keywords users/publishers sometimes add to model names.
                if ModelCapabilityHeuristics.isReasoningOnly(nameCandidates: item.displayName) ||
                   lowerId.contains("reasoning") || lowerId.contains("chain-of-thought") {
                    caps.insert(.reasoning)
                }
                if lowerId.contains("coder") || lowerId.contains("code") || lowerId.contains("codellama") || lowerId.contains("qwen2.5-coder") {
                    caps.insert(.coding)
                }
                if lowerId.contains("vision") || lowerId.contains("vl") || lowerId.contains("llava") || lowerId.contains("pixtral") || lowerId.contains("qwen2-vl") {
                    caps.insert(.vision)
                }
                
                // Fallback to text generation if nothing matches
                if caps.isEmpty {
                    caps.insert(.textGeneration)
                }
                
                // Installed models used to be mapped with `size: nil`, so the Installed tab
                // showed no disk figure, suppressed the fit badge, and made "Sort by size" a
                // silent no-op there. Sizes arrive from the background sizing pass.
                let bytes = service.installedSizeBytes[item.displayName]
                return MLXDisplayModel(
                    id: item.displayName,
                    size: bytes.map { ByteCountFormatter.string(fromByteCount: $0, countStyle: .file) },
                    sizeBytes: bytes,
                    quantization: MLXQuantization.parse(fromRepoId: item.displayName),
                    capabilities: caps,
                    tags: ["Installed"],
                    downloads: 0,
                    likes: 0,
                    description: item.localPath.path,
                    createdAt: item.createdAt
                )
            }
            
            // Soft filter only, and only while the user leaves the toggle on. `capabilities`
            // here comes from substring matching over the model id, so a false negative is
            // routine for any newly-released family, re-quantized upload or personal
            // fine-tune. Hiding those outright removed the only way to reach them.
            if filterForTools && showToolCapableOnly {
                sourceModels = sourceModels.filter { $0.capabilities.contains(.toolUse) }
            }
            
        } else {
            // Only use the remote payload if it was actually fetched for this category.
            guard service.availableModelsCategory == nil
                    || service.availableModelsCategory == category.rawValue else {
                return []
            }
            sourceModels = remote

            // Filter remote results by category capability (client-side).
            // HF's server-side tag filter is too restrictive (authors rarely add
            // `tool-use`/`reasoning` tags), so we rely on `classifyCapabilities`
            // heuristics baked into `MLXDisplayModel.capabilities`.
            // NOTE: no log here — `applyFilterAndSort` is invoked on every
            // observer tick (including per-model size updates), so logging
            // would emit 30+ lines per fetch.
            if let cap = category.clientCapability {
                sourceModels = sourceModels.filter { $0.capabilities.contains(cap) }
            }
        }

        // 2. Filter by quantization when the user has narrowed to one.
        if let quantizationFilter {
            sourceModels = sourceModels.filter { $0.quantization == quantizationFilter }
        }

        // 3. Filter by search text.
        //
        // The `.installed` tab filters unconditionally: there is no HF query behind it, so
        // gating on `isRemoteSearchEnabled` (which is initialised to true and never assigned
        // anywhere in the repo) made the entire branch dead code. The field's own placeholder
        // reads "Filter installed models…" and typing in it did nothing.
        let filtersLocally = category == .installed || !isRemoteSearchEnabled
        if !query.isEmpty && filtersLocally {
            sourceModels = sourceModels.filter { model in
                model.displayName.localizedCaseInsensitiveContains(query) ||
                (model.description?.localizedCaseInsensitiveContains(query) ?? false)
            }
        }
        
        // 3. Sort.
        //
        // Every comparator below tie-breaks down to `id`. Swift's `sort` is introsort and is
        // NOT stable, so a comparator that returns false for every pair (which "Recent" did
        // for remote models, since none carried a date) permutes the array arbitrarily —
        // cards visibly jumped under the cursor on each of the ~30 size-update ticks.
        // The curated list is ordered deliberately — what this machine can run, smallest
        // first — so a popularity sort (every entry has 0 downloads) would scramble it.
        if category == .recommended { return sourceModels }

        switch sort {
        case .popularity:
            // The HF query is already `sort=downloads&direction=-1`, but appended pages and
            // locally-sourced rows are not, so make the order explicit rather than implied.
            sourceModels.sort { lhs, rhs in
                lhs.downloads == rhs.downloads ? lhs.id < rhs.id : lhs.downloads > rhs.downloads
            }

        case .recent:
            sourceModels.sort { lhs, rhs in
                let l = lhs.createdAt, r = rhs.createdAt
                if let l, let r, l != r { return l > r }
                if (l == nil) != (r == nil) { return l != nil }  // dated entries first
                return lhs.id < rhs.id
            }

        case .sizeSmallest:
            sourceModels.sort { lhs, rhs in
                sortableBytes(lhs) == sortableBytes(rhs)
                    ? lhs.id < rhs.id
                    : sortableBytes(lhs) < sortableBytes(rhs)
            }

        case .sizeLargest:
            sourceModels.sort { lhs, rhs in
                sortableBytes(lhs) == sortableBytes(rhs)
                    ? lhs.id < rhs.id
                    : sortableBytes(lhs) > sortableBytes(rhs)
            }
        }

        return sourceModels
    }

    /// Sort key for size. Models whose size hasn't loaded sort last in both directions
    /// rather than pretending to be 0 bytes (which put every unsized card at the top of
    /// "Smallest").
    private func sortableBytes(_ model: MLXDisplayModel) -> Int64 {
        model.sizeBytes ?? Int64.max
    }
    
    
    // MARK: - Actions
    
    /// ⚠️ This used to fall back to `installed.displayName.contains(model.displayName)`.
    /// `model.displayName` is the bare name with the org stripped, so the substring test
    /// matched any installed model that merely *contained* it — a different quantization,
    /// a suffixed variant (`…-4bit` inside `…-4bit-DWQ`), or another org entirely. The card
    /// then rendered a green "Installed" capsule, and since the Download affordance only
    /// exists in the `else` branch there was no way to download that model at all.
    /// Goes through the shared comparator now, which never uses substrings.
    func isInstalled(_ model: MLXDisplayModel) -> Bool {
        service.isInstalled(repoId: model.id)
    }
    
    func downloadModel(_ model: MLXDisplayModel) {
        service.downloadModel(repoId: model.id)
    }
    
    func deleteModel(_ model: MLXDisplayModel) {
        guard let item = service.installedModel(named: model.id) else {
            // Was a silent no-op: the strict `==` lookup here disagreed with the lenient
            // `isInstalled` used to render the card, so a card could offer Delete on a model
            // this lookup could not find, and nothing happened or was logged.
            logger.error("[MLXSTORE] Delete requested for '\(model.id)' but it is not in the installed list (\(self.service.installedModels.count) model(s)). CONSEQUENCE: nothing was deleted and the card still shows it as installed — the list is stale, refresh the store.")
            return
        }
        Task { await service.deleteModel(item) }
    }
    
    func cancelDownload() {
        service.cancelDownload()
    }
    
    func refresh() {
        refreshCategoryData()
    }

    /// Clears the banner and the service flag together. Leaving `errorMessage` set would make
    /// the DownloadManager bridge classify the NEXT download's terminal state as failed.
    func dismissDownloadError() {
        downloadError = nil
        service.errorMessage = nil
    }
}
