// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2026 Raj Singh
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
    /// Threaded down to the download records. See `ModelCardView.profileID`.
    var profileID: UUID?
    /// When false, the search bar is hidden (it's in the DynamicIslandBar instead).
    var showSearchBar: Bool = true
    /// When true, content is centered with maxWidth: 1000 to match DynamicIslandBar width.
    var centeredLayout: Bool = false
    @Environment(\.appTheme) private var theme

    private var emptyStateIcon: String {
        if viewModel.loadError != nil { return "exclamationmark.icloud" }
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

                // Storage accounting: the app held 76 GB of models on the dev machine and
                // could not tell the user that, or which model was the large one.
                if viewModel.selectedCategory == .installed, let used = viewModel.installedStorageSummary {
                    // ⚠️ ONE row. This was a storage HStack, then a bare `Spacer()`, then the
                    // button — and that Spacer was a child of the enclosing VStack, not of the
                    // HStack, so it expanded VERTICALLY and pushed "Check for Updates", the
                    // quantization picker and the whole grid ~400pt down the Installed tab,
                    // leaving a void under the summary. Found by running the app; no test
                    // asserts layout.
                    HStack(spacing: 6) {
                        HStack(spacing: 6) {
                            Image(systemName: "internaldrive")
                                .font(.caption)
                            // Both halves must describe the SAME set. Using the filtered count
                            // beside the whole-library size read as "1 installed model totalling
                            // 81.52 GB". The row is storage accounting for the library, so the
                            // library totals lead; the filter is reported separately.
                            Text(viewModel.isFilteringInstalled
                                 ? "\(viewModel.displayedModels.count) of \(viewModel.installedCount) shown · \(used) on disk"
                                 : "\(viewModel.installedCount) installed · \(used) on disk")
                                .font(.caption)
                        }
                        .foregroundColor(theme.secondaryText)
                        // ⚠️ `.combine` only over the label pair — applied to the whole row it
                        // would swallow the button below into one unactionable element.
                        .accessibilityElement(children: .combine)

                        Spacer()

                        // ⚠️ Explicit rather than automatic: one request per installed model on
                        // every store open is exactly the unbounded fan-out A9 removed.
                        Button {
                            viewModel.checkForUpdates()
                        } label: {
                            if viewModel.isCheckingForUpdates {
                                ProgressView().controlSize(.small)
                            } else {
                                Text("Check for Updates").font(.caption)
                            }
                        }
                        .buttonStyle(.link)
                        .disabled(viewModel.isCheckingForUpdates)
                        .help("Compares each installed model against the version currently published on HuggingFace.")
                    }
                }

                // Quantization picker. Only shown when the current results actually contain
                // more than one — a single-option filter is just clutter.
                // ⚠️ …but ALWAYS shown while a filter is active, whatever the count. The
                // control that clears a filter must never be hidden by the filter's own
                // effect; that combination is how the grid could go empty with no way back.
                if viewModel.availableQuantizations.count > 1 || viewModel.quantizationFilter != nil {
                    HStack(spacing: 8) {
                        Text("Quantization")
                            .font(.caption)
                            .foregroundColor(theme.secondaryText)
                        Picker("Quantization", selection: $viewModel.quantizationFilter) {
                            Text("Any").tag(MLXQuantization?.none)
                            ForEach(viewModel.availableQuantizations, id: \.self) { quant in
                                Text(quant.localizedTitle).tag(MLXQuantization?.some(quant))
                            }
                        }
                        .labelsHidden()
                        .pickerStyle(.menu)
                        .frame(maxWidth: 130)
                        .help("Lower bit counts are smaller and faster; higher ones keep more of the original quality.")
                        Spacer()
                    }
                }

                // The tool-capability filter is the user's to control. It used to be an
                // unconditional filter with no override, so a heuristic false negative made
                // a model unreachable in Agent profiles entirely.
                if filterForTools {
                    HStack {
                        Toggle("Show tool-capable models only", isOn: $viewModel.showToolCapableOnly)
                            .toggleStyle(.checkbox)
                            .font(.caption)
                            .foregroundColor(theme.secondaryText)
                            .help("Tool support is detected from the model name and is often wrong for new or re-quantized models. Turn this off to see everything.")
                        Spacer()
                    }
                }
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
                            Text(filterForTools ? "No installed tool-supported models" : "No installed models")
                                .font(.title3)
                                .fontWeight(.medium)
                            Text(filterForTools ? "Download models from the 'Tool Use' tab." : "Download models from the 'All' or specific category tabs.")
                                .foregroundColor(theme.secondaryText)
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
                            if !error.isRateLimited {
                                Button("Try Again") { viewModel.refresh() }
                            }
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
        VStack(alignment: .trailing, spacing: 8) {
            // Intelligence Core selection is MLX-specific and only meaningful once the model
            // is on disk, so it stays here rather than moving into the shared component.
            if isInstalled, viewModel.selectedCategory == .installed {
                if coreIntelligenceModel == model.id {
                    HStack(spacing: 5) {
                        Image(systemName: "cpu.fill")
                            .font(.system(.caption2, weight: .semibold))
                            .foregroundColor(.purple)
                        Text("Intelligence Core")
                            .font(.caption2)
                            .foregroundColor(theme.primaryText.opacity(0.85))
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(theme.surfaceOverlay)
                    .clipShape(Capsule())
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
            }

            // ⚠️ Driven by the REAL `isInstalled`. This used to be hard-coded `false` and
            // rendered only inside an `else if isInstalled`, so the shared component's
            // Installed state — the capsule plus the overflow menu carrying "Re-download…"
            // and "Delete" — was unreachable for MLX. That made MLX the only backend with no
            // re-download path: to re-pull a model the user had to delete it and find it
            // again. The card's own bespoke Installed capsule and standalone trash button are
            // gone; all three backends now present an installed model identically.
            ModelDownloadStatusView(
                backend: .mlx,
                modelIdentifier: model.id,
                displayName: model.displayName,
                isInstalled: isInstalled,
                profileID: profileID,
                onDownloadRequested: {
                    let verdict = fitAssessment.verdict
                    // `.unknown` deliberately does NOT raise the advisory sheet. We don't
                    // know the model is risky, and during a rate-limit every card is
                    // unknown — interrupting each download with a sheet that can only say
                    // "we couldn't check" is noise. The card's badge carries that state
                    // instead: describe, don't gate.
                    if verdict == .risky || verdict == .incompatible {
                        showingFitAdvisory = true
                    } else {
                        // Must route through DownloadCoordinator (not
                        // `viewModel.downloadModel` directly) so the pre-seed HF size fetch
                        // fires — without it the bridge has no total bytes, the speed
                        // sampler can't compute a rate, and the UI is stuck on "calculating…".
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

    /// Shared icon (44×44 rounded rectangle with the accent "cube" glyph).
    /// Used by both the standard and downloading layouts.
    private var cardIcon: some View {
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
    }

    /// Standard card layout — used when no download is in progress.
    private var standardCard: some View {
        HStack(alignment: .top, spacing: 14) {
            cardIcon

            VStack(alignment: .leading, spacing: 6) {
                // Name + Organization
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(model.displayName)
                        .font(.headline)
                        .foregroundColor(theme.primaryText)
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .layoutPriority(1)

                    if !model.organization.isEmpty {
                        Text(model.organization)
                            .font(.caption)
                            .foregroundColor(theme.secondaryText)
                            .lineLimit(1)
                            .truncationMode(.tail)
                    }
                    Spacer(minLength: 0)
                }
                // Reserve room for the `.topTrailing` actions overlay. Without this a long
                // name plus an org label runs underneath "Set as IC" and the delete button —
                // which became common once every model carried an org (previously only
                // `mlx-community` models did, so most titles were short and unqualified).
                .padding(.trailing, actionsReserve)

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

                // Badges + Fit — full card width now that actions overlay
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        ForEach(Array(model.capabilities), id: \.self) { cap in
                            CapabilityBadge(capability: cap)
                        }

                        // "Update available" — the publisher pushed a newer commit than the
                        // one this copy was downloaded at. `.unknown` deliberately shows
                        // nothing rather than implying up-to-date.
                        if viewModel.updateStatus(for: model)?.needsUpdate == true {
                            HStack(spacing: 4) {
                                Image(systemName: "arrow.triangle.2.circlepath")
                                    .font(.caption2)
                                Text("Update available")
                                    .font(.caption2)
                            }
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .background(theme.accentColor.opacity(0.15))
                            .clipShape(Capsule())
                            .foregroundColor(theme.accentColor)
                            .help("The publisher has pushed a newer version. Use Re-download to update — HubApi verifies each file and fetches only what changed.")
                        }

                        // Gated repos rendered as ordinary cards, so the only way to learn a
                        // download could never succeed was to start it and read the failure.
                        // ⚠️ A label, never a disabled button: the user may well have a token
                        // configured, and gating on a listing flag would block a download that
                        // works perfectly.
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
                                  : "Needs a HuggingFace access token. Add one in Settings › Account.")
                            .accessibilityElement(children: .ignore)
                            .accessibilityLabel("Gated model — requires a HuggingFace access token")
                        }

                        // Quantization was invisible: the live top-30 lists four gemma-4
                        // variants distinguished only by a suffix buried in the title.
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
                            .accessibilityElement(children: .ignore)
                            // `localizedTitle`, matching the visible badge. `shortLabel` is the
                            // same text but as a plain `String`, so VoiceOver was reading an
                            // untranslated form of a label that renders translated.
                            .accessibilityLabel(Text("Quantization: \(Text(quant.localizedTitle))"))
                            .accessibilityHint(quant.guidance)
                        }

                        // `.unknown` must render too. The old gate required a non-nil size
                        // AND a positive RAM estimate, so a failed size fetch hid the badge
                        // entirely — the user got no signal that the fit was unchecked
                        // rather than fine.
                        if fitAssessment.verdict == .unknown
                            || (model.size != nil && fitAssessment.estimatedRuntimeRAM > 0) {
                            ModelFitBadgeView(assessment: fitAssessment)
                        }
                    }
                }
            }

            Spacer(minLength: 0)
        }
        .overlay(alignment: .topTrailing) {
            actionsView
                .opacity(actionsOpacity)
                .animation(reduceMotion ? nil : .easeOut(duration: 0.15), value: actionsOpacity)
        }
    }

    /// Simplified layout shown while a download is in progress. Strips metadata
    /// and badges to keep the card calm; the circular progress indicator
    /// replaces the progress bar and doubles as the cancel control on hover.
    private func downloadingCard(record: DownloadRecord) -> some View {
        let isCleaningUp = MLXModelService.shared.isCancellingDownload(repoId: model.id)
        let snapshot = DownloadManager.shared.activeSpeeds[record.id]

        return HStack(alignment: .center, spacing: 14) {
            cardIcon

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
        .background(isHovered ? theme.controlBackground : theme.secondaryBackground)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(isHovered ? theme.accentColor.opacity(0.4) : theme.surfaceOverlayStrong, lineWidth: 1)
        )
        .shadow(color: theme.primaryText.opacity(isHovered ? 0.05 : 0.03), radius: isHovered ? 12 : 6, y: isHovered ? 6 : 3)
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
