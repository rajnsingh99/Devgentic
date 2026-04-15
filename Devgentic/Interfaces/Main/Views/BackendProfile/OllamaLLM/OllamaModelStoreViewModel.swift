//
//  OllamaModelStoreViewModel.swift
//  Devgentic
//
//  Created by Antigravity on 07/03/26.
//

import Foundation
import SwiftUI

@Observable @MainActor
class OllamaModelStoreViewModel {

    // MARK: - Inputs
    var searchText: String = "" {
        didSet { applyFilterAndSort(models: service.localModels, query: searchText, sort: sortOption) }
    }
    var sortOption: SortOption = .name {
        didSet { applyFilterAndSort(models: service.localModels, query: searchText, sort: sortOption) }
    }

    // MARK: - Outputs
    var displayedModels: [LocalModel] = []
    var isLoading: Bool = false

    // Download State
    var isDownloading: Bool = false
    var downloadProgress: Double = 0.0
    var currentDownloadName: String = ""
    var downloadErrorMessage: String? = nil

    // MARK: - Dependencies
    @ObservationIgnored private let service = OllamaService.shared

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

    @ObservationIgnored private var isObserving = true

    init() {
        setupBindings()
        refresh()
    }

    deinit {
        isObserving = false
    }

    private func setupBindings() {
        observeOllamaServiceChanges()
    }

    /// Bridges OllamaService (@Observable) state via withObservationTracking.
    private func observeOllamaServiceChanges() {
        guard isObserving else { return }
        withObservationTracking {
            _ = service.localModels
            _ = service.isLoadingModels
            _ = service.isPullingModel
            _ = service.pullProgress
            _ = service.modelToPull
            _ = service.modelPullError
        } onChange: {
            Task { @MainActor [weak self] in
                guard let self, self.isObserving else { return }
                self.applyFilterAndSort(models: self.service.localModels, query: self.searchText, sort: self.sortOption)
                self.isLoading = self.service.isLoadingModels
                self.isDownloading = self.service.isPullingModel
                self.downloadProgress = self.service.pullProgress
                self.currentDownloadName = self.service.modelToPull
                self.downloadErrorMessage = self.service.modelPullError
                self.observeOllamaServiceChanges()
            }
        }
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
            filtered.sort {
                let lhs = $0.details?.parameterSizeValue ?? 0
                let rhs = $1.details?.parameterSizeValue ?? 0
                if lhs != rhs { return lhs > rhs }
                return $0.name < $1.name  // tie-break alphabetically
            }
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
