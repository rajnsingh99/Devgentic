//
//  MLXModelStoreView.swift
//  Devgentic
//
//  Created by Raj Singh on 04/02/26.
//

import SwiftUI

struct MLXModelStoreView: View {
    let filterForTools: Bool
    @State private var viewModel: MLXModelStoreViewModel
    @Environment(\.dismiss) var dismiss
    @Environment(\.appTheme) private var theme

    init(filterForTools: Bool = false) {
        self.filterForTools = filterForTools
        _viewModel = State(wrappedValue: MLXModelStoreViewModel(filterForTools: filterForTools))
    }

    var body: some View {
        VStack(spacing: 0) {
            MLXModelStoreContent(viewModel: viewModel, filterForTools: filterForTools)

            Divider().background(theme.dividerColor)

            // Bottom Action Bar — matches Ollama sheet
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
                .tint(theme.accentColor)
                .keyboardShortcut(.defaultAction)
            }
            .padding()
            .background(theme.secondaryBackground)
        }
        .frame(width: 750, height: 650)
    }
}

// MARK: - Reusable Content (shared between sheet and inline container)

struct MLXModelStoreContent: View {
    @Bindable var viewModel: MLXModelStoreViewModel
    let filterForTools: Bool
    /// When false, the search bar is hidden (it's in the DynamicIslandBar instead).
    var showSearchBar: Bool = true
    /// When true, content is centered with maxWidth: 1000 to match DynamicIslandBar width.
    var centeredLayout: Bool = false
    @Environment(\.appTheme) private var theme

    var body: some View {
        VStack(spacing: 0) {

            // MARK: - Header & Filter Bar
            VStack(spacing: showSearchBar ? 16 : 0) {
                // Title + Search — only in sheet mode
                if showSearchBar {
                    // Title Row
                    HStack {
                        Image(systemName: "square.grid.2x2.fill")
                            .font(.title2)
                            .foregroundColor(theme.accentColor)

                        Text(filterForTools ? "Agent Model Store" : "MLX Model Library")
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
                    HStack(spacing: 8) {
                        HStack {
                            Image(systemName: "magnifyingglass")
                                .foregroundColor(theme.secondaryText)

                            TextField(
                                viewModel.selectedCategory == .installed ? "Filter installed models..." : "Search Hugging Face...",
                                text: $viewModel.searchText
                            )
                            .textFieldStyle(.plain)
                            .font(.body)

                            if !viewModel.searchText.isEmpty {
                                Button {
                                    viewModel.searchText = ""
                                } label: {
                                    Image(systemName: "xmark.circle.fill")
                                        .foregroundColor(theme.secondaryText)
                                }
                                .buttonStyle(.plain)
                            }

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
                        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                        .overlay(
                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .stroke(theme.dividerColor, lineWidth: 1)
                        )
                    }
                }

                // Category Tabs
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(viewModel.availableCategories) { category in
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
            .padding(20)
            .frame(maxWidth: centeredLayout ? 1000 : .infinity)
            .frame(maxWidth: .infinity)
            .background(showSearchBar ? theme.primaryBackground : Color.clear)

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
                            .font(.system(size: 48)) // Fixed size: intentional (icon)
                            .foregroundColor(theme.secondaryText.opacity(0.5))

                        if viewModel.selectedCategory == .installed {
                            Text(filterForTools ? "No installed tool-supported models" : "No installed models")
                                .font(.title3)
                                .fontWeight(.medium)
                            Text(filterForTools ? "Download models from the 'Tool Use' tab." : "Download models from the 'All' or specific category tabs.")
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
                        .padding(20)
                        .frame(maxWidth: centeredLayout ? 1000 : .infinity)
                        .frame(maxWidth: .infinity)
                    }
                }

                // Global banner intentionally omitted — per-row
                // `ModelDownloadStatusView` handles inline progress and the
                // Downloads sidebar surfaces any active pull cross-backend.
            }
        }
    }

    private var downloadBanner: some View {
        VStack {
            Spacer()
            HStack(spacing: 16) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Downloading \(viewModel.currentDownloadName)...")
                        .font(.headline)
                        .foregroundColor(theme.primaryText)
                        .lineLimit(1)

                    ProgressView(value: viewModel.downloadProgress)
                        .controlSize(.small)
                        .tint(theme.accentColor)
                }

                Text("\(Int(viewModel.downloadProgress * 100))%")
                    .monospacedDigit()
                    .fontWeight(.bold)
                    .foregroundColor(theme.accentColor)
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
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(theme.secondaryBackground)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .stroke(theme.surfaceOverlayStrong, lineWidth: 1)
            )
            .shadow(color: theme.primaryText.opacity(0.08), radius: 10, y: 4)
            .padding(.horizontal, 40)
            .padding(.bottom, 20)
        }
        .transition(.move(edge: .bottom).combined(with: .opacity))
    }
}

// Updated Model Card to support Deletion
struct ModelCardView: View {
    let model: MLXDisplayModel
    var viewModel: MLXModelStoreViewModel
    @State private var showingDeleteAlert = false
    @State private var showingFitAdvisory = false
    @State private var isHovered = false
    @AppStorage(AppSettings.coreIntelligenceModelKey) private var coreIntelligenceModel: String = ""
    @Environment(\.appTheme) private var theme

    var isInstalled: Bool {
        viewModel.isInstalled(model)
    }

