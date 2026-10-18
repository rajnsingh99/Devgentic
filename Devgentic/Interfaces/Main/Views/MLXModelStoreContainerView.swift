// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
//
//  MLXModelStoreContainerView.swift
//  Devgentic
//
//  Created by Raj Singh.
//

import SwiftUI

/// Inline MLX model store rendered within the single-window interface, with a `DynamicIslandBar` for back navigation,
/// search and refresh. Content is centered at maxWidth 1000 to match the bar.
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

    // Why: blocks a second press during the pre-flight: a duplicate task would replace the first download toast.
    /// True while `fetchByRepoId` is awaiting HuggingFace.
    @State private var isFetchingPastedRepo = false

    @State private var isSearchExpanded = false

    /// Pasted repo ids whose declared metadata says Devgentic can't run them → the reason.
    /// Only unsupported ids are stored: absence means "supported or not yet known", and the
    /// authoritative check in `fetchByRepoId` covers the not-yet-known case.
    @State private var unsupportedPastedRepos: [String: String] = [:]

    init(filterForTools: Bool = false, profileID: UUID? = nil) {
        self.filterForTools = filterForTools
        self.profileID = profileID
    }

    // Why: the detail pre-check is needed: the id is validated for emptiness only, so a typo would fail after the
    // download starts.
    /// Fetches a repo the user pasted, rather than one picked off a card.
    /// Goes through `DownloadCoordinator.startMLXDownloadIfNeeded`, like `ModelCardView.startDownload()`, so it keeps
    /// the install short-circuit, single-slot refusal and free-space preflight.
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

        // Checked before any download slot is taken: a pasted id skips the search listing, which hides unsupported models.
        if let reason = detail.unsupportedReason {
            unsupportedPastedRepos[repoId] = reason
            toastManager.show("\(repoId) is not supported. \(reason)", style: .warning)
            return
        }

        // Appended to the one toast, never a second `show` (a new toast replaces the live one).
        // A note, not a gate: the user may have accepted the licence.
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
                        // Return fetches, but only when the text is an identifier; for an ordinary query it is a no-op.
                        // Mirrors the Ollama store, whose box is both a filter and a pull field.
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

                    // Paste-a-repo-id button, gated on the text being an identifier, not on `displayedModels.isEmpty`: remote refreshes
                    // reset that array, so an emptiness gate would flicker and would miss a repo the filters hid.
                    if let repoId = MLXModelStoreViewModel.repoIdToDownload(from: viewModel.searchText),
                       let reason = unsupportedPastedRepos[repoId] {
                        // The icon-only toolbar button is replaced by a labelled, inert pill —
                        // an unexplained dimmed icon would read as "still loading".
                        Text("Not supported")
                            .font(.system(.caption, weight: .medium))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .fixedSize(horizontal: true, vertical: false)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 5)
                            .background(Capsule().fill(.secondary.opacity(0.15)))
                            .help(reason)
                            .accessibilityLabel("\(repoId) is not supported")
                            .accessibilityHint(reason)
                    } else if let repoId = MLXModelStoreViewModel.repoIdToDownload(from: viewModel.searchText) {
                        IslandIconButton(
                            symbol: "arrow.down.circle.fill",
                            style: .prominent,
                            help: "Download \(repoId) from HuggingFace (⌘↩)",
                            accessibilityLabel: "Download \(repoId) from HuggingFace",
                            // Command-Return, as the tooltip says: `.defaultAction` is a bare Return, which also fires the search field's
                            // `onSubmit`, so one keypress would have two triggers.
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
        // Pre-checks a pasted repo id so the button reads Not supported before it is pressed.
        // `.task(id:)` restarts on every keystroke, so the sleep is the debounce: a half-typed id never reaches the network.
        .task(id: MLXModelStoreViewModel.repoIdToDownload(from: viewModel.searchText)) {
            guard let repoId = MLXModelStoreViewModel.repoIdToDownload(from: viewModel.searchText),
                  unsupportedPastedRepos[repoId] == nil else { return }
            try? await Task.sleep(for: .milliseconds(400))
            guard !Task.isCancelled else { return }
            if let reason = await MLXModelService.shared.unsupportedReason(forRepo: repoId) {
                unsupportedPastedRepos[repoId] = reason
            }
        }
        .onAppear {
            if !viewModel.searchText.isEmpty {
                isSearchExpanded = true
            }
            // Re-entry is the only moment this is detectable: neither store view model refetches on appear, and the two cached
            // instances share one result array that the other may have replaced while the user was away.
            viewModel.refreshIfSharedPayloadIsForeign()
        }
    }
}
