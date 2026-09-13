// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2026 Raj Singh
//
//  OllamaModelStoreViewModel.swift
//  Devgentic
//
//  Created by Antigravity on 07/03/26.
//

import Foundation
import SwiftUI

private let logger = DGLogger(category: "OllamaModelStore")

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
    //
    // ⚠️ register A42 — `downloadProgress` and `currentDownloadName` were removed with the
    // `pullProgress` tracking that fed them. Their only reader was a `downloadBanner` in
    // `OllamaModelStoreView` that was declared and never called, so mirroring them cost a full
    // re-filter and re-sort of the grid per NDJSON line of a multi-GB pull and rendered nothing.
    // Live per-row progress comes from `DownloadManager` via `ModelDownloadStatusView`.
    var isDownloading: Bool = false
    var downloadErrorMessage: String? = nil

    /// The service's own pull narration, mirrored so it can actually be rendered.
    ///
    /// ⚠️ `OllamaService.pullStatusMessage` is written SEVEN times — including "Successfully
    /// pulled …" — and was read ZERO times anywhere in the app. A user who pulled a multi-GB
    /// model was never told it had finished; they had to press Refresh and look for the card.
    var pullStatus: OllamaService.PullTerminalState? = nil

    // Deletion State
    //
    // ⚠️ `OllamaService.modelRemoveError` had ZERO readers anywhere in the app: `removeModel`
    // writes a reason into it on five separate guard arms and every one of them was invisible.
    // Confirming "Delete Model?" on the active model, or while a pull was in flight, simply did
    // nothing — the card stayed on screen with no message, no toast and (for one arm) no log.
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
        // Cold start / disconnected: the cooldown-respecting full probe runs
        // (`checkServerStatusAndUpdateModels` — status check + model load, with
        // 30-second failure throttling). When the shared `OllamaService` already
        // holds data from a prior view-model lifetime, we no longer skip entirely —
        // that made models pulled via the CLI invisible until an explicit refresh.
        // Instead we revalidate: `loadLocalModels()` is digest-aware
        // (`LocalModelRefresher`), so a recreation costs one /api/tags +
        // /api/version round-trip and re-runs /api/show only for new/changed
        // models. The original concern (status-probe log floods + full /api/show
        // fan-outs on every `MainApplicationView` layer toggle) stays solved.
        // The explicit refresh button still forces the full probe via `refresh()`.
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
                // ⚠️ register A42 — `pullProgress` and `modelToPull` are deliberately NOT tracked.
                // `pullProgress` ticks once per NDJSON line for the whole of a multi-GB pull, and
                // this observer's `onChange` runs `applyFilterAndSort` — a full re-filter and
                // re-sort of the grid, plus a write to every mirrored property — per tick. The
                // per-row progress UI reads `DownloadManager`'s own state directly
                // (`ModelDownloadStatusView`), so nothing here needs the value.
                //
                // This is the same rule `MLXModelStoreViewModel` records having adopted; the two
                // view models now document it identically so neither drifts back.
                _ = self.service.localModels
                _ = self.service.isLoadingModels
                _ = self.service.isPullingModel
                _ = self.service.modelPullError
                // ⚠️ `pullTerminalState`, NOT `pullStatusMessage`. The latter is rewritten
                // once per NDJSON line, so tracking it ran this observer's `applyFilterAndSort`
                // — a full re-filter and re-sort — for every progress line of a multi-GB pull.
                // That is precisely what the note above excludes `pullProgress` for, and the
                // offending line had been added directly beneath it.
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

    /// Clears whichever error banner the store is showing.
    /// Clears the pull outcome banner.
    ///
    /// ⚠️ Must clear it on the SERVICE too. The view model's copy is re-mirrored from
    /// `service.pullTerminalState` on the very next observer tick, so nilling only the local one
    /// makes the banner reappear. That is also why the banner could never be dismissed before:
    /// `clearPullActionStatus()` is the only thing that resets the service-side value and it has
    /// no callers anywhere in the tree.
    func dismissPullStatus() {
        pullStatus = nil
        service.pullTerminalState = nil
    }

    func dismissErrors() {
        deleteErrorMessage = nil
        downloadErrorMessage = nil
        service.modelRemoveError = nil
        service.modelPullError = nil
        // ⚠️ The outcome banner is suppressed while an error is showing, so dismissing the error
        // used to REVEAL a stale one — dismiss a failed pull's error and "Failed to pull X."
        // surfaced underneath it, under a green tick. They describe the same event; they go
        // together.
        dismissPullStatus()
    }
    
    func cancelDownload() {
        service.cancelPullModel()
    }
}
