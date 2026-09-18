// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
//
//  OllamaModelStoreView.swift
//  Devgentic
//
//  Created by Antigravity on 07/03/26.
//

import SwiftUI

// MARK: - Reusable Content (shared between sheet and inline container)

struct OllamaModelStoreContent: View {
    @Bindable var viewModel: OllamaModelStoreViewModel
    /// When false, the search bar is hidden (it's in the DynamicIslandBar instead).
    var showSearchBar: Bool = true
    /// When true, content is centered with maxWidth: 1000 to match DynamicIslandBar width.
    var centeredLayout: Bool = false
    /// The profile that opened the store, so downloads it starts are attributed to it in
    /// history. The route carried this all along; `MainApplicationView` was discarding it at
    /// the destructure, so every Ollama download was recorded with a nil profile.
    var profileID: UUID?
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
                                        Label(option.localizedTitle, systemImage: option.icon).tag(option)
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
                                isInstalled: viewModel.displayedModels.contains { $0.name == viewModel.searchText },
                                profileID: profileID
                            )
                        }
                    }
                }
                .padding(20)
                .background(showSearchBar ? theme.primaryBackground : Color.clear)
            }

            // MARK: - Failure Banner
            //
            // ⚠️ Neither of these strings was rendered anywhere. `downloadErrorMessage` had exactly
            // two references in the repo — its declaration and its assignment — and
            // `modelRemoveError` had none outside the service that writes it. A refused delete or a
            // failed pull left the store looking idle and unchanged.
            // ⚠️ Status BELOW errors in precedence, and only when there is no error to show: the
            // outcome keeps its last value after a failure, so rendering both would put two
            // descriptions of the same event side by side.
            //
            // ⚠️ THE ICON COMES FROM THE OUTCOME, NEVER FROM `isDownloading`. Deriving it from the
            // in-flight flag meant every terminal state that was not "in progress" rendered as
            // success — so "Download cancelled." and "Failed to pull X." both got a green tick the
            // instant the pull stopped. A phase cannot answer "did this succeed?".
            if viewModel.deleteErrorMessage == nil,
               viewModel.downloadErrorMessage == nil,
               let status = viewModel.pullStatus {
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: pullStatusIcon(for: status))
                        .foregroundColor(pullStatusColor(for: status))
                        .accessibilityHidden(true)
                    Text(status.message)
                        .font(theme.fontCaption)
                        .foregroundColor(theme.primaryText)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 8)
                    // ⚠️ A banner with no way out is a banner that lives forever. This one used to
                    // persist for the rest of the process: it had no dismiss control, and the only
                    // thing that reset the underlying value had no callers.
                    if status.isTerminal {
                        Button {
                            viewModel.dismissPullStatus()
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .foregroundColor(theme.secondaryText)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Dismiss pull status")
                    }
                }
                .padding(12)
                .background(theme.secondaryBackground.opacity(0.5))
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .padding(.horizontal, 20)
                .padding(.bottom, 8)
            }

            if let message = viewModel.deleteErrorMessage ?? viewModel.downloadErrorMessage {
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundColor(theme.errorColor)
                        .accessibilityHidden(true)
                    Text(message)
                        .font(theme.fontCaption)
                        .foregroundColor(theme.primaryText)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 8)
                    Button {
                        viewModel.dismissErrors()
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundColor(theme.secondaryText)
                    }
                    .buttonStyle(.plain)
                    .help("Dismiss")
                    .accessibilityLabel("Dismiss error")
                }
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(theme.errorColor.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
                .padding(.horizontal, 16)
                .padding(.bottom, 8)
                .accessibilityElement(children: .combine)
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
    
    // ⚠️ register A42 — `downloadBanner` was removed here. It was declared and never called, and
    // it was the ONLY reader of `viewModel.downloadProgress` / `.currentDownloadName`, which the
    // view model mirrored on every NDJSON line of a pull (a full re-filter and re-sort of the grid
    // per tick) to feed a view nothing rendered. Live per-row progress is `ModelDownloadStatusView`
    // above, backed by `DownloadManager`.
    //
    // ⚠️ ADJACENT GAP, deliberately not closed here: this banner held the only Cancel affordance
    // for an Ollama pull, so `OllamaModelStoreViewModel.cancelDownload()` is now unreferenced.
    // Deleting it would remove the only implementation of a capability users arguably want, and
    // wiring a new Cancel control is a feature decision, not part of A42. Left for its own finding.

    /// ⚠️ Exhaustive, no `default:` — a new outcome must fail the build here rather than silently
    /// inherit another state's icon. Inheriting silently is exactly how cancellation and failure
    /// came to render as success.
    private func pullStatusIcon(for status: OllamaService.PullTerminalState) -> String {
        switch status {
        case .started:   return "arrow.down.circle"
        case .succeeded: return "checkmark.circle.fill"
        case .cancelled: return "slash.circle"
        case .failed:    return "exclamationmark.triangle.fill"
        }
    }

    /// ⚠️ `.cancelled` is deliberately NEITHER green NOR red: the user asked for it, so it is not
    /// a success to celebrate and not an error to alarm them about.
    private func pullStatusColor(for status: OllamaService.PullTerminalState) -> Color {
        switch status {
        case .started:   return theme.accentColor
        case .succeeded: return theme.successColor
        case .cancelled: return theme.secondaryText
        case .failed:    return theme.errorColor
        }
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
                            Text(model.cognitiveCapability.localizedTitle)
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

// MARK: - Localizable Labels
//
// This lives here rather than beside the enum declaration on purpose:
// `OllamaModelStoreViewModel.SortOption` is declared in the view model, which is
// not part of this change's file scope.
//
// `ModelCognitiveCapability.localizedTitle` (used by the capability badge above)
// is declared once in `AgentConfigDetailView.swift` — its enum lives in
// `BackendProfile.swift`, a `Foundation`-only model file that must not import SwiftUI.

extension OllamaModelStoreViewModel.SortOption {
    /// User-facing name. ⚠️ Separate from `rawValue` on purpose: `Text(x.rawValue)` /
    /// `Label(x.rawValue, …)` bind to the non-localizing `StringProtocol` overload, so every
    /// rawValue-sourced label was invisible to the String Catalog extractor and would have
    /// shipped untranslated inside otherwise-translated chrome. `rawValue` stays for
    /// persistence, `id`, and logging only.
    var localizedTitle: LocalizedStringKey {
        switch self {
        case .name: return "Name"
        case .size: return "Size"
        }
    }
}
