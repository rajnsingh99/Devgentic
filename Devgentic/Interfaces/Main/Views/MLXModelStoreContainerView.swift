// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2026 Raj Singh
//
//  MLXModelStoreContainerView.swift
//  Devgentic
//
//  Created by Raj Singh on 19/03/26.
//
//  Inline wrapper for the MLX model store that renders within
//  the single-window interface. Uses DynamicIslandBar for back
//  navigation, search, and refresh. Content is centered at
//  maxWidth: 1000 to match the DynamicIslandBar width.
//

import SwiftUI

struct MLXModelStoreContainerView: View {

    let filterForTools: Bool
    /// The profile that opened the store, so downloads it starts are attributed to it.
    let profileID: UUID?

    /// View model is owned by `DestinationCoordinator` (separate instance per
    /// `filterForTools` value) so its category / search / sort state survives
    /// the view re-creation cascade when navigating away and back.
    @Environment(DestinationCoordinator.self) private var coordinator
    /// The same surface `ModelCardView` uses to report a download start or a refusal.
    @Environment(ToastManager.self) private var toastManager

    /// True while `fetchByRepoId` is awaiting HuggingFace.
    ///
    /// ⚠️ The pre-flight is a model-info request plus a README fetch — easily a second or two —
    /// during which nothing on screen changed and no toast had appeared yet. A second press
    /// started a second task for the same id; the first began the pull and toasted
    /// "Downloading X…", then the second was rejected deep in the service and REPLACED that toast
    /// with "another model is already downloading" — naming another model when it is the same one,
    /// and burying the only confirmation the user was going to get.
    @State private var isFetchingPastedRepo = false

    @State private var isSearchExpanded = false

    init(filterForTools: Bool = false, profileID: UUID? = nil) {
        self.filterForTools = filterForTools
        self.profileID = profileID
    }

    /// Fetches a repo the user PASTED, rather than one they picked off a card.
    ///
    /// ⚠️ Routes through `DownloadCoordinator.startMLXDownloadIfNeeded` — the same entry point
    /// `ModelCardView.startDownload()` uses — so the pasted path keeps the install
    /// short-circuit, the single-slot refusal, the in-flight history check, the free-space
    /// preflight and the `preSeedTotalBytes` that feeds the speed/ETA readout. Calling
    /// `MLXModelService.downloadModel` directly would skip every one of them.
    ///
    /// ⚠️ The pre-flight is not belt-and-braces. `startMLXDownloadIfNeeded` validates the id for
    /// EMPTINESS only, and the byte-size probe returns nil for a repo that does not exist exactly
    /// as it does for a flaky network — so without this a typo passes preflight, shows
    /// "Downloading …", and fails a round trip later with HubApi's `File not found: main`, which
    /// names the REVISION rather than the repo. One reuse of `fetchModelDetail` turns that into
    /// "That model doesn't exist on HuggingFace." before a download slot is taken.
    @MainActor
    private func fetchByRepoId(_ repoId: String) async {
        guard !isFetchingPastedRepo else { return }
        isFetchingPastedRepo = true
        defer { isFetchingPastedRepo = false }

        let detail: MLXModelDetail
        switch await MLXModelService.shared.fetchModelDetail(repoId: repoId) {
        case .success(let value):
            detail = value
        case .failure(let error):
            toastManager.show(error.errorDescription ?? "Couldn't reach HuggingFace.", style: .error)
            return
        }

        // ⚠️ Appended to the ONE toast, never shown as a second `show` — a new toast replaces the
        // live one, so two calls in a row means the first is never read. And a NOTE, not a gate:
        // the same line the card's "Gated" capsule takes — the user may have accepted the licence,
        // and refusing on a listing flag blocks a download that would work.
        let gatedNote = (detail.isGated && !HuggingFaceTokenStore.shared.hasToken)
            ? " It's gated — add a HuggingFace token in Settings › General if it fails."
            : ""

        switch await DownloadCoordinator.startMLXDownloadIfNeeded(repoId: repoId, profileID: profileID) {
        case .alreadyInstalled:
            toastManager.show("\(repoId) is already installed.", style: .success)
        case .alreadyInProgress:
            toastManager.show("\(repoId) is already downloading.", style: .warning)
        case .resumedFromHistory, .startedFresh:
            toastManager.show("Downloading \(repoId)…\(gatedNote)",
                              style: gatedNote.isEmpty ? .success : .warning)
        case .failed(let reason):
            toastManager.show(reason, style: .error)
        }
    }

