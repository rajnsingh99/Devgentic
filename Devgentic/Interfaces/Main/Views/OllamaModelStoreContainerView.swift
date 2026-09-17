// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2026 Raj Singh
//
//  OllamaModelStoreContainerView.swift
//  Devgentic
//
//  Created by Raj Singh on 19/03/26.
//
//  Inline wrapper for the Ollama model store that renders within
//  the single-window interface. Uses DynamicIslandBar for back
//  navigation, search, and refresh. Content is centered at
//  maxWidth: 1000 to match the DynamicIslandBar width.
//

import SwiftUI

struct OllamaModelStoreContainerView: View {

    /// The profile that opened the store. See `OllamaModelStoreContent.profileID`.
    let profileID: UUID?

    init(profileID: UUID? = nil) {
        self.profileID = profileID
    }

    /// View model is owned by `DestinationCoordinator` so it survives the view
    /// re-creation cascade when the user toggles between chat and non-chat
    /// destinations. Previously `@State private var viewModel = ...` got
    /// recreated on every navigation, losing search text / sort / scroll and
    /// (pre-defensive-patch) firing a full server probe each time.
    @Environment(DestinationCoordinator.self) private var coordinator

    /// Tracks whether the current load cycle was triggered by the user tapping refresh.
    /// We can't derive this from `viewModel.isLoading` because that flag also flips true
    /// during background `OllamaService` polls — tying the refresh-button spinner directly
    /// to `isLoading` made the button pulse whenever the service polled in the background.
    @State private var isManualRefreshing = false
    @State private var isSearchExpanded = false

    var body: some View {
        @Bindable var viewModel = coordinator.ollamaStore

        VStack(spacing: 0) {
            DynamicIslandBar {
                // NOTE: `isSearching` is intentionally NOT wired to `viewModel.isLoading`.
                // Ollama's local-model filter is synchronous/client-side; typing does
                // not kick off an async query. Meanwhile `viewModel.isLoading` bridges
                // `OllamaService.isLoadingModels`, which also flips true during
                // background server-status polls — surfacing that as a "search in
                // progress" spinner made the magnifying glass appear stuck.
                IslandExpandableSearchHeader(
                    title: "Ollama Models",
                    icon: "shippingbox.fill",
                    text: $viewModel.searchText,
                    placeholder: "Search or enter model name to pull",
                    isExpanded: $isSearchExpanded,
                    accessibilityIdentifier: "ollama.store.search",
                    onSubmit: {
                        if viewModel.displayedModels.isEmpty && !viewModel.searchText.isEmpty {
                            viewModel.downloadModel(name: viewModel.searchText)
                        }
                    }
                )
            } trailing: {
                HStack(spacing: 6) {
                    IslandSearchToggleButton(isExpanded: $isSearchExpanded)

                    // Sort is client-side; don't disable it while the service polls.
                    Menu {
                        Picker("Sort By", selection: $viewModel.sortOption) {
                            ForEach(OllamaModelStoreViewModel.SortOption.allCases) { option in
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

                    if viewModel.displayedModels.isEmpty && !viewModel.searchText.isEmpty {
                        IslandIconButton(
                            symbol: "arrow.down.circle.fill",
                            style: .prominent,
                            help: "Pull Model (⌘↩)",
                            accessibilityLabel: "Pull model",
                            keyboardShortcut: KeyboardShortcut(.return, modifiers: .command)
                        ) {
                            viewModel.downloadModel(name: viewModel.searchText)
                        }
                    }

                    // Spinner shows only for user-initiated refreshes, not for every
                    // background poll that flips `viewModel.isLoading` true/false.
                    IslandIconButton(
                        symbol: "arrow.clockwise",
                        help: "Refresh Models (⌘R)",
                        accessibilityLabel: "Refresh models",
                        keyboardShortcut: KeyboardShortcut("r", modifiers: .command),
                        isLoading: isManualRefreshing
                    ) {
                        isManualRefreshing = true
                        // UserAction token confirms this is the button-tap path
                        // (not an init / onChange / observer callback). See UserAction.swift.
                        viewModel.refresh(triggeredBy: .ollamaRefreshButton)
                    }
                }
            }

            OllamaModelStoreContent(
                viewModel: viewModel,
                showSearchBar: false,
                centeredLayout: true,
                profileID: profileID
            )
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear {
            if !viewModel.searchText.isEmpty {
                isSearchExpanded = true
            }
        }
        .onChange(of: viewModel.isLoading) { _, newValue in
            // Clear the manual-refresh spinner as soon as the service reports
            // loading has finished. Guarantees the spinner resolves even if the
            // refresh completes faster than any timeout we could pick.
            if !newValue {
                isManualRefreshing = false
            }
        }
    }
}
