//
//  OllamaModelStoreViewModel.swift
//  Devgentic
//
//  Created by Antigravity on 07/03/26.
//

import Foundation
import SwiftUI
import Combine

@MainActor
class OllamaModelStoreViewModel: ObservableObject {
    
    // MARK: - Inputs
    @Published var searchText: String = ""
    @Published var sortOption: SortOption = .name
    
    // MARK: - Outputs
    @Published var displayedModels: [LocalModel] = []
    @Published var isLoading: Bool = false
    
    // Download State
    @Published var isDownloading: Bool = false
    @Published var downloadProgress: Double = 0.0
    @Published var currentDownloadName: String = ""
    @Published var downloadErrorMessage: String? = nil
    
    // MARK: - Dependencies
    private let service = OllamaService.shared
    private var cancellables = Set<AnyCancellable>()
    
    enum SortOption: String, CaseIterable, Identifiable {
        case name = "Name"
        case size = "Size"
        
        var id: String { rawValue }
        
        var icon: String {
            switch self {
            case .name: return "textformat"
            case .size: return "externaldrive"
            }
        }
    }
    
    init() {
        setupBindings()
        refresh()
    }
    
    private func setupBindings() {
        // Handle Filtering & Sorting
        Publishers.CombineLatest3(
            service.$localModels,
            $searchText,
            $sortOption
        )
        .receive(on: RunLoop.main)
        .sink { [weak self] localModels, query, sort in
            self?.applyFilterAndSort(models: localModels, query: query, sort: sort)
        }
        .store(in: &cancellables)
        
        // Mirror Service State
        service.$isLoadingModels.assign(to: &$isLoading)
        service.$isPullingModel.assign(to: &$isDownloading)
        service.$pullProgress.assign(to: &$downloadProgress)
        service.$modelToPull.assign(to: &$currentDownloadName)
        service.$modelPullError.assign(to: &$downloadErrorMessage)
    }
    
    private func applyFilterAndSort(models: [LocalModel], query: String, sort: SortOption) {
        var filtered = models
        
        if !query.isEmpty {
            filtered = models.filter { $0.name.localizedCaseInsensitiveContains(query) }
        }
        
        switch sort {
        case .name:
            filtered.sort { $0.name < $1.name }
        case .size:
            // LocalModel doesn't explicitly store size in the current struct, 
            // but we could parse it from details if available in the future.
            // For now, keep alphabetical if size is unavailable.
            filtered.sort { $0.name < $1.name }
        }
        
        self.displayedModels = filtered
    }
    
    // MARK: - Actions
    
    func refresh() {
        Task {
            await service.forceCheckServerStatus()
        }
    }
    
    func downloadModel(name: String) {
        guard !name.isEmpty else { return }
        Task {
            await service.pullModel(name: name, baseURL: service.ollamaBaseURL)
        }
    }
    
    func deleteModel(_ model: LocalModel) {
        Task {
            await service.removeModel(name: model.name, baseURL: service.ollamaBaseURL)
        }
    }
    
    func cancelDownload() {
        service.cancelPullModel()
    }
}
