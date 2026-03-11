//
//  MLXModelStoreView.swift
//  Devgentic
//
//  Created by Raj Singh on 04/02/26.
//

import SwiftUI

struct MLXModelStoreView: View {
    @StateObject private var viewModel = MLXModelStoreViewModel()
    @Environment(\.dismiss) var dismiss
    @Environment(\.appTheme) private var theme
    
    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                
                // MARK: - Header & Filter Bar
                VStack(spacing: 16) {
                    // Search Input & Controls
                    HStack(spacing: 8) {
                        // Search Field
                        HStack {
                            Image(systemName: "magnifyingglass")
                                .foregroundColor(theme.secondaryText)
                            
                            TextField(
                                viewModel.selectedCategory == .installed ? "Filter fetched models..." : "Search Hugging Face...",
                                text: $viewModel.searchText
                            )
                            .textFieldStyle(.plain)
                            .font(.body)
                            
                            // Sort Menu (Moved inside Search Box)
                            Menu {
                                Picker("Sort By", selection: $viewModel.sortOption) {
                                    ForEach(MLXModelStoreViewModel.SortOption.allCases) { option in
                                        Label(option.rawValue, systemImage: option.icon).tag(option)
                                    }
                                }
                            } label: {
                                Image(systemName: "arrow.up.arrow.down")
                                    .font(.body)
                                    .foregroundColor(theme.secondaryText)
                                    .padding(.horizontal, 8)
                                    .contentShape(Rectangle())
                            }
                            .menuStyle(.borderlessButton)
                            .help("Sort Models")
                        }
                        .padding(10)
                        .background(theme.secondaryBackground)
                        .cornerRadius(8)
                        .overlay(
                            RoundedRectangle(cornerRadius: 8)
                                .stroke(theme.dividerColor, lineWidth: 1)
                        )
                    }
                    
                    // Category Tabs
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 8) {
                            ForEach(MLXModelStoreViewModel.StoreCategory.allCases) { category in
                                CategoryTabButton(
                                    category: category,
                                    isSelected: viewModel.selectedCategory == category
                                ) {
                                    viewModel.selectedCategory = category
                                }
                            }
                        }
                        .padding(.horizontal, 2)
                    }
                }
                .padding()
                .background(theme.primaryBackground)
                .overlay(Rectangle().frame(height: 1).foregroundColor(theme.dividerColor), alignment: .bottom)
                
                // MARK: - Main Content Area
                ZStack {
                    if viewModel.isLoading && viewModel.displayedModels.isEmpty {
                        VStack(spacing: 16) {
                            ProgressView()
                                .controlSize(.large)
                            Text("Fetching \(viewModel.selectedCategory.rawValue) models...")
                                .foregroundColor(theme.secondaryText)
                        }
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        
                    } else if viewModel.displayedModels.isEmpty {
                        VStack(spacing: 12) {
                            Image(systemName: viewModel.selectedCategory == .installed ? "externaldrive" : "magnifyingglass")
                                .font(.system(size: 48))
                                .foregroundColor(theme.secondaryText.opacity(0.5))
                            
                            if viewModel.selectedCategory == .installed {
                                Text("No installed models")
                                    .font(.title3)
                                    .fontWeight(.medium)
                                Text("Download models from the 'All' or specific category tabs.")
                                    .foregroundColor(theme.secondaryText)
                            } else {
                                Text("No models found")
                                    .font(.title3)
                                    .fontWeight(.medium)
                                Button("Try Reloading") {
                                    viewModel.refresh()
                                }
                            }
                        }
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        
                    } else {
                        ScrollView {
                            LazyVStack(spacing: 12) {
                                ForEach(viewModel.displayedModels) { model in
                                    ModelCardView(model: model, viewModel: viewModel)
                                }
                                
                                // PAGINATION BUTTON
                                if viewModel.selectedCategory != .installed && !viewModel.displayedModels.isEmpty {
                                    Button {
                                        viewModel.loadMore()
                                    } label: {
                                        HStack {
                                            if viewModel.isLoading {
                                                ProgressView().controlSize(.small)
                                            }
                                            Text("Load More Models")
                                        }
                                        .frame(maxWidth: .infinity)
                                        .padding()
                                    }
                                    .buttonStyle(.borderless)
                                    .disabled(viewModel.isLoading)
                                    .padding(.top, 8)
                                }
                            }
                            .padding()
                        }
                    }
                    
                    // MARK: - Download Status Banner
                    if viewModel.isDownloading {
                        downloadBanner
                    }
                }
            }
            .navigationTitle("Model Store")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
                ToolbarItem(placement: .automatic) {
                    Button {
                        viewModel.refresh()
                    } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                    .help("Refresh Store")
                }
            }
        }
        .frame(minWidth: 700, minHeight: 600)
    }
    
    private var downloadBanner: some View {
        VStack {
            Spacer()
            HStack(spacing: 16) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Downloading \(viewModel.currentDownloadName)...")
                        .font(.headline)
                        .lineLimit(1)
                    
                    ProgressView(value: viewModel.downloadProgress)
                        .controlSize(.small)
                        .tint(.blue)
                }
                
                Spacer()
                
                Text("\(Int(viewModel.downloadProgress * 100))%")
                    .monospacedDigit()
                    .fontWeight(.bold)
                
                Button {
                    viewModel.cancelDownload()
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.title2)
                        .foregroundColor(theme.secondaryText)
                }
                .buttonStyle(.plain)
                .help("Cancel Download")
            }
            .padding()
            .background(.regularMaterial)
            .cornerRadius(12)
            .shadow(color: .black.opacity(0.15), radius: 10, x: 0, y: 5)
            .padding()
        }
        .transition(.move(edge: .bottom).combined(with: .opacity))
    }
}

