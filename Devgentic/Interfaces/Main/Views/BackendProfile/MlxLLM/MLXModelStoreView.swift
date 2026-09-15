// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2026 Raj Singh
//
//  MLXModelStoreView.swift
//  Devgentic
//
//  Created by Raj Singh on 04/02/26.
//

import SwiftUI

// MARK: - Reusable Content (shared between sheet and inline container)

struct MLXModelStoreContent: View {
    @Bindable var viewModel: MLXModelStoreViewModel
    let filterForTools: Bool
    /// Threaded down to the download records. See `ModelCardView.profileID`.
    var profileID: UUID?
    /// When false, the search bar is hidden (it's in the DynamicIslandBar instead).
    var showSearchBar: Bool = true
    /// When true, content is centered with maxWidth: 1000 to match DynamicIslandBar width.
    var centeredLayout: Bool = false
    /// Presents the inline token field from the 401 state and the gated badge.
    @State private var showingTokenEntry = false
    @Environment(\.appTheme) private var theme

    private var hasActiveFilters: Bool {
        !viewModel.searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || viewModel.quantizationFilter != nil
            || viewModel.fitsMyMacOnly
            || (filterForTools && viewModel.showToolCapableOnly)
    }

    private func resetFilters() {
        viewModel.searchText = ""
        viewModel.quantizationFilter = nil
        viewModel.fitsMyMacOnly = false
        if filterForTools {
            viewModel.showToolCapableOnly = false
        }
    }

    private var emptyStateIcon: String {
        if viewModel.loadError != nil { return "exclamationmark.icloud" }
        if hasActiveFilters { return "line.3.horizontal.decrease.circle" }
        return viewModel.selectedCategory == .installed ? "externaldrive" : "magnifyingglass"
    }

    /// A short headline per failure class. The body carries the full message.
    private func errorTitle(for error: HFRequestError) -> String {
        switch error {
        case .rateLimited:      return "Too many requests"
        case .unauthorized:     return "Access token required"
        case .notFound:         return "Not found"
        case .serverError:      return "HuggingFace is unavailable"
        case .offline:          return "You're offline"
        case .malformedResponse, .invalidURL: return "Couldn't load models"
        }
    }

