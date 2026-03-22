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

    @StateObject private var viewModel: MLXModelStoreViewModel
    @Environment(\.appTheme) private var theme

    init(filterForTools: Bool = false) {
        self.filterForTools = filterForTools
        _viewModel = StateObject(wrappedValue: MLXModelStoreViewModel(filterForTools: filterForTools))
    }

    var body: some View {
        VStack(spacing: 0) {
            DynamicIslandBar {
                // Search bar in center
                HStack(spacing: 8) {
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: 12))
                        .foregroundColor(theme.secondaryText)

                    TextField(
                        viewModel.selectedCategory == .installed ? "Filter models..." : "Search Hugging Face...",
                        text: $viewModel.searchText
                    )
                    .textFieldStyle(.plain)
                    .font(.system(size: 13))

                    if !viewModel.searchText.isEmpty {
                        Button {
                            viewModel.searchText = ""
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .font(.system(size: 11))
                                .foregroundColor(theme.secondaryText)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 7)
                .background(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(theme.primaryBackground)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .stroke(theme.dividerColor, lineWidth: 1)
                )
            } trailing: {
                // Sort menu
                Menu {
                    Picker("Sort By", selection: $viewModel.sortOption) {
                        ForEach(MLXModelStoreViewModel.SortOption.allCases) { option in
                            Label(option.rawValue, systemImage: option.icon).tag(option)
                        }
                    }
                } label: {
                    Image(systemName: "arrow.up.arrow.down")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(theme.accentColor)
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                .help("Sort Models")

                Button {
                    viewModel.refresh()
                } label: {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(theme.accentColor)
                }
                .buttonStyle(.plain)
                .help("Refresh Store")
            }

            MLXModelStoreContent(
                viewModel: viewModel,
                filterForTools: filterForTools,
                showSearchBar: false,
                centeredLayout: true
            )
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(theme.primaryBackground)
    }
}
