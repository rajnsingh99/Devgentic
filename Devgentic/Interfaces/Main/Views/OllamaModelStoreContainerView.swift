// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
//
//  OllamaModelStoreContainerView.swift
//  Devgentic
//
//  Created by Raj Singh.
//

import SwiftUI

/// Inline wrapper for the Ollama model store inside the single-window interface, with back navigation,
/// search and refresh. Content is centered at maxWidth 1000 to match the DynamicIslandBar.
struct OllamaModelStoreContainerView: View {

    /// The profile that opened the store. See `OllamaModelStoreContent.profileID`.
    let profileID: UUID?

    init(profileID: UUID? = nil) {
        self.profileID = profileID
    }

    /// The view model is owned by `DestinationCoordinator` so it survives view re-creation when toggling
    /// destinations. Search text, sort and scroll are kept, and no server probe fires on each navigation.
    @Environment(DestinationCoordinator.self) private var coordinator

    /// Whether the current load cycle was triggered by the refresh button.
    /// Not derived from `viewModel.isLoading`, which also flips during background `OllamaService` polls.
    @State private var isManualRefreshing = false
    @State private var isSearchExpanded = false

    var body: some View {
        @Bindable var viewModel = coordinator.ollamaStore

        VStack(spacing: 0) {
            DynamicIslandBar {
                // `isSearching` is not wired to `viewModel.isLoading`: the local-model filter is synchronous,
                // and `isLoading` also flips during background server polls, which made the magnifier look stuck.
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

                    if viewModel.displayedModels.isEmpty && !viewModel.searchText.isEmpty,
                       let reason = viewModel.unsupportedPullReason {
                        // Labelled, inert pill instead of the Pull icon — a dimmed icon alone
                        // would read as "still loading".
                        Text("Not supported")
                            .font(.system(.caption, weight: .medium))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .fixedSize(horizontal: true, vertical: false)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 5)
                            .background(Capsule().fill(.secondary.opacity(0.15)))
                            .help(reason)
                            .accessibilityLabel("This model is not supported")
                            .accessibilityHint(reason)
                    } else if viewModel.displayedModels.isEmpty && !viewModel.searchText.isEmpty {
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
            // Clears the manual-refresh spinner as soon as the service reports loading has finished,
            // so it resolves even when the refresh completes faster than any timeout.
            if !newValue {
                isManualRefreshing = false
            }
        }
    }
}
