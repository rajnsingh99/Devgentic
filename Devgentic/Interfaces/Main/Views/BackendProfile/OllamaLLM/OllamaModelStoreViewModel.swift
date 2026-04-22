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

    @ObservationIgnored private var serviceObserver: ObservationStream?

    init() {
        setupBindings()
        // Bootstrap probe is skipped when the shared `OllamaService` already holds
        // fresh data from a prior view-model lifetime. This prevents the repeated
        // `Checking Ollama server status` log floods and redundant `/api/show`
        // fan-outs whenever SwiftUI re-creates `OllamaModelStoreContainerView`
        // (which happens every time the user toggles into/out of this destination
        // since layer 2 of `MainApplicationView` is `if !router.isShowingChat`-gated).
        //
        // If Ollama has never been probed, or was previously disconnected, the
        // cooldown-respecting `checkServerStatusAndUpdateModels()` handles both
        // cold start and 30-second failure throttling. The user's explicit refresh
        // button still hits `forceCheckServerStatus()` via `refresh()`.
        Task { @MainActor [service] in
            if Self.shouldBootstrapProbe(for: service) {
                await service.checkServerStatusAndUpdateModels()
            }
        }
    }

    /// Decide whether a fresh viewModel should kick off a server probe.
    /// Returns `false` when the singleton already has cached data (connected +
    /// non-empty models) so repeated recreations don't hammer the server.
    private static func shouldBootstrapProbe(for service: OllamaService) -> Bool {
        // Service is already loading → let that finish, don't stack probes.
        if service.serverStatus == .checking { return false }
        // We have cached models from a prior instance → reuse them.
        if service.serverStatus == .connected && !service.localModels.isEmpty { return false }
        return true
    }

    deinit {
        // Releasing `serviceObserver` triggers `ObservationStream.deinit`,
        // which flips its own `isActive` flag so any in-flight onChange task
        // short-circuits instead of writing to a zombie self.
    }

    /// Bridges OllamaService (@Observable) state via the shared `ObservationStream`
    /// helper. The stream owns the re-subscription recursion and the lifecycle
    /// cancellation guard — this file just declares what to track and what to do.
    private func setupBindings() {
        serviceObserver = ObservationStream(
            track: { [weak self] in
                guard let self else { return }
                _ = self.service.localModels
                _ = self.service.isLoadingModels
                _ = self.service.isPullingModel
                _ = self.service.pullProgress
                _ = self.service.modelToPull
                _ = self.service.modelPullError
            },
            onChange: { [weak self] in
                guard let self else { return }
                self.applyFilterAndSort(models: self.service.localModels, query: self.searchText, sort: self.sortOption)
                self.isLoading = self.service.isLoadingModels
                self.isDownloading = self.service.isPullingModel
                self.downloadProgress = self.service.pullProgress
                self.currentDownloadName = self.service.modelToPull
                self.downloadErrorMessage = self.service.modelPullError
            }
        )
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

    /// User-triggered refresh. Takes a `UserAction` proof to propagate intent
    /// down to the service — we don't construct the token internally so a
    /// stray `refresh()` call from, e.g., an init or onAppear, doesn't silently
    /// bypass the server-probe cooldown (which is how this path got misused
    /// originally).
    func refresh(triggeredBy action: UserAction) {
        Task {
            await service.forceCheckServerStatus(triggeredBy: action)
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