    var body: some View {
        @Bindable var viewModel = coordinator.mlxStore(filterForTools: filterForTools)

        VStack(spacing: 0) {
            DynamicIslandBar {
                IslandExpandableSearchHeader(
                    title: "MLX Model Store",
                    icon: "cpu.fill",
                    text: $viewModel.searchText,
                    placeholder: viewModel.selectedCategory == .installed
                        ? "Filter models"
                        : "Search Hugging Face, or paste a repo ID",
                    isExpanded: $isSearchExpanded,
                    isSearching: viewModel.isLoading,
                    accessibilityIdentifier: "mlx.store.search",
                    onSubmit: {
                        // Return fetches, but ONLY when the text is an identifier — for an
                        // ordinary query it stays the no-op it is today. Mirrors the Ollama
                        // store, whose box is likewise both a filter and a pull field.
                        if let repoId = MLXModelStoreViewModel.repoIdToDownload(from: viewModel.searchText) {
                            Task { await fetchByRepoId(repoId) }
                        }
                    }
                )
            } trailing: {
                HStack(spacing: 6) {
                    IslandSearchToggleButton(isExpanded: $isSearchExpanded)

                    Menu {
                        Picker("Sort By", selection: $viewModel.sortOption) {
                            ForEach(MLXModelStoreViewModel.SortOption.allCases) { option in
                                Label(option.localizedTitle, systemImage: option.icon).tag(option)
                            }
                        }
                    } label: {
                        Image(systemName: "arrow.up.arrow.down")
                            .islandCircleAffordance()
                    }
                    .menuStyle(.borderlessButton)
                    .menuIndicator(.hidden)
                    .fixedSize()
                    .help("Sort Models")
                    .accessibilityLabel("Sort models")
                    .disabled(viewModel.isLoading)

                    // Paste-a-repo-id. The box is otherwise a QUERY, so an exact id had to be
                    // located in ranked results before it could be fetched.
                    //
                    // ⚠️ Gated on the TEXT being an identifier, NOT on `displayedModels.isEmpty`
                    // the way the Ollama store gates its Pull button. Ollama's filter is
                    // synchronous and client-side; this one is not — `refreshCategoryData`
                    // assigns `displayedModels = []` on every remote refresh, so an
                    // emptiness-gated button would appear and vanish on every typing pause. It
                    // would also be missing in the case that matters most: a search that DID
                    // return the repo, which the quantization / fit / tool-capable filters hid.
                    if let repoId = MLXModelStoreViewModel.repoIdToDownload(from: viewModel.searchText) {
                        IslandIconButton(
                            symbol: "arrow.down.circle.fill",
                            style: .prominent,
                            help: "Download \(repoId) from HuggingFace (⌘↩)",
                            accessibilityLabel: "Download \(repoId) from HuggingFace",
                            // ⚠️ ⌘↩, matching what the tooltip says. `.defaultAction` is a bare
                            // Return, so the tooltip advertised a shortcut that did nothing —
                            // and worse, Return ALSO fires the search field's own `onSubmit`,
                            // which calls this same function, so one keypress had two triggers.
                            keyboardShortcut: KeyboardShortcut(.return, modifiers: .command),
                            isLoading: isFetchingPastedRepo
                        ) {
                            Task { await fetchByRepoId(repoId) }
                        }
                    }

                    IslandIconButton(
                        symbol: "arrow.clockwise",
                        help: "Refresh Store (⌘R)",
                        accessibilityLabel: "Refresh store",
                        keyboardShortcut: KeyboardShortcut("r", modifiers: .command),
                        isLoading: viewModel.isLoading
                    ) {
                        viewModel.refresh()
                    }
                }
            }

            MLXModelStoreContent(
                viewModel: viewModel,
                filterForTools: filterForTools,
                profileID: profileID,
                showSearchBar: false,
                centeredLayout: true
            )
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear {
            if !viewModel.searchText.isEmpty {
                isSearchExpanded = true
            }
            // ⚠️ RE-ENTRY IS THE ONLY MOMENT THIS IS DETECTABLE. Neither store view model refetches
            // on appear — that is deliberate, so returning to the store keeps your place — but the
            // two cached instances share one result array, so the other one may have replaced it
            // while you were away. Without this the grid shows its rows until you touch a control.
            viewModel.refreshIfSharedPayloadIsForeign()
        }
    }
}
