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

    init(filterForTools: Bool = false, profileID: UUID? = nil) {
        self.filterForTools = filterForTools
        self.profileID = profileID
    }

    var body: some View {
        @Bindable var viewModel = coordinator.mlxStore(filterForTools: filterForTools)

        VStack(spacing: 0) {
            DynamicIslandBar {
                IslandSearchField(
                    text: $viewModel.searchText,
                    placeholder: viewModel.selectedCategory == .installed ? "Filter models..." : "Search Hugging Face...",
                    autoFocus: true,
                    isSearching: viewModel.isLoading,
                    accessibilityIdentifier: "mlx.store.search"
                )
            } trailing: {
                HStack(spacing: 6) {
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
    }
}
