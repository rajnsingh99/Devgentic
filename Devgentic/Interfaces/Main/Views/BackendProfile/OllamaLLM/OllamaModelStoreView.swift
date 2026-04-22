//
//  OllamaModelStoreView.swift
//  Devgentic
//
//  Created by Antigravity on 07/03/26.
//

import SwiftUI

struct OllamaModelStoreView: View {
    @State private var viewModel = OllamaModelStoreViewModel()
    @Environment(\.dismiss) var dismiss
    @Environment(\.appTheme) private var theme

    var body: some View {
        VStack(spacing: 0) {
            OllamaModelStoreContent(viewModel: viewModel)

            Divider().foregroundColor(theme.dividerColor)

            // MARK: - Bottom Action Bar (sheet-only)
            HStack {
                Text("\(viewModel.displayedModels.count) Models Available")
                    .font(theme.fontCaption)
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
    @Bindable var viewModel: OllamaModelStoreViewModel
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
                            viewModel.refresh(triggeredBy: .ollamaRefreshButton)
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

                            Menu {
                                Picker("Sort By", selection: $viewModel.sortOption) {
                                    ForEach(OllamaModelStoreViewModel.SortOption.allCases) { option in
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
                        .clipShape(RoundedRectangle(cornerRadius: theme.cornerRadiusMedium, style: .continuous))
                        .overlay(
                            RoundedRectangle(cornerRadius: theme.cornerRadiusMedium, style: .continuous)
                                .stroke(theme.dividerColor, lineWidth: 1)
                        )

                        // Contextual "Pull by name" affordance — replaces the
                        // old standalone Button with the shared status view,
                        // which handles in-progress / installed / available
                        // states uniformly and writes to DownloadHistoryStore
                        // via DownloadCoordinator.
                        if viewModel.displayedModels.isEmpty && !viewModel.searchText.isEmpty {
                            ModelDownloadStatusView(
                                backend: .ollama,
                                modelIdentifier: viewModel.searchText,
                                displayName: viewModel.searchText,
                                isInstalled: viewModel.displayedModels.contains { $0.name == viewModel.searchText }
                            )
                        }
                    }
                }
                .padding(20)
                .background(showSearchBar ? theme.primaryBackground : Color.clear)
            }

            // MARK: - Main Content Area
            ZStack {
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

                // Global in-flight banner intentionally omitted — the
                // Downloads sidebar already surfaces all active downloads
                // cross-backend, and `ModelDownloadStatusView` shows per-row
                // progress inline. The old floating banner here duplicated
                // that UX.
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
                .font(.system(size: 48)) // Fixed size: intentional (icon)
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
                viewModel.refresh(triggeredBy: .ollamaRefreshButton)
            }
            .buttonStyle(.bordered)
            .padding(.top, 8)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
    
    private var downloadBanner: some View {
        HStack(spacing: 16) {
            VStack(alignment: .leading, spacing: 6) {
                Text("Pulling \(viewModel.currentDownloadName)...")
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
            RoundedRectangle(cornerRadius: theme.cornerRadiusLarge, style: .continuous)
                .fill(theme.secondaryBackground)
        )
        .overlay(
            RoundedRectangle(cornerRadius: theme.cornerRadiusLarge, style: .continuous)
                .stroke(theme.surfaceOverlayStrong, lineWidth: 1)
        )
        .shadow(color: theme.primaryText.opacity(0.08), radius: 10, y: 4)
        .padding(.horizontal, 40)
        .transition(.move(edge: .bottom).combined(with: .opacity))
    }
}

struct OllamaModelCardView: View {
    let model: LocalModel
    var viewModel: OllamaModelStoreViewModel
    @State private var showingDeleteAlert = false
    @State private var isHovered = false
    @Environment(\.appTheme) private var theme

    /// Fit assessment using the model's cognitive profile metadata.
    /// Isolated per card: any unparseable metadata degrades gracefully to a neutral assessment
    /// and logs raw inputs (see ModelFitAdvisor) so we can add support for new formats.
    private var fitAssessment: ModelFitAssessment {
        ModelFitAdvisor.assess(metadata: model.cognitiveProfile.metadata, modelName: model.name)
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

            // Details
            VStack(alignment: .leading, spacing: 6) {
                // Name + Family
                HStack(alignment: .firstTextBaseline) {
                    Text(model.name)
                        .font(.headline)
                        .foregroundColor(theme.primaryText)

                    if let family = model.details?.family {
                        Text(family)
                            .font(theme.fontCaption)
                            .foregroundColor(theme.secondaryText)
                    }
                }

                // Meta info row
                if let details = model.details {
                    HStack(spacing: 12) {
                        if let size = details.parameterSize {
                            Label(size, systemImage: "memorychip")
                        }
                        if let quant = details.quantizationLevel {
                            Label(quant, systemImage: "square.3.layers.3d.down.right")
                        }
                    }
                    .font(theme.fontCaption)
                    .foregroundColor(theme.secondaryText)
                }

                // Badges + Capability + Fit
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        ForEach(model.tags) { tag in
                            HStack(spacing: 4) {
                                if let icon = tag.icon {
                                    Image(systemName: icon)
                                }
                                Text(tag.text)
                            }
                            .font(theme.fontCaption2)
                            .fontWeight(.medium)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 3)
                            .background(tag.color.opacity(0.1))
                            .foregroundColor(tag.color)
                            .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
                            .overlay(
                                RoundedRectangle(cornerRadius: 4, style: .continuous)
                                    .stroke(tag.color.opacity(0.3), lineWidth: 1)
                            )
                        }

                        // Capability Badge
                        HStack(spacing: 4) {
                            Image(systemName: capabilityIcon(for: model.cognitiveCapability))
                            Text(model.cognitiveCapability.rawValue)
                        }
                        .font(theme.fontCaption2)
                        .fontWeight(.medium)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 3)
                        .background(capabilityColor(for: model.cognitiveCapability).opacity(0.1))
                        .foregroundColor(capabilityColor(for: model.cognitiveCapability))
                        .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
                        .overlay(
                            RoundedRectangle(cornerRadius: 4, style: .continuous)
                                .stroke(capabilityColor(for: model.cognitiveCapability).opacity(0.3), lineWidth: 1)
                        )

                        if fitAssessment.estimatedRuntimeRAM > 0 {
                            ModelFitBadgeView(assessment: fitAssessment)
                        }
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
                    .clipShape(RoundedRectangle(cornerRadius: theme.cornerRadiusMedium, style: .continuous))
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
        .padding(14)
        .background(isHovered ? theme.controlBackground : theme.secondaryBackground)
        .clipShape(RoundedRectangle(cornerRadius: theme.cornerRadiusLarge, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: theme.cornerRadiusLarge, style: .continuous)
                .stroke(isHovered ? theme.accentColor.opacity(0.4) : theme.surfaceOverlayStrong, lineWidth: 1)
        )
        .shadow(color: theme.primaryText.opacity(isHovered ? 0.05 : 0.03), radius: isHovered ? 12 : 6, y: isHovered ? 6 : 3)
        .onHover { hovering in
            withAnimation(.easeOut(duration: 0.2)) {
                isHovered = hovering
            }
        }
    }

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