// Updated Model Card to support Deletion
struct ModelCardView: View {
    let model: MLXDisplayModel
    @ObservedObject var viewModel: MLXModelStoreViewModel
    @State private var showingDeleteAlert = false // Local state for delete confirmation
    @Environment(\.appTheme) private var theme
    
    var isInstalled: Bool {
        viewModel.isInstalled(model)
    }
    
    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            ZStack {
                RoundedRectangle(cornerRadius: 12)
                    .fill(theme.dividerColor)
                    .frame(width: 52, height: 52)
                
                Image(systemName: "cube.fill")
                    .font(.title)
                    .foregroundColor(theme.secondaryText)
            }
            
            VStack(alignment: .leading, spacing: 6) {
                HStack(alignment: .firstTextBaseline) {
                    Text(model.displayName)
                        .font(.headline)
                        .foregroundColor(.primary)
                    
                    if !model.organization.isEmpty {
                        Text(model.organization)
                            .font(.caption)
                            .foregroundColor(theme.secondaryText)
                    }
                }
                
                // Badges
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack {
                        ForEach(Array(model.capabilities), id: \.self) { cap in
                            CapabilityBadge(capability: cap)
                        }
                    }
                }
                
                HStack(spacing: 12) {
                    if model.downloads > 0 {
                        Label("\(model.downloads.formatted())", systemImage: "arrow.down.circle")
                    }
                    if let size = model.size {
                        Text("• \(size)")
                    }
                    // For installed models, show path
                    if viewModel.selectedCategory == .installed, let desc = model.description {
                        Text("• \(desc)")
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                }
                .font(.caption2)
                .foregroundColor(theme.secondaryText)
            }
            
            Spacer()
            
            VStack(alignment: .trailing) {
                if isInstalled {
                    if viewModel.selectedCategory == .installed {
                        // DELETE BUTTON (Only in Installed Tab)
                        Button(role: .destructive) {
                            showingDeleteAlert = true
                        } label: {
                            Label("Delete", systemImage: "trash")
                        }
                        .controlSize(.regular)
                        .alert("Delete Model?", isPresented: $showingDeleteAlert) {
                            Button("Delete", role: .destructive) {
                                viewModel.deleteModel(model)
                            }
                            Button("Cancel", role: .cancel) { }
                        } message: {
                            Text("Are you sure you want to delete '\(model.displayName)'? This will permanently remove the files from your disk.")
                        }
                    } else {
                        // INSTALLED BADGE (In other tabs)
                        HStack {
                            Image(systemName: "checkmark.circle.fill")
                            Text("Installed")
                        }
                        .font(.subheadline)
                        .foregroundColor(.green)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background(Color.green.opacity(0.1))
                        .cornerRadius(6)
                    }
                } else {
                    Button {
                        viewModel.downloadModel(model)
                    } label: {
                        if viewModel.isDownloading && viewModel.currentDownloadName == model.id {
                            ProgressView().controlSize(.small).frame(width: 60)
                        } else {
                            Text("Get").fontWeight(.medium).frame(minWidth: 60)
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.regular)
                    .disabled(viewModel.isDownloading && viewModel.currentDownloadName != model.id)
                }
            }
        }
        .padding(12)
        .background(theme.secondaryBackground)
        .cornerRadius(12)
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(theme.dividerColor, lineWidth: 1)
        )
    }
}

// Re-added the Tab Button helper
struct CategoryTabButton: View {
    let category: MLXModelStoreViewModel.StoreCategory
    let isSelected: Bool
    let action: () -> Void
    @Environment(\.appTheme) private var theme
    
    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: category.icon)
                Text(category.rawValue)
            }
            .font(.subheadline.weight(isSelected ? .semibold : .regular))
            .padding(.vertical, 6)
            .padding(.horizontal, 12)
            .background(isSelected ? Color.accentColor : theme.dividerColor)
            .foregroundColor(isSelected ? .white : .primary)
            .cornerRadius(20)
        }
        .buttonStyle(.plain)
    }
}
