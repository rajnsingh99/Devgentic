//
//  OllamaModelStoreView.swift
//  Devgentic
//
//  Created by Antigravity on 07/03/26.
//

import SwiftUI

struct OllamaModelStoreView: View {
    @StateObject private var viewModel = OllamaModelStoreViewModel()
    @Environment(\.dismiss) var dismiss
    @Environment(\.appTheme) private var theme

    var body: some View {
        VStack(spacing: 0) {
            OllamaModelStoreContent(viewModel: viewModel)

            Divider().foregroundColor(theme.dividerColor)

            // MARK: - Bottom Action Bar (sheet-only)
            HStack {
                Text("\(viewModel.displayedModels.count) Models Available")
                    .font(.caption)
                    .foregroundColor(theme.secondaryText)

                Spacer()

                Button("Done") {
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .keyboardShortcut(.defaultAction)
            }
            .padding()
            .background(theme.secondaryBackground)
        }
        // Strict outer frame. Because of the GeometryReader inside, this will be strictly respected.
        .frame(width: 750, height: 650)
    }
}

// MARK: - Reusable Content (shared between sheet and inline container)

struct OllamaModelStoreContent: View {
    @ObservedObject var viewModel: OllamaModelStoreViewModel
    /// When false, the search bar is hidden (it's in the DynamicIslandBar instead).
    var showSearchBar: Bool = true
    /// When true, content is centered with maxWidth: 1000 to match DynamicIslandBar width.
    var centeredLayout: Bool = false
    @Environment(\.appTheme) private var theme

    var body: some View {
        VStack(spacing: 0) {
            // MARK: - Header & Search Area
            if showSearchBar {
                VStack(spacing: 16) {
                    // Title Row
                    HStack {
                        Image(systemName: "shippingbox.fill")
                            .font(.title2)
                            .foregroundColor(theme.accentColor)

                        Text("Ollama Model Library")
                            .font(.title2)
                            .fontWeight(.bold)
                            .foregroundColor(theme.primaryText)

                        Spacer()

                        Button {
                            viewModel.refresh()
                        } label: {
                            Image(systemName: "arrow.clockwise")
                                .font(.body)
                                .foregroundColor(theme.secondaryText)
                        }
                        .buttonStyle(.plain)
                        .help("Refresh Models")
                    }

                    // Search & Actions Row
                    HStack(spacing: 12) {
                        // Custom Search Field
                        HStack {
                            Image(systemName: "magnifyingglass")
                                .foregroundColor(theme.secondaryText)

                            TextField("Search installed models or enter name to pull...", text: $viewModel.searchText)
                                .textFieldStyle(.plain)
                                .font(.body)
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
                                        .foregroundColor(theme.secondaryText)
                                }
                                .buttonStyle(.plain)
                            }
                        }
                        .padding(10)
                        .background(theme.secondaryBackground)
                        .cornerRadius(8)
                        .overlay(
                            RoundedRectangle(cornerRadius: 8)
                                .stroke(theme.dividerColor, lineWidth: 1)
                        )

                        // Sort Menu
                        Menu {
                            Picker("Sort By", selection: $viewModel.sortOption) {
                                ForEach(OllamaModelStoreViewModel.SortOption.allCases) { option in
                                    Label(option.rawValue, systemImage: option.icon).tag(option)
                                }
                            }
                        } label: {
                            Label("Sort", systemImage: "line.3.horizontal.decrease.circle")
                        }
                        .menuStyle(.borderlessButton)
                        .fixedSize()
                        .help("Sort Models")

                        // Contextual Pull Button
                        if viewModel.displayedModels.isEmpty && !viewModel.searchText.isEmpty {
                            Button {
                                viewModel.downloadModel(name: viewModel.searchText)
                            } label: {
                                Label("Pull Model", systemImage: "arrow.down.circle.fill")
                            }
                            .buttonStyle(.borderedProminent)
                            .tint(theme.accentColor)
                        }
                    }
                }
                .padding(20)
                .background(theme.primaryBackground)

                Divider().foregroundColor(theme.dividerColor)
            }

