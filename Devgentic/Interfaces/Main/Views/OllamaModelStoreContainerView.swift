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

    @StateObject private var viewModel = OllamaModelStoreViewModel()
    @Environment(\.appTheme) private var theme

    var body: some View {
        VStack(spacing: 0) {
            DynamicIslandBar {
                // Search bar in center
                HStack(spacing: 8) {
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: 12))
                        .foregroundColor(theme.secondaryText)

                    TextField("Search or enter model name to pull...", text: $viewModel.searchText)
                        .textFieldStyle(.plain)
                        .font(.system(size: 13))
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
                                .font(.system(size: 11))
                                .foregroundColor(theme.secondaryText)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 7)
                .background(
                    Capsule()
                        .fill(theme.primaryBackground.opacity(0.6))
                )
                .overlay(
                    Capsule()
                        .stroke(theme.surfaceOverlayStrong.opacity(0.3), lineWidth: 0.5)
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
                    Image(systemName: "line.3.horizontal.decrease.circle")
                        .font(.system(size: 11, weight: .medium))
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
                            .font(.system(size: 12, weight: .medium))
                            .foregroundColor(theme.accentColor)
                    }
                    .buttonStyle(.plain)
                    .help("Pull Model")
                }

                Button {
                    viewModel.refresh()
                } label: {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 11, weight: .medium))
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
        .background(theme.primaryBackground)
    }
}
