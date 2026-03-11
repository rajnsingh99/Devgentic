//
//  MLXModelStoreViewModel.swift
//  Devgentic
//
//  Created by Raj Singh on 04/02/26.
//

import Foundation
import SwiftUI
import Combine

@MainActor
class MLXModelStoreViewModel: ObservableObject {
    
    // MARK: - Inputs (View Actions)
    @Published var searchText: String = ""
    @Published var selectedCategory: StoreCategory = .all {
        didSet {
            if selectedCategory != oldValue {
                refreshCategoryData()
            }
        }
    }
    
    /// Toggle to switch between filtering local results or fetching new results from the server
    @Published var isRemoteSearchEnabled: Bool = true {
        didSet {
            refreshCategoryData()
        }
    }
    
    /// Sorting preference
    @Published var sortOption: SortOption = .popularity {
        didSet {
            // Re-apply filters and sort when option changes
            applyFilterAndSort()
        }
    }
    
    // MARK: - Outputs (View State)
    @Published var displayedModels: [MLXDisplayModel] = []
    @Published var isLoading: Bool = false
    
    // Pagination State
    private var currentPage = 0
    private let pageSize = 30
    
    // Download State
    @Published var isDownloading: Bool = false
    @Published var downloadProgress: Double = 0.0
    @Published var currentDownloadName: String = ""
    
    // MARK: - Dependencies
    private let service = MLXModelService.shared
    private var cancellables = Set<AnyCancellable>()
    
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
        
        var apiTag: String? {
            switch self {
            case .all, .installed: return nil
            case .reasoning: return "reasoning"
            case .toolUse: return "tool-use"
            case .coding: return "code"
            case .vision: return "vision"
            }
        }
    }
    
    enum SortOption: String, CaseIterable, Identifiable {
        case popularity = "Popularity"
        case sizeSmallest = "Size (Smallest)"
        case sizeLargest = "Size (Largest)"
        
        var id: String { rawValue }
        
        var icon: String {
            switch self {
            case .popularity: return "arrow.down.circle"
            case .sizeSmallest: return "arrow.up.arrow.down.square"
            case .sizeLargest: return "arrow.up.arrow.down.square.fill"
            }
        }
    }
    
    // MARK: - Initialization
    
    init() {
        setupBindings()
        refreshCategoryData()
    }
    
    private func setupBindings() {
        // 1. Debounced Remote Search Trigger
        $searchText
            .debounce(for: .milliseconds(500), scheduler: RunLoop.main)
            .removeDuplicates()
            .sink { [weak self] _ in
                guard let self = self else { return }
                if self.isRemoteSearchEnabled {
                    self.refreshCategoryData()
                }
            }
            .store(in: &cancellables)
        
        // 2. Filter & Sort Logic (Local)
        Publishers.CombineLatest3(
            service.$availableModels,
            service.$installedModels,
            $searchText
        )
        .receive(on: RunLoop.main)
        .sink { [weak self] _ in
            self?.applyFilterAndSort()
        }
        .store(in: &cancellables)
        
        // 3. Loading State
        service.$isLoadingRemoteModels.assign(to: &$isLoading)
        
        // 4. Download State Mirroring
        service.$isDownloading.assign(to: &$isDownloading)
        service.$downloadProgress.assign(to: &$downloadProgress)
        service.$currentDownloadName.assign(to: &$currentDownloadName)
    }
    
    // MARK: - Logic
    
    private func refreshCategoryData() {
        currentPage = 0
        
        if selectedCategory == .installed {
            service.refreshInstalledModels()
        } else {
            let search = (isRemoteSearchEnabled && !searchText.isEmpty) ? searchText : nil
            
            Task {
                await service.fetchRemoteModels(
                    limit: pageSize,
                    offset: 0,
                    tags: selectedCategory.apiTag != nil ? [selectedCategory.apiTag!] : nil,
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
        
        Task {
            await service.fetchRemoteModels(
                limit: pageSize,
                offset: offset,
                tags: selectedCategory.apiTag != nil ? [selectedCategory.apiTag!] : nil,
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
                MLXDisplayModel(
                    id: item.displayName,
                    size: nil,
                    capabilities: [.textGeneration],
                    tags: ["Installed"],
                    downloads: 0,
                    likes: 0,
                    description: item.localPath.path
                )
            }
        } else {
            sourceModels = remote
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
            // Default API order is usually popularity, but we can enforce logic here if needed.
            // For now, we trust the API order or the list order unless explicitly sorting.
            // If strictly local sorting is needed:
            // sourceModels.sort { $0.downloads > $1.downloads }
            break
            
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
