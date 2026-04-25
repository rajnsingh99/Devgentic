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
                self.refreshCategoryData()
            }
        }
    }
    var selectedCategory: StoreCategory = .all {
        didSet {
            if selectedCategory != oldValue {
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

    // Pagination State
    @ObservationIgnored private var currentPage = 0
    @ObservationIgnored private let pageSize = 30

    // Download State
    var isDownloading: Bool = false
    var downloadProgress: Double = 0.0
    var currentDownloadName: String = ""

    // MARK: - Dependencies
    @ObservationIgnored private let service = MLXModelService.shared
    @ObservationIgnored private var searchDebounceTask: Task<Void, Never>?
    
    // MARK: - Definitions
    
    enum StoreCategory: String, CaseIterable, Identifiable {
        case installed = "Installed"
        case all = "All"
        case reasoning = "Reasoning"
        case toolUse = "Tool Use"
        case coding = "Coding"
        case vision = "Vision"
        
        var id: String { rawValue }
        
        var icon: String {
            switch self {
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
            case .all, .installed: return nil
            case .reasoning: return .reasoning
            case .toolUse: return .toolUse
            case .coding: return .coding
            case .vision: return .vision
            }
        }
    }
    
    var availableCategories: [StoreCategory] {
        if filterForTools {
            return [.installed, .toolUse]
        } else {
            return StoreCategory.allCases
        }
    }
    
    enum SortOption: String, CaseIterable, Identifiable {
        case popularity = "Popularity"
        case recent = "Recent"
        case sizeSmallest = "Size (Smallest)"
        case sizeLargest = "Size (Largest)"

        var id: String { rawValue }

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
        self.selectedCategory = filterForTools ? .installed : .all
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
                _ = self.service.isLoadingRemoteModels
                _ = self.service.isDownloading
                _ = self.service.downloadProgress
                _ = self.service.currentDownloadName
            },
            onChange: { [weak self] in
                guard let self else { return }
                // Mirror state from service
                self.isLoading = self.service.isLoadingRemoteModels
                self.isDownloading = self.service.isDownloading
                self.downloadProgress = self.service.downloadProgress
                self.currentDownloadName = self.service.currentDownloadName
                self.applyFilterAndSort()
            }
        )
    }
    
    // MARK: - Logic
    
    private func refreshCategoryData() {
        currentPage = 0

        if selectedCategory == .installed {
            // Default installed tab to most-recent-first
            if sortOption == .popularity { sortOption = .recent }
            logger.info("Refresh: category=installed — scanning local models")
            service.refreshInstalledModels()
            // The scan is debounced: if the last scan was <2s ago, it returns
            // without touching `installedModels`, so the observer never fires
            // and `displayedModels` would keep showing the prior tab's content.
            // Force a re-filter so the installed cards render immediately.
            applyFilterAndSort()
        } else {
            let search = (isRemoteSearchEnabled && !searchText.isEmpty) ? searchText : nil
            logger.info("Refresh: category=\(self.selectedCategory.rawValue) search=\(search ?? "<none>") clientCapability=\(self.selectedCategory.clientCapability?.rawValue ?? "<none>")")

            // Clear stale cards from the prior tab so the loading UI shows
            // instead of (incorrectly) rendering the previous category's
            // models until the remote fetch completes.
            displayedModels = []

            Task {
                await service.fetchRemoteModels(
                    limit: pageSize,
                    offset: 0,
                    tags: nil,
                    search: search,
                    append: false
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

        Task {
            await service.fetchRemoteModels(
                limit: pageSize,
                offset: offset,
                tags: nil,
                search: search,
                append: true
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
        if category == .installed {
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
                
                return MLXDisplayModel(
                    id: item.displayName,
                    size: nil,
                    capabilities: caps,
                    tags: ["Installed"],
                    downloads: 0,
                    likes: 0,
                    description: item.localPath.path,
                    createdAt: item.createdAt
                )
            }
            
            // Apply hard filter if we only want tool models
            if filterForTools {
                sourceModels = sourceModels.filter { $0.capabilities.contains(.toolUse) }
            }
            
        } else {
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

        // 2. Filter by Search Text (Local Mode)
        if !query.isEmpty && !isRemoteSearchEnabled {
            sourceModels = sourceModels.filter { model in
                model.displayName.localizedCaseInsensitiveContains(query) ||
                (model.description?.localizedCaseInsensitiveContains(query) ?? false)
            }
        }
        
        // 3. Sort
        switch sort {
        case .popularity:
            break

        case .recent:
            sourceModels.sort { ($0.createdAt ?? .distantPast) > ($1.createdAt ?? .distantPast) }

        case .sizeSmallest:
            sourceModels.sort { parseSize($0.size) < parseSize($1.size) }

        case .sizeLargest:
            sourceModels.sort { parseSize($0.size) > parseSize($1.size) }
        }
        
        return sourceModels
    }
    
    /// Helper to approximate size in MB from string like "1.2 GB"
    private func parseSize(_ sizeStr: String?) -> Double {
        guard let sizeStr = sizeStr else { return 0 }
        let normalized = sizeStr.uppercased()
        
        // Extract numeric part
        let numberString = normalized.components(separatedBy: CharacterSet(charactersIn: "0123456789.").inverted).joined()
        let value = Double(numberString) ?? 0
        
        if normalized.contains("GB") {
            return value * 1024
        } else if normalized.contains("KB") {
            return value / 1024
        }
        // Assume MB if no unit or just return value
        return value
    }
    
    // MARK: - Actions
    
    func isInstalled(_ model: MLXDisplayModel) -> Bool {
        return service.installedModels.contains { installed in
            installed.displayName == model.id || installed.displayName.contains(model.displayName)
        }
    }
    
    func downloadModel(_ model: MLXDisplayModel) {
        service.downloadModel(repoId: model.id)
    }
    
    func deleteModel(_ model: MLXDisplayModel) {
        if let item = service.installedModels.first(where: { $0.displayName == model.id }) {
            service.deleteModel(item)
        }
    }
    
    func cancelDownload() {
        service.cancelDownload()
    }
    
    func refresh() {
        refreshCategoryData()
    }
}