    /// Lazily computed fit assessment based on available model metadata.
    /// Isolated per card: any unparseable metadata degrades gracefully to a neutral assessment
    /// and logs raw inputs (see ModelFitAdvisor) so we can add support for new formats.
    private var fitAssessment: ModelFitAssessment {
        ModelFitAdvisor.assess(metadata: nil, diskSizeString: model.size, modelName: model.id)
    }

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            // Icon — unified 44x44, controlBackground, continuous corner
            ZStack {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(theme.controlBackground)
                    .frame(width: 44, height: 44)
                    .overlay(
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .stroke(theme.surfaceOverlayStrong, lineWidth: 1)
                    )

                Image(systemName: "cube.fill")
                    .font(.title2)
                    .foregroundColor(theme.accentColor)
            }

            VStack(alignment: .leading, spacing: 6) {
                // Name + Organization
                HStack(alignment: .firstTextBaseline) {
                    Text(model.displayName)
                        .font(.headline)
                        .foregroundColor(theme.primaryText)

                    if !model.organization.isEmpty {
                        Text(model.organization)
                            .font(.caption)
                            .foregroundColor(theme.secondaryText)
                    }
                }

                // Meta info row
                HStack(spacing: 12) {
                    if model.downloads > 0 {
                        Label("\(model.downloads.formatted())", systemImage: "arrow.down.circle")
                    }
                    if let size = model.size {
                        Label(size, systemImage: "internaldrive")
                    }
                    if viewModel.selectedCategory == .installed, let desc = model.description {
                        Text(desc)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                }
                .font(.caption)
                .foregroundColor(theme.secondaryText)

                // Badges + Fit
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        ForEach(Array(model.capabilities), id: \.self) { cap in
                            CapabilityBadge(capability: cap)
                        }

                        if model.size != nil && fitAssessment.estimatedRuntimeRAM > 0 {
                            ModelFitBadgeView(assessment: fitAssessment)
                        }
                    }
                }
            }

            Spacer(minLength: 16)

            // Actions
            VStack(alignment: .trailing, spacing: 8) {
                if isInstalled {
                    if viewModel.selectedCategory == .installed {
                        // Set as Intelligence Core
                        if coreIntelligenceModel == model.id {
                            HStack(spacing: 4) {
                                Image(systemName: "cpu.fill")
                                Text("Intelligence Core")
                            }
                            .font(.caption2)
                            .fontWeight(.semibold)
                            .foregroundColor(.purple)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .background(Color.purple.opacity(0.1))
                            .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                        } else {
                            Button {
                                coreIntelligenceModel = model.id
                            } label: {
                                Label("Set as IC", systemImage: "cpu")
                                    .font(.caption2)
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                            .help("Set as Intelligence Core model")
                        }

                        // DELETE BUTTON
                        Button(role: .destructive) {
                            showingDeleteAlert = true
                        } label: {
                            Image(systemName: "trash")
                                .foregroundColor(isHovered ? theme.errorColor : theme.secondaryText)
                                .padding(8)
                                .background(isHovered ? theme.errorColor.opacity(0.1) : Color.clear)
                                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                        }
                        .buttonStyle(.plain)
                        .help("Delete Model")
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
                        HStack(spacing: 4) {
                            Image(systemName: "checkmark.circle.fill")
                            Text("Installed")
                        }
                        .font(.caption2)
                        .fontWeight(.medium)
                        .foregroundColor(.green)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 3)
                        .background(theme.successColor.opacity(0.1))
                        .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
                        .overlay(
                            RoundedRectangle(cornerRadius: 4, style: .continuous)
                                .stroke(theme.successColor.opacity(0.3), lineWidth: 1)
                        )
                    }
                } else {
                    // Shared status view routes through DownloadCoordinator
                    // (idempotent — shortcuts to "already installed" toast
                    // if the filesystem scan lied). Fit advisory still gates
                    // the actual pull via onDownloadRequested.
                    ModelDownloadStatusView(
                        backend: .mlx,
                        modelIdentifier: model.id,
                        displayName: model.displayName,
                        isInstalled: false,
                        onDownloadRequested: {
                            let verdict = fitAssessment.verdict
                            if verdict == .risky || verdict == .incompatible {
                                showingFitAdvisory = true
                            } else {
                                // Must route through DownloadCoordinator
                                // (not `viewModel.downloadModel` directly) so
                                // the pre-seed HF size fetch fires — without
                                // it the bridge has no total bytes, the
                                // speed sampler can't compute a rate, and
                                // the UI is stuck on "calculating…".
                                Task { @MainActor in
                                    _ = await DownloadCoordinator.startMLXDownloadIfNeeded(
                                        repoId: model.id
                                    )
                                }
                            }
                        }
                    )
                }
            }
        }
        .padding(14)
        .background(isHovered ? theme.controlBackground : theme.secondaryBackground)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(isHovered ? theme.accentColor.opacity(0.4) : theme.surfaceOverlayStrong, lineWidth: 1)
        )
        .shadow(color: theme.primaryText.opacity(isHovered ? 0.05 : 0.03), radius: isHovered ? 12 : 6, y: isHovered ? 6 : 3)
        .onHover { hovering in
            withAnimation(.easeOut(duration: 0.2)) {
                isHovered = hovering
            }
        }
        .sheet(isPresented: $showingFitAdvisory) {
            ModelFitAdvisoryView(
                modelName: model.displayName,
                assessment: fitAssessment,
                onDownloadAnyway: {
                    showingFitAdvisory = false
                    // Same reason as the main Download button above —
                    // must go through DownloadCoordinator for pre-seed.
                    Task { @MainActor in
                        _ = await DownloadCoordinator.startMLXDownloadIfNeeded(
                            repoId: model.id
                        )
                    }
                },
                onDismiss: {
                    showingFitAdvisory = false
                }
            )
        }
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
            .background(isSelected ? theme.accentColor : theme.surfaceOverlay)
            .foregroundColor(isSelected ? .white : theme.primaryText)
            .clipShape(Capsule())
        }
        .buttonStyle(.plain)
    }
}
