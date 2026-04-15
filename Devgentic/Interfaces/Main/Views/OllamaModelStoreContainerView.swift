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

    @State private var viewModel = OllamaModelStoreViewModel()
    @Environment(\.appTheme) private var theme

    var body: some View {
        VStack(spacing: 0) {
            DynamicIslandBar {
                // Search bar in center
                HStack(spacing: 8) {
                    Image(systemName: "magnifyingglass")
                        .font(.system(.caption))
                        .foregroundColor(theme.secondaryText)

                    TextField("Search or enter model name to pull...", text: $viewModel.searchText)
                        .textFieldStyle(.plain)
                        .font(theme.fontSubheadline)
                        .onSubmit {
                            if viewModel.displayedModels.isEmpty && !viewModel.searchText.isEmpty {
                                viewModel.downloadModel(name: viewModel.searchText)
                            }
                        }

                    if !viewModel.searchText.isEmpty {
                        Button {
                            viewModel.searchText = ""
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .font(.system(.caption))
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
                        ForEach(OllamaModelStoreViewModel.SortOption.allCases) { option in
                            Label(option.rawValue, systemImage: option.icon).tag(option)
                        }
                    }
                } label: {
                    Image(systemName: "arrow.up.arrow.down")
                        .font(.system(.caption, weight: .medium))
                        .foregroundColor(theme.accentColor)
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                .help("Sort Models")

                // Contextual Pull Button
                if viewModel.displayedModels.isEmpty && !viewModel.searchText.isEmpty {
                    Button {
                        viewModel.downloadModel(name: viewModel.searchText)
                    } label: {
                        Image(systemName: "arrow.down.circle.fill")
                            .font(.system(.caption, weight: .medium))
                            .foregroundColor(theme.accentColor)
                    }
                    .buttonStyle(.plain)
                    .help("Pull Model")
                }

                Button {
                    viewModel.refresh()
                } label: {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(.caption, weight: .medium))
                        .foregroundColor(theme.accentColor)
                }
                .buttonStyle(.plain)
                .help("Refresh Models")
            }

            OllamaModelStoreContent(
                viewModel: viewModel,
                showSearchBar: false,
                centeredLayout: true
            )
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