    var body: some View {
        VStack(spacing: 0) {

            // MARK: - Header & Filter Bar
            VStack(spacing: showSearchBar ? 16 : 12) {
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

                // Filter & Storage Toolbar Row
                HStack(spacing: 10) {
                    // Quantization picker
                    //
                    // ⚠️ Read ONCE into a local. `availableQuantizations` is a computed property,
                    // and `Menu`'s content builder runs immediately, so reading it here and again
                    // inside the menu evaluated it twice per body — and on the Installed tab each
                    // evaluation re-parses every installed repo id. The body re-evaluates on every
                    // observer tick, so a 20-model library paid for it ~30 times per page load.
                    let quantizations = viewModel.availableQuantizations
                    if quantizations.count > 1 || viewModel.quantizationFilter != nil {
                        Menu {
                            Button("Any Quantization") { viewModel.quantizationFilter = nil }
                            Divider()
                            ForEach(quantizations, id: \.self) { quant in
                                Button(quant.localizedTitle) { viewModel.quantizationFilter = quant }
                            }
                        } label: {
                            HStack(spacing: 5) {
                                Image(systemName: viewModel.quantizationFilter != nil ? "square.stack.3d.down.right.fill" : "square.stack.3d.down.right")
                                    .font(.caption2)
                                    .foregroundColor(viewModel.quantizationFilter != nil ? theme.accentColor : theme.secondaryText)
                                Text(viewModel.quantizationFilter?.localizedTitle ?? "Quantization: Any")
                                    .font(.caption)
                                    .foregroundColor(viewModel.quantizationFilter != nil ? theme.primaryText : theme.secondaryText)
                                Image(systemName: "chevron.down")
                                    .font(.system(size: 8, weight: .bold))
                                    .foregroundColor(viewModel.quantizationFilter != nil ? theme.accentColor : theme.secondaryText)
                            }
                            .padding(.horizontal, 9)
                            .padding(.vertical, 5)
                            .background(
                                RoundedRectangle(cornerRadius: 6, style: .continuous)
                                    .fill(viewModel.quantizationFilter != nil ? theme.accentColor.opacity(0.12) : theme.surfaceOverlay)
                            )
                            .overlay(
                                RoundedRectangle(cornerRadius: 6, style: .continuous)
                                    .strokeBorder(viewModel.quantizationFilter != nil ? theme.accentColor.opacity(0.4) : theme.surfaceOverlayStrong, lineWidth: 0.5)
                            )
                        }
                        .buttonStyle(.plain)
                        .menuIndicator(.hidden)
                        .help("Filter by bit-depth quantization (e.g. 4-bit, 8-bit, 16-bit).")
                    }

                    // "Fits my Mac" toggle chip
                    if viewModel.selectedCategory != .installed {
                        Button {
                            viewModel.fitsMyMacOnly.toggle()
                        } label: {
                            HStack(spacing: 5) {
                                Image(systemName: viewModel.fitsMyMacOnly ? "checkmark.circle.fill" : "circle")
                                    .font(.caption2)
                                    .foregroundColor(viewModel.fitsMyMacOnly ? theme.accentColor : theme.secondaryText)
                                Text("Fits my Mac")
                                    .font(.caption)
                                    .foregroundColor(viewModel.fitsMyMacOnly ? theme.primaryText : theme.secondaryText)
                                if viewModel.fitsMyMacOnly && viewModel.hiddenByFitFilter > 0 {
                                    Text("(\(viewModel.hiddenByFitFilter) hidden)")
                                        .font(.caption2)
                                        .foregroundColor(theme.secondaryText)
                                }
                            }
                            .padding(.horizontal, 9)
                            .padding(.vertical, 5)
                            .background(
                                RoundedRectangle(cornerRadius: 6, style: .continuous)
                                    .fill(viewModel.fitsMyMacOnly ? theme.accentColor.opacity(0.12) : theme.surfaceOverlay)
                            )
                            .overlay(
                                RoundedRectangle(cornerRadius: 6, style: .continuous)
                                    .strokeBorder(viewModel.fitsMyMacOnly ? theme.accentColor.opacity(0.4) : theme.surfaceOverlayStrong, lineWidth: 0.5)
                            )
                        }
                        .buttonStyle(.plain)
                        .help("Hides models estimated to need more than this Mac's \(SystemHardwareProfiler.shared.profile.formattedEffectiveBudget) memory budget.")
                    }

                    if filterForTools {
                        Button {
                            viewModel.showToolCapableOnly.toggle()
                        } label: {
                            HStack(spacing: 5) {
                                Image(systemName: viewModel.showToolCapableOnly ? "checkmark.circle.fill" : "circle")
                                    .font(.caption2)
                                    .foregroundColor(viewModel.showToolCapableOnly ? theme.accentColor : theme.secondaryText)
                                Text("Tool-Capable Only")
                                    .font(.caption)
                                    .foregroundColor(viewModel.showToolCapableOnly ? theme.primaryText : theme.secondaryText)
                            }
                            .padding(.horizontal, 9)
                            .padding(.vertical, 5)
                            .background(
                                RoundedRectangle(cornerRadius: 6, style: .continuous)
                                    .fill(viewModel.showToolCapableOnly ? theme.accentColor.opacity(0.12) : theme.surfaceOverlay)
                            )
                            .overlay(
                                RoundedRectangle(cornerRadius: 6, style: .continuous)
                                    .strokeBorder(viewModel.showToolCapableOnly ? theme.accentColor.opacity(0.4) : theme.surfaceOverlayStrong, lineWidth: 0.5)
                            )
                        }
                        .buttonStyle(.plain)
                    }

                    Spacer()

                    // Storage summary + Check for Updates (Installed Tab)
                    if viewModel.selectedCategory == .installed, let used = viewModel.installedStorageSummary {
                        HStack(spacing: 8) {
                            HStack(spacing: 5) {
                                Image(systemName: "internaldrive")
                                    .font(.caption2)
                                Text(viewModel.isFilteringInstalled
                                     ? "\(viewModel.displayedModels.count) of \(viewModel.installedCount) · \(used) on disk"
                                     : "\(viewModel.installedCount) installed · \(used) on disk")
                                    .font(.caption)
                            }
                            .foregroundColor(theme.secondaryText)

                            Button {
                                viewModel.checkForUpdates()
                            } label: {
                                if viewModel.isCheckingForUpdates {
                                    ProgressView().controlSize(.mini)
                                } else {
                                    HStack(spacing: 4) {
                                        Image(systemName: "arrow.clockwise")
                                            .font(.caption2)
                                        Text("Check Updates")
                                            .font(.caption)
                                    }
                                    .padding(.horizontal, 8)
                                    .padding(.vertical, 4)
                                    .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(theme.surfaceOverlay))
                                    .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous).strokeBorder(theme.surfaceOverlayStrong, lineWidth: 0.5))
                                }
                            }
                            .buttonStyle(.plain)
                            .disabled(viewModel.isCheckingForUpdates)
                            .help("Compares each installed model against the version currently published on HuggingFace.")
                        }
                    }
                }
                .padding(.top, 6)
            }
            .padding(20)
            .frame(maxWidth: centeredLayout ? 1000 : .infinity)
            .frame(maxWidth: .infinity)
            .background(showSearchBar ? theme.primaryBackground : Color.clear)

            // Download failures were previously invisible in the store: the card just
            // reverted to a Download button and the reason went nowhere.
            if let downloadError = viewModel.downloadError {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundColor(.orange)
                    Text(downloadError)
                        .font(.caption)
                        .foregroundColor(theme.primaryText)
                        .textSelection(.enabled)
                    Spacer()
                    Button {
                        viewModel.dismissDownloadError()
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundColor(theme.secondaryText)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Dismiss download error")
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 10)
                .background(Color.orange.opacity(0.12))
            }

            // MARK: - Main Content Area
            ZStack {
                if viewModel.isLoading && viewModel.displayedModels.isEmpty {
                    VStack(spacing: 16) {
                        ProgressView()
                            .controlSize(.large)
                        // The key extracts, but interpolating `rawValue` left the category
                        // name in English inside an otherwise-translated sentence. Composing
                        // from the localized title keeps both halves translatable.
                        Text("Fetching \(Text(viewModel.selectedCategory.localizedTitle)) models…")
                            .foregroundColor(theme.secondaryText)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)

                } else if viewModel.displayedModels.isEmpty {
                    VStack(spacing: 12) {
                        Image(systemName: emptyStateIcon)
                            .font(.system(size: 48)) // Fixed size: intentional (icon)
                            .foregroundColor(theme.secondaryText.opacity(0.5))

                        if viewModel.selectedCategory == .installed {
                            if hasActiveFilters {
                                Text("No matching installed models")
                                    .font(.title3)
                                    .fontWeight(.medium)
                                Text("No installed models match your search or filter criteria.")
                                    .foregroundColor(theme.secondaryText)
                                Button("Reset Filters") {
                                    resetFilters()
                                }
                                .buttonStyle(.borderedProminent)
                                .tint(theme.accentColor)
                                .padding(.top, 4)
                            } else {
                                Text(filterForTools ? "No installed tool-supported models" : "No installed models")
                                    .font(.title3)
                                    .fontWeight(.medium)
                                Text(filterForTools ? "Download models from the 'Tool Use' tab." : "Download models from the 'All' or specific category tabs.")
                                    .foregroundColor(theme.secondaryText)
                            }
                        } else if let error = viewModel.loadError {
                            Text(errorTitle(for: error))
                                .font(.title3)
                                .fontWeight(.medium)
                            Text(error.errorDescription ?? "Couldn't reach HuggingFace.")
                                .foregroundColor(theme.secondaryText)
                                .multilineTextAlignment(.center)
                                .padding(.horizontal, 32)
                            // No retry button while throttled: retrying is what deepens a
                            // 429, and the old "Try Reloading" fired another 31 requests
                            // straight back into the same wall.
                            HStack(spacing: 10) {
                                // ⚠️ The 401 copy says "Add one in Settings › General" and then
                                // offered no way to get there — the one screen that knows a
                                // token is missing was the one screen that could not take it.
                                if case .unauthorized = error {
                                    Button("Add Token…") { showingTokenEntry = true }
                                        .buttonStyle(.borderedProminent)
                                }
                                // No retry button while throttled: retrying is what deepens a
                                // 429, and the old "Try Reloading" fired another 31 requests
                                // straight back into the same wall.
                                if !error.isRateLimited {
                                    Button("Try Again") { viewModel.refresh() }
                                }
                            }
                        } else if hasActiveFilters {
                            Text("No matching models")
                                .font(.title3)
                                .fontWeight(.medium)
                            Text("Try adjusting your search terms or clearing active filters.")
                                .foregroundColor(theme.secondaryText)
                            HStack(spacing: 10) {
                                Button("Reset Filters") {
                                    resetFilters()
                                }
                                .buttonStyle(.borderedProminent)
                                .tint(theme.accentColor)

                                Button("Reload Models") {
                                    viewModel.refresh()
                                }
                                .buttonStyle(.bordered)
                            }
                            .padding(.top, 4)
                        } else {
                            Text("No models found")
                                .font(.title3)
                                .fontWeight(.medium)
                            Button("Try Reloading") {
                                viewModel.refresh()
                            }
                            .buttonStyle(.borderedProminent)
                            .tint(theme.accentColor)
                            .padding(.top, 4)
                        }
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)

                } else {
                    ScrollView {
                        VStack(spacing: 0) {
                            LazyVGrid(
                                columns: [
                                    GridItem(.flexible(), spacing: 12),
                                    GridItem(.flexible(), spacing: 12)
                                ],
                                spacing: 12
                            ) {
                                ForEach(viewModel.displayedModels) { model in
                                    ModelCardView(model: model, viewModel: viewModel, profileID: profileID)
                                }
                            }

                            // PAGINATION BUTTON — full-width below the grid
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
        .sheet(isPresented: $showingTokenEntry) {
            // ⚠️ Retries on SAVE, not on a `.valid` verdict. The token is in the Keychain and in
            // use either way, and gating the retry on a network check would strand a user whose
            // check was merely inconclusive — the failure this whole flow exists to avoid.
            HuggingFaceTokenEntrySheet { viewModel.refresh() }
        }
    }
}

// Updated Model Card to support Deletion
struct ModelCardView: View {
    let model: MLXDisplayModel
    var viewModel: MLXModelStoreViewModel
    /// Which profile asked for this store, so the `DownloadRecord` records who wanted the
    /// model. MLX produced records with a nil `profileID` because the route's value was
    /// discarded at the destructure.
    var profileID: UUID?
    @State private var showingDeleteAlert = false
    @State private var showingFitAdvisory = false
    @State private var showingCancelAlert = false
    @State private var showingDetail = false
    @State private var isHovered = false
    @AppStorage(AppSettings.coreIntelligenceModelKey) private var coreIntelligenceModel: String = ""
    @Environment(\.appTheme) private var theme
    @Environment(ToastManager.self) private var toastManager
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var isInstalled: Bool {
        viewModel.isInstalled(model)
    }

    /// Starts a download and surfaces the coordinator's verdict. The outcome used to be
    /// discarded (`_ = await …`), so a refused start — MLX has a single download slot and
    /// now refuses rather than pre-empting the in-flight pull — left the button looking
    /// dead with no explanation anywhere in the UI.
    @MainActor
    private func startDownload() async {
        let outcome = await DownloadCoordinator.startMLXDownloadIfNeeded(repoId: model.id)
        switch outcome {
        case .alreadyInstalled:
            toastManager.show("\(model.displayName) is already installed", style: .success)
        case .alreadyInProgress:
            toastManager.show("Already downloading \(model.displayName)", style: .warning)
        case .resumedFromHistory:
            toastManager.show("Re-downloading \(model.displayName)…", style: .success)
        case .startedFresh:
            toastManager.show("Downloading \(model.displayName)…", style: .success)
        case .failed(let reason):
            toastManager.show(reason, style: .error)
        }
    }

    /// Re-pulls an installed model at the publisher's current revision.
    ///
    /// ⚠️ Byte-for-byte the path the "Re-download…" overflow item takes
    /// (`ModelDownloadStatusView.triggerDownload(force: true)`): delete the stale history
    /// record so the new pull gets its own row, then call the coordinator with `force` so the
    /// installed-on-disk short-circuit is skipped. WITHOUT `force` this is a guaranteed no-op —
    /// the install check reads the FILESYSTEM, and the model is by definition already there.
    ///
    /// Unlike `startDownload()` this passes `profileID`, so the record says who asked.
    @MainActor
    private func startUpdate() async {
        if let record = DownloadHistoryStore.shared.fetchMostRecent(
            backend: .mlx,
            modelIdentifier: model.id
        ) {
            _ = DownloadHistoryStore.shared.delete(id: record.id)
        }

        let outcome = await DownloadCoordinator.startMLXDownloadIfNeeded(
            repoId: model.id,
            profileID: profileID,
            force: true
        )
        switch outcome {
        case .alreadyInstalled:
            // Unreachable with `force: true`, but a silent no-op would read as a dead button.
            toastManager.show("\(model.displayName) is already up to date", style: .success)
        case .alreadyInProgress:
            toastManager.show("Already downloading \(model.displayName)", style: .warning)
        case .resumedFromHistory, .startedFresh:
            toastManager.show("Updating \(model.displayName)…", style: .success)
        case .failed(let reason):
            toastManager.show(reason, style: .error)
        }
    }

    /// Lazily computed fit assessment based on available model metadata.
    /// Isolated per card: any unparseable metadata degrades gracefully to a neutral assessment
    /// and logs raw inputs (see ModelFitAdvisor) so we can add support for new formats.
    private var fitAssessment: ModelFitAssessment {
        // `metadata: nil` made `ModelFitAdvisor.parseQuantizationBits` dead code on the
        // pre-download path, so the verdict fell back to a crude `diskBytes × 1.2` proxy even
        // though the repo id states the quantization outright. Synthesised metadata lets the
        // real formula run; it returns nil when the name yields no parameter count, in which
        // case the disk-size path answers exactly as before.
        ModelFitAdvisor.assess(
            metadata: MLXQuantization.fitMetadata(forRepoId: model.id),
            diskSizeString: model.size,
            diskSizeBytes: model.sizeBytes,
            modelName: model.id
        )
    }

    /// The active download record for this model, if one exists. When non-nil,
    /// the card switches to a simplified layout (name + circular progress) so
    /// the progress UI doesn't overlap the org label / metadata / badge row.
    private var activeDownloadRecord: DownloadRecord? {
        DownloadManager.shared.activeRecord(backend: .mlx, modelIdentifier: model.id)
    }

    /// Actions render as a floating top-right overlay so the badge row can use
    /// the full card width. We keep them visible when installed, and fade in on
    /// hover for the idle-remote case — which was the common offender for
    /// horizontal-space waste. Downloads use a dedicated layout, not the overlay.
    /// ⚠️ Always true. The actions overlay carries the store's PRIMARY action — Download —
    /// and gating it on `isHovered` with `.allowsHitTesting(false)` meant there was no
    /// pointer-free path to it at all: not by keyboard, not by VoiceOver, not by touch.
    /// Hover now only affects emphasis (see `actionsOpacity`), never reachability.
    private var showActionsOverlay: Bool { true }

    /// Hover/focus still de-emphasises the controls visually, but they stay hit-testable
    /// and in the accessibility tree at all times.
    /// Horizontal space kept clear for the actions overlay (Set as IC + delete, or the
    /// Download/Installed control). Sized to the widest of those.
    private var actionsReserve: CGFloat { 124 }

    private var actionsOpacity: Double {
        (isHovered || isInstalled) ? 1 : 0.55
    }

    @ViewBuilder
    private var actionsView: some View {
        HStack(spacing: 6) {
            // Subtle checkmark icon for installed models
            if isInstalled {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(.caption, weight: .semibold))
                    .foregroundColor(theme.successColor)
                    .help("Installed on this Mac")
                    .accessibilityLabel("Installed on this Mac")
            }

            // Intelligence Core selection is MLX-specific and only meaningful once the model
            // is on disk, so it stays here rather than moving into the shared component.
            if isInstalled, viewModel.selectedCategory == .installed {
                if coreIntelligenceModel == model.id {
                    HStack(spacing: 4) {
                        Image(systemName: "cpu.fill")
                            .font(.system(size: 10, weight: .bold))
                            .foregroundColor(theme.accentColor)
                        Text("IC")
                            .font(.system(size: 10, weight: .bold))
                            .foregroundColor(theme.primaryText.opacity(0.9))
                    }
                    .padding(.horizontal, 7)
                    .padding(.vertical, 3)
                    .background(theme.surfaceOverlay)
                    .clipShape(Capsule())
                    .help("Current Intelligence Core Model")
                } else {
                    Button {
                        coreIntelligenceModel = model.id
                    } label: {
                        HStack(spacing: 3) {
                            Image(systemName: "cpu")
                                .font(.system(size: 10, weight: .medium))
                            Text("Set as IC")
                                .font(.system(size: 10, weight: .medium))
                        }
                        .padding(.horizontal, 7)
                        .padding(.vertical, 3)
                    }
                    .buttonStyle(.plain)
                    .background(
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .fill(theme.surfaceOverlay)
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .strokeBorder(theme.surfaceOverlayStrong, lineWidth: 0.5)
                    )
                    .help("Set as Intelligence Core model")
                }
            }

            ModelDownloadStatusView(
                backend: .mlx,
                modelIdentifier: model.id,
                displayName: model.displayName,
                isInstalled: isInstalled,
                profileID: profileID,
                showInstalledLabel: false,
                onDownloadRequested: {
                    let verdict = fitAssessment.verdict
                    if verdict == .risky || verdict == .incompatible {
                        showingFitAdvisory = true
                    } else {
                        Task { @MainActor in await startDownload() }
                    }
                },
                onDeleteRequested: { showingDeleteAlert = true },
                onRevealRequested: {
                    if let item = viewModel.installedItem(for: model) {
                        MLXModelService.shared.revealInFinder(item)
                    }
                }
            )
        }
    }

    /// Standard card layout — used when no download is in progress.
    private var standardCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            // Header row: Title + Org + Spacer + Actions
            HStack(alignment: .top, spacing: 8) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(model.displayName)
                        .font(.headline)
                        .foregroundColor(theme.primaryText)
                        .lineLimit(1)
                        .truncationMode(.tail)

                    HStack(spacing: 6) {
                        if !model.organization.isEmpty {
                            Text(model.organization)
                                .font(.caption)
                                .foregroundColor(theme.secondaryText)
                                .lineLimit(1)
                        }

                        if model.downloads > 0 {
                            Text("·")
                                .font(.caption)
                                .foregroundColor(theme.secondaryText)
                            Label("\(model.downloads.formatted())", systemImage: "arrow.down.circle")
                                .font(.caption)
                                .foregroundColor(theme.secondaryText)
                        }

                        if let size = model.size {
                            Text("·")
                                .font(.caption)
                                .foregroundColor(theme.secondaryText)
                            Label(size, systemImage: "internaldrive")
                                .font(.caption)
                                .foregroundColor(theme.secondaryText)
                        }
                    }
                }

                Spacer(minLength: 8)

                actionsView
                    .opacity(actionsOpacity)
                    .animation(reduceMotion ? nil : .easeOut(duration: 0.15), value: actionsOpacity)
            }

            // Badges + Fit row
            HStack(spacing: 6) {
                ForEach(Array(model.capabilities), id: \.self) { cap in
                    CapabilityBadge(capability: cap, iconOnly: true)
                }

                if isInstalled,
                   let status = viewModel.updateStatus(for: model),
                   case .updateAvailable(let installed, let latest) = status {
                    Button {
                        Task { @MainActor in await startUpdate() }
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: "arrow.triangle.2.circlepath")
                                .font(.caption2)
                            Text("Update")
                                .font(.caption2)
                            Text(verbatim: "\(MLXModelRevision.shortForm(installed)) → \(MLXModelRevision.shortForm(latest))")
                                .font(.system(.caption2, design: .monospaced))
                                .foregroundColor(theme.accentColor.opacity(0.75))
                        }
                        .lineLimit(1)
                        .fixedSize(horizontal: true, vertical: false)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(theme.accentColor.opacity(0.15))
                        .clipShape(Capsule())
                        .foregroundColor(theme.accentColor)
                    }
                    .buttonStyle(.plain)
                    .help("Update available")
                }

                if model.isGated {
                    HStack(spacing: 4) {
                        Image(systemName: "lock.fill")
                            .font(.caption2)
                        Text("Gated")
                            .font(.caption2)
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(Color.orange.opacity(0.15))
                    .clipShape(Capsule())
                    .foregroundColor(.orange)
                    .help(HuggingFaceTokenStore.shared.hasToken
                          ? "Needs an access token and an accepted licence on HuggingFace. You have a token saved."
                          : "Needs a HuggingFace access token. Add one in Settings › General.")
                }

                if let quant = model.quantization {
                    HStack(spacing: 4) {
                        Image(systemName: "square.stack.3d.down.right")
                            .font(.caption2)
                        Text(quant.localizedTitle)
                            .font(.caption2)
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(theme.surfaceOverlay)
                    .clipShape(Capsule())
                    .foregroundColor(theme.primaryText.opacity(0.85))
                    .help(quant.guidance)
                }

                // ⚠️ Read ONCE. `fitAssessment` is a computed property with no storage, so this
                // chain used to run the full `ModelFitAdvisor.assess` three times per body — each
                // re-parsing the repo id AND emitting its own `logger.info("Assessment: …")`. Every
                // card with a badge therefore logged the same line three times and paid for it,
                // on every observer tick.
                let fit = fitAssessment
                if fit.verdict == .unknown || (model.size != nil && fit.estimatedRuntimeRAM > 0) {
                    ModelFitBadgeView(assessment: fit)
                }

                Spacer(minLength: 0)
            }
        }
    }

    /// Simplified layout shown while a download is in progress. Strips metadata
    /// and badges to keep the card calm; the circular progress indicator
    /// replaces the progress bar and doubles as the cancel control on hover.
    private func downloadingCard(record: DownloadRecord) -> some View {
        let isCleaningUp = MLXModelService.shared.isCancellingDownload(repoId: model.id)
        let snapshot = DownloadManager.shared.activeSpeeds[record.id]

        return HStack(alignment: .center, spacing: 14) {
            VStack(alignment: .leading, spacing: 4) {
                Text(model.displayName)
                    .font(.headline)
                    .foregroundColor(theme.primaryText)
                    .lineLimit(1)
                    .truncationMode(.middle)

                Text(isCleaningUp ? "Cleaning up…" : DownloadSpeedFormatter.compactLine(snapshot: snapshot))
                    .font(.caption2)
                    .foregroundColor(theme.tertiaryText)
                    .lineLimit(1)
            }

            Spacer(minLength: 0)

            if isCleaningUp {
                ProgressView()
                    .controlSize(.small)
                    .frame(width: 44, height: 44)
            } else {
                MLXDownloadProgressCircle(
                    progress: record.progress,
                    onCancelRequested: { showingCancelAlert = true }
                )
            }
        }
    }

    var body: some View {
        Group {
            if let record = activeDownloadRecord {
                downloadingCard(record: record)
            } else {
                standardCard
            }
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(
                    isInstalled
                        ? theme.successColor.opacity(isHovered ? 0.08 : 0.04)
                        : (isHovered ? theme.controlBackground : theme.secondaryBackground)
                )
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(
                    isInstalled
                        ? theme.successColor.opacity(isHovered ? 0.50 : 0.25)
                        : (isHovered ? theme.accentColor.opacity(0.4) : theme.surfaceOverlayStrong),
                    lineWidth: 1
                )
        )
        .shadow(
            color: isInstalled
                ? theme.successColor.opacity(isHovered ? 0.08 : 0.03)
                : theme.primaryText.opacity(isHovered ? 0.05 : 0.03),
            radius: isHovered ? 10 : 5,
            y: isHovered ? 4 : 2
        )
        .onHover { hovering in
            withAnimation(reduceMotion ? nil : .easeOut(duration: 0.2)) {
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
                    Task { @MainActor in await startDownload() }
                },
                onDismiss: {
                    showingFitAdvisory = false
                }
            )
        }
        // The card had no tap target at all — name, org, downloads, size and heuristic badges
        // were everything the user got before committing to a multi-gigabyte download.
        // `.onTapGesture` rather than wrapping in a Button so the card's own controls
        // (Download, Set as IC, the overflow menu) keep their own hit areas.
        .contentShape(Rectangle())
        .onTapGesture { showingDetail = true }
        .accessibilityAddTraits(.isButton)
        .accessibilityHint("Show details for \(model.displayName)")
        .sheet(isPresented: $showingDetail) {
            MLXModelDetailSheet(
                model: model,
                fitAssessment: fitAssessment,
                onDownload: {
                    // Same routing as the card's own button: the fit advisory still gates,
                    // and the coordinator still pre-seeds the size.
                    let verdict = fitAssessment.verdict
                    if verdict == .risky || verdict == .incompatible {
                        showingFitAdvisory = true
                    } else {
                        Task { @MainActor in await startDownload() }
                    }
                }
            )
        }
        .alert("Delete Model?", isPresented: $showingDeleteAlert) {
            Button("Delete", role: .destructive) {
                viewModel.deleteModel(model)
            }
            Button("Cancel", role: .cancel) { }
        } message: {
            // Name the bytes reclaimed: the whole reason a user deletes a model is to
            // recover space, and the alert used to promise removal without saying how much.
            Text(viewModel.installedSize(of: model).map {
                "Are you sure you want to delete '\(model.displayName)'? This permanently removes \($0) from your disk."
            } ?? "Are you sure you want to delete '\(model.displayName)'? This will permanently remove the files from your disk.")
        }
        .alert("Cancel Download?", isPresented: $showingCancelAlert) {
            Button("Cancel Download", role: .destructive) {
                if let record = activeDownloadRecord {
                    DownloadManager.shared.cancelDownload(record)
                }
            }
            Button("Keep Downloading", role: .cancel) { }
        } message: {
            Text("The in-progress download of '\(model.displayName)' will be stopped and any partial files removed from disk.")
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
                Text(category.localizedTitle)
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
