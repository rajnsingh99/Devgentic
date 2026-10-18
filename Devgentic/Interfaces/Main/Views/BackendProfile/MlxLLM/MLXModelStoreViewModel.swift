// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
//
//  MLXModelStoreViewModel.swift
//  Devgentic
//
//  Created by Raj Singh.
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
            guard searchText != oldValue else { return }
            searchDebounceTask?.cancel()
            searchDebounceTask = Task { [weak self] in
                try? await Task.sleep(for: .milliseconds(500))
                guard !Task.isCancelled, let self else { return }
                self.applySearchChange()
            }
        }
    }

    /// True while the user is on `.all` only because a query moved them off `.recommended`.
    /// Clearing the query puts them back; picking any tab themselves ends the arrangement.
    @ObservationIgnored private var didAutoLeaveRecommended = false

    /// Set while THIS type assigns `selectedCategory`, so the `didSet` can tell an automatic
    /// switch from one the user made.
    @ObservationIgnored private var isAutoSwitchingCategory = false
    var selectedCategory: StoreCategory = .all {
        didSet {
            if selectedCategory != oldValue {
                // A tab the user picked ends the auto-switch, so clearing the search box does not return to Recommended.
                // Cancels any pending debounced search so it cannot route on the new category.
                if !isAutoSwitchingCategory {
                    didAutoLeaveRecommended = false
                    cancelPendingSearch()
                }
                // Drops the quantization filter on a user-picked category switch; the picker may not render for the new result set.
                // Not applied during the automatic switch, where the picker always renders.
                if let cleared = quantizationFilter, !isAutoSwitchingCategory {
                    logger.info("[MLXSTORE] Cleared the \(cleared.rawValue)-bit quantization filter on switching to the \(self.selectedCategory.rawValue) tab. CONSEQUENCE: the new tab shows all its models; the filter was chosen against the previous result set.")
                    // Suppresses this clear's own refresh; the category refresh below already re-queries.
                    isClearingQuantizationForCategorySwitch = true
                    quantizationFilter = nil
                    isClearingQuantizationForCategorySwitch = false
                }
                refreshCategoryData()
            }
        }
    }

    /// Sorting preference
    var sortOption: SortOption = .popularity {
        didSet {
            // Re-apply filters and sort when option changes
            applyFilterAndSort()
            maybeRefetchForServerSort(from: oldValue)
        }
    }

    /// True only while `refreshCategoryData` is putting `sortBeforeInstalledTab` back, so the
    /// `sortOption` didSet can tell that restore from a choice the user made. Same reason
    /// `isAutoSwitchingCategory` exists for `selectedCategory`.
    @ObservationIgnored private var isRestoringSort = false

    /// The HuggingFace `sort=` field the models currently in `service.availableModels` were
    /// ranked by. `loadMore` pages against THIS, not against `sortOption`, because a `skip`
    /// offset is only meaningful within the ranking that produced the earlier pages.
    @ObservationIgnored private var lastFetchedSort = MLXModelService.defaultSortField

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

    /// The last download failure, surfaced as a dismissible banner.
    var downloadError: String?

    /// Why the last remote fetch failed, mirrored from the service so the grid can explain an empty result.
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
        case toolUse = "Tool Use"
        case vision = "Vision"
        
        var id: String { rawValue }
        
        /// User-facing name of the category.
        /// Separate from `rawValue` so the label is localizable; `rawValue` is for persistence and logging only.
        var localizedTitle: LocalizedStringKey {
            switch self {
            case .installed:   return "Installed"
            case .recommended: return "Recommended"
            case .all:         return "All"
            case .toolUse:   return "Tool Use"
            case .vision:    return "Vision"
            }
        }

        var icon: String {
            switch self {
            case .recommended: return "sparkles"
            case .installed: return "externaldrive.fill.badge.checkmark"
            case .all: return "square.grid.2x2.fill"
            case .toolUse: return "hammer.fill"
            case .vision: return "eye.fill"
            }
        }
        
        /// Client-side capability to filter on for this category.
        /// Capability tags are not forwarded to the HuggingFace filter: it ANDs them server-side and hides most models.
        /// Models are fetched unfiltered and classified via `MLXDisplayModel.capabilities`.
        var clientCapability: MLXModelCapability? {
            switch self {
            case .all, .installed, .recommended: return nil
            case .toolUse: return .toolUse
            case .vision: return .vision
            }
        }
    }
    
    /// Every category stays available, including in tool-filtering mode.
    /// Classification may label and group models; it never gates browsing.
    var availableCategories: [StoreCategory] {
        StoreCategory.allCases
    }

    /// Show only this quantization, or nil for all.
    /// On a server-backed tab this is part of the query, not a client-side filter; see `remoteQuery`.
    var quantizationFilter: MLXQuantization? {
        didSet {
            guard quantizationFilter != oldValue else { return }
            // A category switch clears this and then refreshes for the new tab itself; without
            // this guard that clear fires a second, immediately-superseded request.
            guard !isClearingQuantizationForCategorySwitch else { return }
            if selectedCategory == .installed || selectedCategory == .recommended {
                // Fixed local sets with no server behind them — the client filter IS the answer.
                applyFilterAndSort()
            } else {
                logger.info("[MLXSTORE] Quantization → \(self.quantizationFilter?.searchToken ?? "any") on the \(self.selectedCategory.rawValue) tab. CONSEQUENCE: re-querying HuggingFace with the bit-width in the search term; narrowing the current 30-row page client-side left only the few of that width that happened to land on it.")
                // This re-query supersedes any pending one, so a width picked right after a keystroke sends a single request.
                cancelPendingSearch()
                refreshCategoryData(reason: .filterChanged)
            }
        }
    }

    /// Set while `selectedCategory`'s didSet clears the quantization filter, so that clear does
    /// not issue a fetch on top of the one the category switch is already about to make.
    @ObservationIgnored private var isClearingQuantizationForCategorySwitch = false

    /// The exact `search=` term the next HuggingFace listing request carries.
    /// Every remote call site reads this property so later pages keep the narrowing of page 1.
    var remoteSearchQuery: String? {
        Self.remoteQuery(search: searchText, quantization: quantizationFilter)
    }

    // Why: HuggingFace ANDs search tokens against the repo id, so contradicting or duplicate widths return zero rows.
    /// Folds the search box and the quantization picker into one HuggingFace `search=` term.
    /// A bare bit-width typed by the user is dropped in favour of the picker's canonical spelling.
    /// Pure and `nonisolated`.
    nonisolated static func remoteQuery(
        search: String, quantization: MLXQuantization?
    ) -> String? {
        // Tokenises on the whitespace class and re-joins on plain spaces; a trim alone leaves non-breaking spaces inside.
        let tokens = search.split(whereSeparator: { $0.isWhitespace })
        guard let quantization else {
            return tokens.isEmpty ? nil : tokens.joined(separator: " ")
        }
        let kept = tokens.filter { token in
            let lower = token.lowercased()
            let isBareWidth = MLXQuantization.allCases.contains { quant in
                ["\(quant.rawValue)bit", "\(quant.rawValue)-bit", "\(quant.rawValue)_bit"].contains(lower)
            } || ["bf16", "fp16", "float16"].contains(lower)
            // Drops every bare width, including one that agrees with the picker; the picker supplies the one canonical spelling.
            // HuggingFace ANDs the terms, so two spellings of the same width make the query unsatisfiable.
            return !isBareWidth
        }
        return (kept.map(String.init) + [quantization.searchToken]).joined(separator: " ")
    }

    /// Quantizations offered by the picker.
    /// On server-backed tabs this is the full set; on `.installed` and `.recommended` it is derived from the local rows
    /// (`CuratedMLXCatalog` for `.recommended`), and always includes the active filter.
    var availableQuantizations: [MLXQuantization] {
        guard selectedCategory == .installed || selectedCategory == .recommended else {
            return MLXQuantization.allCases.sorted()
        }
        let source: [MLXQuantization]
        if selectedCategory == .installed {
            source = service.installedModels.compactMap { MLXQuantization.parse(fromRepoId: $0.displayName) }
        } else {
            let ramGB = Int(SystemHardwareProfiler.shared.profile.totalRAM / (1024 * 1024 * 1024))
            source = CuratedMLXCatalog.recommended(forSystemRAMGB: ramGB)
                .compactMap { MLXQuantization.parse(fromRepoId: $0.id) }
        }
        var present = Set(source)
        // Always offers the active filter so the picker has a tag for its own selection and the user can clear it.
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

    /// Narrows the grid to models this Mac can run.
    /// Defaults to off: the fit verdict describes models and orders them elsewhere; hiding is the user's explicit choice.
    var fitsMyMacOnly: Bool = false {
        didSet {
            guard fitsMyMacOnly != oldValue else { return }
            let budget = SystemHardwareProfiler.shared.profile.formattedEffectiveBudget
            logger.info("[MLXSTORE] 'Fits my Mac' \(self.fitsMyMacOnly ? "ON" : "OFF") against a \(budget) budget. CONSEQUENCE: \(self.fitsMyMacOnly ? "models estimated to exceed the budget are hidden; the hidden count renders beside the checkbox, which always clears it" : "every model is shown again").")
            applyFilterAndSort()
        }
    }

    /// How many models the fit filter is hiding right now, shown beside the checkbox.
    var hiddenByFitFilter: Int = 0

    // Why: the switch is exhaustive with no `default:` so a new verdict must be decided here at build time.
    /// Whether a verdict survives the "Fits my Mac" filter. Pure and `nonisolated`.
    /// `.unknown` is kept: remote cards have no size until the size pass lands, and hiding them would show an empty grid.
    nonisolated static func passesFitFilter(_ verdict: ModelFitVerdict) -> Bool {
        switch verdict {
        case .comfortable, .tight:  return true
        case .risky, .incompatible: return false
        case .unknown:              return true
        }
    }

    // Why: the id is interpolated into an API URL and a local path, so `.` and `..` components must be rejected.
    /// The canonical `owner/name` repo id a pasted string denotes, or nil when the text is a search term.
    /// Accepts a bare id or a huggingface.co / hf.co URL (optional scheme, query, fragment, `/tree/main`, `/blob/...`).
    /// Rejects text without a `/`, with inner whitespace, or not exactly two components.
    nonisolated static func repoIdToDownload(from text: String) -> String? {
        var s = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !s.isEmpty, !s.contains(where: { $0.isWhitespace }) else { return nil }

        // Strip the URL form down to its path FIRST, so a query or fragment never has to pass
        // the component test below.
        if let hash = s.firstIndex(of: "#") { s = String(s[s.startIndex..<hash]) }
        if let query = s.firstIndex(of: "?") { s = String(s[s.startIndex..<query]) }
        let scheme = s.lowercased()
        if scheme.hasPrefix("https://") { s = String(s.dropFirst(8)) }
        else if scheme.hasPrefix("http://") { s = String(s.dropFirst(7)) }

        var isURLForm = false
        for host in ["www.huggingface.co/", "huggingface.co/", "hf.co/"] where s.lowercased().hasPrefix(host) {
            s = String(s.dropFirst(host.count))
            isURLForm = true
            break
        }

        var parts = s.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        if parts.last == "" { parts.removeLast() }          // exactly one trailing slash
        // A model-card URL routinely carries `/tree/main` or `/blob/main/config.json`; the id is
        // the first two components. URL form ONLY — a bare `a/b/c` is not a repo id.
        if isURLForm, parts.count > 2 { parts = Array(parts.prefix(2)) }
        guard parts.count == 2 else { return nil }

        for part in parts {
            guard !part.isEmpty, part != ".", part != ".." else { return nil }
            let ok = part.allSatisfy { ch in
                ch.isASCII && (ch.isLetter || ch.isNumber || ch == "." || ch == "_" || ch == "-")
            }
            guard ok else { return nil }
        }
        return parts.joined(separator: "/")
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

        // Why: no `default:` so a new option must choose its server mapping at build time.
        /// The HuggingFace `sort=` field this option maps to, or nil when only a client-side ordering is possible.
        /// The size sorts are nil: repo size is fetched per repo after the listing, so they re-order loaded pages only.
        var hfSort: String? {
            switch self {
            case .popularity:   return "downloads"
            case .recent:       return "lastModified"
            case .sizeSmallest, .sizeLargest: return nil
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
        // A first run with no models on disk lands on the curated list, where the raw popularity listing is least useful.
        let hasModels = !MLXModelService.shared.installedModels.isEmpty
        self.selectedCategory = hasModels ? (filterForTools ? .installed : .all) : .recommended
        setupObserver()
        refreshCategoryData()
    }

    deinit {
        // Releasing `serviceObserver` flips its `isActive` flag so in-flight onChange tasks stop.
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
                // `downloadProgress` is not tracked: it ticks continuously and each change would re-filter the whole grid.
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

    /// Why `refreshCategoryData` is being called.
    /// A filter keystroke must not force a disk rescan of the Installed tab, since filtering there is client-side.
    private enum RefreshReason {
        /// Refresh button, tab switch, first load — re-read the disk.
        case userRequest
        /// A filter keystroke. The data is already current; only the projection changes.
        case filterChanged
    }

    /// Where a search keystroke should send the user, or nil to stay on this tab and re-filter in place.
    /// A query typed on Recommended routes to `.all`, since the curated list issues no remote request; clearing returns.
    /// Pure and `nonisolated`.
    nonisolated static func searchDestination(
        from current: StoreCategory,
        query: String,
        autoLeftRecommended: Bool
    ) -> StoreCategory? {
        let hasQuery = !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        if current == .recommended && hasQuery { return .all }
        if current == .all && autoLeftRecommended && !hasQuery { return .recommended }
        return nil
    }

    /// The HF `sort=` field a sort change must re-query with, or nil to just re-order the loaded results client-side.
    /// Nil for `.installed`, `.recommended` (no server behind them) and for size sorts the API cannot rank.
    /// Pure and `nonisolated`.
    nonisolated static func serverSortRefetch(
        from oldValue: SortOption,
        to newValue: SortOption,
        category: StoreCategory,
        lastFetchedSort: String
    ) -> String? {
        guard oldValue != newValue else { return nil }
        guard category != .installed, category != .recommended else { return nil }
        guard let target = newValue.hfSort, target != lastFetchedSort else { return nil }
        return target
    }

    // Why: the `isRestoringSort` guard breaks a didSet -> refreshCategoryData -> assign -> didSet loop; do not remove it.
    /// Re-queries HuggingFace when the user's sort choice changes the ranking the server provides.
    private func maybeRefetchForServerSort(from oldValue: SortOption) {
        guard !isRestoringSort else { return }
        guard let target = Self.serverSortRefetch(
            from: oldValue, to: sortOption,
            category: selectedCategory, lastFetchedSort: lastFetchedSort
        ) else { return }
        logger.info("[MLXSTORE] Sort \(oldValue.rawValue) → \(self.sortOption.rawValue) re-ranks the query as sort=\(target) (was \(self.lastFetchedSort)). CONSEQUENCE: page 0 is re-fetched and currentPage resets — a skip offset into the old ranking indexes a different result set.")
        refreshCategoryData()
    }

    /// True when the shared `availableModels` was produced by a different query than this instance is showing.
    /// Two store view models share one payload; local tabs (`.installed`, `.recommended`) never read it and are exempt.
    var sharedPayloadIsForeign: Bool {
        Self.payloadIsForeign(
            category: selectedCategory,
            payloadCategory: service.availableModelsCategory,
            payloadSort: service.availableModelsSort,
            payloadSearch: service.availableModelsSearch,
            expectedSort: lastFetchedSort,
            expectedSearch: remoteSearchQuery
        )
    }

    /// The comparison behind `sharedPayloadIsForeign`; pure and `nonisolated`.
    /// A nil `payloadCategory` means nothing has been fetched yet, which is not foreign.
    nonisolated static func payloadIsForeign(
        category: StoreCategory,
        payloadCategory: String?,
        payloadSort: String?,
        payloadSearch: String?,
        expectedSort: String,
        expectedSearch: String?
    ) -> Bool {
        guard category != .installed, category != .recommended else { return false }
        guard payloadCategory != nil else { return false }
        return payloadCategory != category.rawValue
            || payloadSort != expectedSort
            || payloadSearch != expectedSearch
    }

    /// Re-queries when the shared payload belongs to the other store instance.
    /// Call on re-entry, since neither view model refetches on appear.
    func refreshIfSharedPayloadIsForeign() {
        guard sharedPayloadIsForeign else { return }
        logger.info("[MLXSTORE] Shared payload belongs to another store instance (category=\(self.service.availableModelsCategory ?? "<none>") sort=\(self.service.availableModelsSort ?? "<none>") vs mine \(self.selectedCategory.rawValue)/\(self.lastFetchedSort)). CONSEQUENCE: re-querying page 0 rather than rendering or paging another instance's results.")
        refreshCategoryData()
    }

    /// Drops a pending debounced search.
    /// Call from any path about to refresh, so the debounced task cannot duplicate the request or route on stale state.
    private func cancelPendingSearch() {
        searchDebounceTask?.cancel()
        searchDebounceTask = nil
    }

    /// Applies a debounced search change: either move to a tab that can answer it, or re-filter
    /// where we are.
    private func applySearchChange() {
        if let destination = Self.searchDestination(
            from: selectedCategory,
            query: searchText,
            autoLeftRecommended: didAutoLeaveRecommended
        ) {
            logger.info("[MLXSTORE] Search on the \(self.selectedCategory.rawValue) tab moved to \(destination.rawValue). CONSEQUENCE: the query is answered by HuggingFace instead of being dropped; the Recommended tab serves a fixed local list and issues no request.")
            didAutoLeaveRecommended = (destination == .all)
            isAutoSwitchingCategory = true
            selectedCategory = destination   // its `didSet` issues the refresh for the new tab
            isAutoSwitchingCategory = false
            return
        }
        // `.filterChanged` lets the Installed tab re-filter without re-walking the disk.
        // Remote categories still fetch: for them the search text is a server query.
        refreshCategoryData(reason: .filterChanged)
    }

    private func refreshCategoryData(reason: RefreshReason = .userRequest) {
        currentPage = 0

        if selectedCategory == .recommended {
            // Restores the Installed tab's stashed sort here too, not only on the remote branch.
            if let restore = sortBeforeInstalledTab {
                isRestoringSort = true
                sortOption = restore
                isRestoringSort = false
                sortBeforeInstalledTab = nil
            }
            logger.info("Refresh: category=recommended — serving \(CuratedMLXCatalog.models.count) curated model(s) locally")
            applyFilterAndSort()
            // Sizes still come from HuggingFace so the cards show real numbers and the RAM
            // verdict has a denominator; one bounded fetch, not the 30-per-page fan-out.
            Task { await service.fetchSizesForCuratedModels() }
        } else if selectedCategory == .installed {
            // Defaults the Installed tab to most-recent-first and stashes the previous sort for restoration.
            if sortOption == .popularity {
                sortBeforeInstalledTab = sortOption
                sortOption = .recent
            }
            // Forced: reached from the Refresh button and Installed tab switches, which are explicit requests for current data.
            // A filter keystroke does not force, since filtering is client-side.
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
                // Fences the assignment: `sortOption`'s didSet re-enters this function while the stash is non-nil.
                isRestoringSort = true
                sortOption = restore
                isRestoringSort = false
                sortBeforeInstalledTab = nil
            }
            // Uses `remoteSearchQuery`, not `searchText`: the quantization is part of the query.
            let search = remoteSearchQuery
            // A size sort has no server equivalent, so keep the ranking the loaded results were
            // fetched with rather than silently reverting the listing to `downloads`.
            let serverSort = sortOption.hfSort ?? lastFetchedSort
            lastFetchedSort = serverSort
            logger.info("Refresh: category=\(self.selectedCategory.rawValue) search=\(search ?? "<none>") sort=\(serverSort) clientCapability=\(self.selectedCategory.clientCapability?.rawValue ?? "<none>")")

            // Clears the previous tab's cards and sets `isLoading` synchronously, so the grid never flashes "No models found"
            // during the actor hops before the service sets its own flag.
            isLoading = true
            loadError = nil
            displayedModels = []

            Task { [category = selectedCategory.rawValue, serverSort] in
                await service.fetchRemoteModels(
                    limit: pageSize,
                    offset: 0,
                    tags: nil,
                    search: search,
                    append: false,
                    category: category,
                    sort: serverSort
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
        // `.recommended` is excluded as well as `.installed`: both are fixed local sets, so paging them changes nothing.
        guard selectedCategory != .installed, selectedCategory != .recommended else { return }

        // Never appends onto another instance's results: the offset is measured against the shared array.
        // Re-queries page 0 instead.
        guard !sharedPayloadIsForeign else {
            logger.info("[MLXSTORE] LoadMore REFUSED — the shared payload is another store instance's. CONSEQUENCE: re-querying page 0 for this instance instead of paging into a ranking it never fetched.")
            refreshCategoryData()
            return
        }

        // The offset comes from what actually landed, not a page counter, so a failed fetch leaves no hole in the paging.
        let offset = service.availableModels.count
        currentPage += 1
        // Must match `refreshCategoryData`; a bare `searchText` would append an unfiltered page under a filtered one.
        let search = remoteSearchQuery
        logger.info("LoadMore: page=\(self.currentPage) offset=\(offset) sort=\(self.lastFetchedSort) search=\(search ?? "<none>") currentAvailable=\(self.service.availableModels.count)")

        // Uses `lastFetchedSort`, not `sortOption.hfSort`: `skip=offset` only fits the ranking that produced the loaded pages.
        Task { [category = selectedCategory.rawValue, sort = lastFetchedSort] in
            await service.fetchRemoteModels(
                limit: pageSize,
                offset: offset,
                tags: nil,
                search: search,
                append: true,
                category: category,
                sort: sort
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
                // Reasoning badge: the centralized heuristics plus generic "reasoning" / "chain-of-thought" keywords in model names.
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
                
                // Installed models carry their size from the background sizing pass (nil until it lands).
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
                    description: nil,
                    createdAt: item.createdAt
                )
            }
            
            // Soft filter, applied only while the toggle is on: `capabilities` comes from substring matching, so false negatives
            // are routine and hiding them would remove the only way to reach those models.
            if filterForTools && showToolCapableOnly {
                sourceModels = sourceModels.filter { $0.capabilities.contains(.toolUse) }
            }
            
        } else {
            // Uses the remote payload only if it was fetched for this category, ranking and search; see `sharedPayloadIsForeign`.
            guard service.availableModelsCategory == nil
                    || (service.availableModelsCategory == category.rawValue
                        && service.availableModelsSort == lastFetchedSort
                        && service.availableModelsSearch == remoteSearchQuery) else {
                // Resets the count here: this early return sits above the fit block, so the previous tab's count would otherwise stay.
                hiddenByFitFilter = 0
                return []
            }
            sourceModels = remote

            // Filters remote results client-side by category capability using `MLXDisplayModel.capabilities`.
            // No log here: this runs on every observer tick.
            if let cap = category.clientCapability {
                sourceModels = sourceModels.filter { $0.capabilities.contains(cap) }
            }
        }

        // 2. Filter by quantization when the user has narrowed to one.
        if let quantizationFilter {
            sourceModels = sourceModels.filter { $0.quantization == quantizationFilter }
        }

        // "Fits my Mac": the RAM advisory used as a filter on request. Never on the Installed tab, which carries Delete.
        // Uses `ModelFitAdvisor.verdict` (no per-model logging) with the same arguments as `ModelCardView.fitAssessment`.
        if fitsMyMacOnly && category != .installed {
            let before = sourceModels.count
            sourceModels = sourceModels.filter { model in
                Self.passesFitFilter(ModelFitAdvisor.verdict(
                    metadata: MLXQuantization.fitMetadata(forRepoId: model.id),
                    diskSizeString: model.size,
                    diskSizeBytes: model.sizeBytes
                ))
            }
            hiddenByFitFilter = before - sourceModels.count
        } else {
            hiddenByFitFilter = 0
        }

        // Filters by search text. Only `.installed` filters client-side; other tabs' queries are answered by HuggingFace.
        let filtersLocally = category == .installed
        if !query.isEmpty && filtersLocally {
            sourceModels = sourceModels.filter { model in
                model.displayName.localizedCaseInsensitiveContains(query) ||
                (model.description?.localizedCaseInsensitiveContains(query) ?? false)
            }
        }
        
        // Sorts. Every comparator tie-breaks on `id` because Swift's sort is not stable.
        // The curated list keeps its deliberate order (what this machine can run, smallest first).
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
    
    /// Whether the model is installed, using the shared repo-id comparator, which never matches by substring.
    func isInstalled(_ model: MLXDisplayModel) -> Bool {
        service.isInstalled(repoId: model.id)
    }
    
    func downloadModel(_ model: MLXDisplayModel) {
        service.downloadModel(repoId: model.id)
    }
    
    func deleteModel(_ model: MLXDisplayModel) {
        guard let item = service.installedModel(named: model.id) else {
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