            // MARK: - Main Content Area
            ZStack {
                theme.primaryBackground

                if viewModel.isLoading && viewModel.displayedModels.isEmpty {
                    loadingState
                } else if viewModel.displayedModels.isEmpty {
                    emptyState
                } else {
                    ScrollView {
                        LazyVStack(spacing: 12) {
                            ForEach(viewModel.displayedModels) { model in
                                OllamaModelCardView(model: model, viewModel: viewModel)
                            }
                        }
                        .padding(20)
                        .frame(maxWidth: centeredLayout ? 1000 : .infinity)
                        .frame(maxWidth: .infinity)
                    }
                }

                // Floating Download Banner
                if viewModel.isDownloading {
                    VStack {
                        Spacer()
                        downloadBanner
                            .padding(.bottom, 20)
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    // MARK: - Subviews

    private var loadingState: some View {
        VStack(spacing: 16) {
            ProgressView()
                .controlSize(.large)
            Text("Fetching local models...")
                .foregroundColor(theme.secondaryText)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
    
    private var emptyState: some View {
        VStack(spacing: 16) {
            Image(systemName: "externaldrive.badge.xmark")
                .font(.system(size: 48))
                .foregroundColor(theme.secondaryText.opacity(0.5))
            
            Text(viewModel.searchText.isEmpty ? "No local models found" : "No matching models")
                .font(.title3)
                .fontWeight(.medium)
            
            if !viewModel.searchText.isEmpty {
                Text("Press Enter or click 'Pull Model' to download '\(viewModel.searchText)'")
                    .foregroundColor(theme.secondaryText)
                    .font(.callout)
            } else {
                Text("Ensure Ollama is running and you have models pulled.")
                    .foregroundColor(theme.secondaryText)
                    .font(.callout)
            }
            
            Button("Refresh Connection") {
                viewModel.refresh()
            }
            .buttonStyle(.bordered)
            .padding(.top, 8)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
    
    private var downloadBanner: some View {
        HStack(spacing: 16) {
            VStack(alignment: .leading, spacing: 6) {
                Text("Pulling \(viewModel.currentDownloadName)")
                    .font(.headline)
                    .lineLimit(1)
                
                ProgressView(value: viewModel.downloadProgress)
                    .progressViewStyle(.linear)
                    .tint(.blue)
            }
            
            Text("\(Int(viewModel.downloadProgress * 100))%")
                .monospacedDigit()
                .fontWeight(.bold)
                .foregroundColor(.blue)
                .frame(width: 50, alignment: .trailing)
            
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
        .padding(16)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(theme.secondaryBackground)
                .shadow(color: .black.opacity(0.2), radius: 10, x: 0, y: 4)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(theme.dividerColor, lineWidth: 1)
        )
        .padding(.horizontal, 40)
        .transition(.move(edge: .bottom).combined(with: .opacity))
        .animation(.spring(), value: viewModel.isDownloading)
    }
}

struct OllamaModelCardView: View {
    let model: LocalModel
    @ObservedObject var viewModel: OllamaModelStoreViewModel
    @State private var showingDeleteAlert = false
    @Environment(\.appTheme) private var theme
    
    // Hover state for modern macOS feel
    @State private var isHovered = false
    
    var body: some View {
        HStack(alignment: .top, spacing: 16) {
            // Icon
            ZStack {
                RoundedRectangle(cornerRadius: 10)
                    .fill(theme.secondaryBackground)
                    .frame(width: 48, height: 48)
                    .overlay(
                        RoundedRectangle(cornerRadius: 10)
                            .stroke(theme.dividerColor, lineWidth: 1)
                    )
                
                Image(systemName: "cpu")
                    .font(.title2)
                    .foregroundColor(theme.accentColor)
            }
            
            // Details
            VStack(alignment: .leading, spacing: 8) {
                Text(model.name)
                    .font(.headline)
                    .foregroundColor(theme.primaryText)
                
                // Meta info (Size, Quant, Family)
                if let details = model.details {
                    HStack(spacing: 12) {
                        if let size = details.parameterSize {
                            Label(size, systemImage: "memorychip")
                        }
                        if let quant = details.quantizationLevel {
                            Label(quant, systemImage: "square.3.layers.3d.down.right")
                        }
                        if let family = details.family {
                            Label(family, systemImage: "network")
                        }
                    }
                    .font(.caption)
                    .foregroundColor(theme.secondaryText)
                }
                
                // Badges & Capabilities
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        // Tags
                        ForEach(model.tags) { tag in
                            HStack(spacing: 4) {
                                if let icon = tag.icon {
                                    Image(systemName: icon)
                                }
                                Text(tag.text)
                            }
                            .font(.caption2)
                            .fontWeight(.medium)
                            .padding(.vertical, 4)
                            .padding(.horizontal, 8)
                            .background(tag.color.opacity(0.1))
                            .foregroundColor(tag.color)
                            .cornerRadius(6)
                        }
                        
                        // Capability Badge
                        HStack(spacing: 4) {
                            Image(systemName: capabilityIcon(for: model.cognitiveCapability))
                            Text(model.cognitiveCapability.rawValue)
                        }
                        .font(.caption2)
                        .fontWeight(.bold)
                        .padding(.vertical, 4)
                        .padding(.horizontal, 8)
                        .background(capabilityColor(for: model.cognitiveCapability).opacity(0.1))
                        .foregroundColor(capabilityColor(for: model.cognitiveCapability))
                        .cornerRadius(6)
                    }
                }
            }
            
            Spacer(minLength: 16)
            
            // Actions
            Button(role: .destructive) {
                showingDeleteAlert = true
            } label: {
                Image(systemName: "trash")
                    .foregroundColor(isHovered ? theme.errorColor : theme.secondaryText)
                    .padding(8)
                    .background(isHovered ? theme.errorColor.opacity(0.1) : Color.clear)
                    .cornerRadius(8)
            }
            .buttonStyle(.plain)
            .help("Delete Model")
            .alert("Delete Model?", isPresented: $showingDeleteAlert) {
                Button("Delete", role: .destructive) {
                    viewModel.deleteModel(model)
                }
                Button("Cancel", role: .cancel) { }
            } message: {
                Text("Are you sure you want to delete '\(model.name)'? This will permanently remove the files from your local Ollama storage.")
            }
        }
        .padding(16)
        .background(isHovered ? theme.secondaryBackground.opacity(0.5) : theme.primaryBackground)
        .cornerRadius(12)
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(isHovered ? theme.accentColor.opacity(0.5) : theme.dividerColor, lineWidth: 1)
        )
        .onHover { hovering in
            withAnimation(.easeInOut(duration: 0.15)) {
                isHovered = hovering
            }
        }
    }
    
    // Helper colors/icons duplicated from detail views or centralized
    private func capabilityIcon(for capability: ModelCognitiveCapability) -> String {
        switch capability {
        case .parallelActions: return "bolt.fill"
        case .singleAction: return "wrench.fill"
        case .none: return "message.fill"
        }
    }
    
    private func capabilityColor(for capability: ModelCognitiveCapability) -> Color {
        switch capability {
        case .parallelActions: return .purple
        case .singleAction: return .blue
        case .none: return .green
        }
    }
}
