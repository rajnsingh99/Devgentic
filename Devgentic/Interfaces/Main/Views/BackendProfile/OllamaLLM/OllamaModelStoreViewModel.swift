// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
//
//  OllamaModelStoreViewModel.swift
//  Devgentic
//
//  Created by Raj Singh.
//

import Foundation
import SwiftUI

private let logger = DGLogger(category: "OllamaModelStore")

@Observable @MainActor
class OllamaModelStoreViewModel {

    // MARK: - Inputs
    var searchText: String = "" {
        didSet {
            applyFilterAndSort(models: service.localModels, query: searchText, sort: sortOption)
            scheduleSupportCheck()
        }
    }
    var sortOption: SortOption = .name {
        didSet { applyFilterAndSort(models: service.localModels, query: searchText, sort: sortOption) }
    }

    // MARK: - Outputs
    var displayedModels: [LocalModel] = []
    var isLoading: Bool = false

    // Download state. Live per-row progress comes from `DownloadManager` via `ModelDownloadStatusView`, so no progress
    // fields are mirrored here.
    var isDownloading: Bool = false
    var downloadErrorMessage: String? = nil

    /// `owner/repo` of an `hf.co/…` pull name → why Devgentic can't run it. Only UNSUPPORTED
    /// repos are stored: absence means "supported, not an hf.co name, or not yet known", and
    /// `DownloadCoordinator.startOllamaDownloadIfNeeded` repeats the check authoritatively.
    var unsupportedPullReasons: [String: String] = [:]

    /// Why the name currently typed in the search box can't be pulled, or nil. Drives the
    /// "Not supported" pill that replaces the Pull/Download button.
    var unsupportedPullReason: String? {
        guard let repo = ModelSupportPolicy.huggingFaceRepoId(fromOllamaName: searchText) else { return nil }
        return unsupportedPullReasons[repo]
    }

    @ObservationIgnored private var supportCheckTask: Task<Void, Never>?

    /// The service's own pull narration, mirrored so the outcome (including "Successfully pulled …") can be rendered.
    var pullStatus: OllamaService.PullTerminalState? = nil

    // Deletion state. A refused delete (active model, or a pull in flight) surfaces its reason from
    // `OllamaService.modelRemoveError`.
    var isDeleting: Bool = false
    var deleteErrorMessage: String? = nil

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
        // Cold start or disconnected runs the cooldown-respecting full probe; otherwise it revalidates, and the digest-aware
        // `loadLocalModels()` re-runs /api/show only for new or changed models.
        Task { @MainActor [service] in
            if Self.shouldBootstrapProbe(for: service) {
                await service.checkServerStatusAndUpdateModels()
            } else {
                await service.loadLocalModels()
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
        // Releasing `serviceObserver` triggers `ObservationStream.deinit`, which flips `isActive` so an in-flight onChange
        // task does not write to a zombie self.
    }

    /// Bridges OllamaService (@Observable) state via the shared `ObservationStream`
    /// helper. The stream owns the re-subscription recursion and the lifecycle
    /// cancellation guard — this file just declares what to track and what to do.
    private func setupBindings() {
        serviceObserver = ObservationStream(
            track: { [weak self] in
                guard let self else { return }
                // `pullProgress` and `modelToPull` are deliberately not tracked: `pullProgress` ticks per NDJSON line and each tick
                // would re-filter and re-sort the grid. Per-row progress reads `DownloadManager`.
                _ = self.service.localModels
                _ = self.service.isLoadingModels
                _ = self.service.isPullingModel
                _ = self.service.modelPullError
                // Tracks `pullTerminalState`, not `pullStatusMessage`, which is rewritten per NDJSON line and would re-filter and
                // re-sort the grid for every progress line.
                _ = self.service.pullTerminalState
                _ = self.service.isRemovingModel
                _ = self.service.modelRemoveError
            },
            onChange: { [weak self] in
                guard let self else { return }
                self.applyFilterAndSort(models: self.service.localModels, query: self.searchText, sort: self.sortOption)
                self.isLoading = self.service.isLoadingModels
                self.isDownloading = self.service.isPullingModel
                self.downloadErrorMessage = self.service.modelPullError
                self.pullStatus = self.service.pullTerminalState
                self.isDeleting = self.service.isRemovingModel
                self.deleteErrorMessage = self.service.modelRemoveError
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

    /// User-triggered refresh. Takes a `UserAction` proof so intent propagates to the service; a stray call from an init
    /// or onAppear cannot bypass the server-probe cooldown.
    func refresh(triggeredBy action: UserAction) {
        Task {
            await service.forceCheckServerStatus(triggeredBy: action)
        }
    }
    
    /// Debounced HuggingFace metadata check for an `hf.co/…` name, so the pull control reads
    /// "Not supported" before it is pressed. Library names have no metadata and are skipped.
    private func scheduleSupportCheck() {
        supportCheckTask?.cancel()
        guard let repo = ModelSupportPolicy.huggingFaceRepoId(fromOllamaName: searchText),
              unsupportedPullReasons[repo] == nil else { return }
        supportCheckTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(400))
            guard !Task.isCancelled else { return }
            if let reason = await MLXModelService.shared.unsupportedReason(forRepo: repo) {
                self?.unsupportedPullReasons[repo] = reason
            }
        }
    }

    func downloadModel(name: String) {
        guard !name.isEmpty else { return }
        Task {
            // Same authoritative check the coordinator makes: this entry point (Return in the search box, the island Pull
            // button) calls `pullModel` directly and never reaches it.
            if let repo = ModelSupportPolicy.huggingFaceRepoId(fromOllamaName: name),
               let reason = await MLXModelService.shared.unsupportedReason(forRepo: repo) {
                unsupportedPullReasons[repo] = reason
                logger.notice("[OLLAMA_STORE] Pull of '\(name)' refused — \(reason) CONSEQUENCE: nothing is pulled; the Pull control now reads 'Not supported' for this name.")
                return
            }
            await service.pullModel(name: name, baseURL: service.ollamaBaseURL)
        }
    }
    
    func deleteModel(_ model: LocalModel) {
        Task {
            await service.removeModel(name: model.name, baseURL: service.ollamaBaseURL)
            // The service reports refusals through `modelRemoveError` rather than throwing, so the
            // outcome has to be read back — the previous fire-and-forget call discarded it.
            if let reason = service.modelRemoveError {
                logger.error("""
                    [DOWNLOAD] Delete refused for Ollama model '\(model.name)': \(reason). \
                    CONSEQUENCE: the model is still installed and the card stays on screen; the \
                    reason is now shown in the store's error banner.
                    """)
            } else {
                logger.info("[DOWNLOAD] Removed Ollama model '\(model.name)'.")
            }
        }
    }

    /// Clears the pull outcome banner and whichever error banner the store is showing. Must clear the service-side value
    /// too: the view model's copy is re-mirrored from `service.pullTerminalState` on the next observer tick.
    func dismissPullStatus() {
        pullStatus = nil
        service.pullTerminalState = nil
    }

    func dismissErrors() {
        deleteErrorMessage = nil
        downloadErrorMessage = nil
        service.modelRemoveError = nil
        service.modelPullError = nil
        // The outcome banner is hidden while an error shows, so dismissing the error also dismisses the outcome; otherwise a
        // stale "Failed to pull X." would appear under a green tick.
        dismissPullStatus()
    }
    
    func cancelDownload() {
        service.cancelPullModel()
    }
}
