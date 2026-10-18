// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
//
//  OnboardingModelDownloadView.swift
//  Devgentic
//
//  Created by Raj Singh.
//

import SwiftUI

/// Lets the user pick one of five starter models and download it; Continue stays disabled until the model is on disk.
/// On failure two retries are offered, then only "Skip for now" (see `OnboardingViewModel.downloadRecovery`).
struct OnboardingModelDownloadView: View {
    @Bindable var viewModel: OnboardingViewModel
    @Environment(\.appTheme) private var theme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @State private var shimmerPhase: CGFloat = -1.0

    var body: some View {
        VStack(spacing: 0) {
            ScrollView(.vertical, showsIndicators: false) {
                VStack(spacing: 18) {
                    header

                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Text(viewModel.selectedBackend == .mlx ? String(localized: "MLX Models") : String(localized: "Ollama Models"))
                                .font(.system(size: 13, weight: .semibold))
                                .foregroundColor(theme.primaryText)
                            Spacer()
                            Text(macSummary)
                                .font(.system(size: 11, weight: .medium))
                                .foregroundColor(theme.secondaryText)
                        }

                        VStack(spacing: 8) {
                            ForEach(viewModel.availableModels) { model in
                                modelRow(model)
                            }
                        }
                    }

                    if viewModel.selectedBackend == .ollama && viewModel.isOllamaReachable == false {
                        ollamaMissingBanner
                    }

                    downloadPanel
                }
                .frame(maxWidth: 620)
                .padding(.horizontal, 32)
                .padding(.bottom, 16)
            }

            // Pinned Bottom Navigation Action
            HStack {
                OnboardingSecondaryButton("Back", icon: "chevron.left") {
                    viewModel.goToStep(.profileSetup)
                }
                .disabled(viewModel.isDownloading)
                .opacity(viewModel.isDownloading ? 0.5 : 1)
                .help(viewModel.isDownloading ? String(localized: "Cancel the download to go back.") : "")

                Spacer()

                OnboardingPrimaryButton(
                    viewModel.didSkipDownload ? "Continue Without Model" : "Continue",
                    isEnabled: viewModel.canContinueFromModelStep
                ) {
                    viewModel.goToStep(.behavior)
                }
            }
            .frame(maxWidth: 620)
            .padding(.horizontal, 32)
            .padding(.top, 10)
            .padding(.bottom, 22)
        }
        .onAppear {
            startShimmer()
        }
    }

    // MARK: - Header
    private var header: some View {
        VStack(spacing: 8) {
            Text(OnboardingViewModel.Step.modelDownload.progressLabel ?? "")
                .font(.system(size: 11, weight: .bold, design: .rounded))
                .foregroundStyle(Color.accentColor)
                .tracking(1.0)
                .padding(.horizontal, 10)
                .padding(.vertical, 4)
                .background(Color.accentColor.opacity(0.12))
                .clipShape(Capsule())

            Text("Choose Your Model")
                .font(.system(size: 26, weight: .bold))
                .foregroundColor(theme.primaryText)

            Text("All five can call tools. Bigger models are smarter but slower and need more memory. You can add more models later.")
                .font(theme.fontBody)
                .foregroundColor(theme.secondaryText)
                .multilineTextAlignment(.center)
        }
        .padding(.top, 12)
    }

    // MARK: - Model Row
    @ViewBuilder
    private func modelRow(_ model: OnboardingStarterModel) -> some View {
        let isSelected = viewModel.selectedModelID == model.id
        let isRecommended = viewModel.recommendedModel?.id == model.id
        let exceedsMemory = model.recommendedMinimumRAMGB > viewModel.physicalMemoryGB
        // An already-downloaded selection needs no space.
        let lacksSpace = !viewModel.fitsOnDisk(model) && !(isSelected && viewModel.isModelInstalled)

        Button(action: { viewModel.selectModel(model.id) }) {
            HStack(spacing: 12) {
                Image(systemName: isSelected ? "largecircle.fill.circle" : "circle")
                    .font(.system(size: 15))
                    .foregroundColor(isSelected ? Color.accentColor : theme.secondaryText.opacity(0.7))

                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        Text(model.displayName)
                            .font(.system(size: 13, weight: .bold))
                            .foregroundColor(theme.primaryText)

                        tag(model.sizeClass, color: theme.secondaryText)

                        if isRecommended {
                            tag(String(localized: "Recommended"), color: Color.accentColor)
                        }
                    }

                    Text(exceedsMemory
                         ? String(localized: "Needs \(model.recommendedMinimumRAMGB) GB+ memory to run smoothly. \(model.summary)")
                         : model.summary)
                        .font(.system(size: 11))
                        .foregroundColor(exceedsMemory ? .orange : theme.secondaryText)
                        .fixedSize(horizontal: false, vertical: true)

                    if lacksSpace {
                        Label(String(localized: "Not enough disk space — needs \(Self.bytes(OnboardingViewModel.requiredDiskBytes(for: model))) free."),
                              systemImage: "externaldrive.badge.exclamationmark")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundColor(.red)
                    }
                }

                Spacer()

                Text(model.formattedSize)
                    .font(.system(size: 12, weight: .semibold, design: .monospaced))
                    .foregroundColor(lacksSpace ? .red : theme.secondaryText)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 9)
            .background(isSelected ? Color.accentColor.opacity(0.08) : theme.secondaryBackground.opacity(0.6))
            .clipShape(RoundedRectangle(cornerRadius: 11))
            .overlay(
                RoundedRectangle(cornerRadius: 11)
                    .stroke(isSelected ? Color.accentColor : theme.dividerColor, lineWidth: isSelected ? 1.5 : 1)
            )
            .contentShape(RoundedRectangle(cornerRadius: 11))
        }
        .buttonStyle(.plain)
        .pointingHandCursor(enabled: !viewModel.isDownloading)
        .disabled(viewModel.isDownloading)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .accessibilityHint(isRecommended ? String(localized: "Recommended for this Mac") : "")
    }

    private func tag(_ text: String, color: Color) -> some View {
        Text(text)
            .font(.system(size: 10, weight: .medium))
            .padding(.horizontal, 7)
            .padding(.vertical, 2)
            .background(color.opacity(0.14))
            .foregroundColor(color)
            .clipShape(Capsule())
    }

    // MARK: - Ollama Missing
    private var ollamaMissingBanner: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "server.rack")
                .font(.system(size: 16))
                .foregroundColor(.orange)
            VStack(alignment: .leading, spacing: 4) {
                Text("Ollama isn't running on this Mac")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(theme.primaryText)
                Text("Install Ollama, or open it if it's already installed, then press Download. Or go back and choose MLX, which needs nothing else installed.")
                    .font(.system(size: 11))
                    .foregroundColor(theme.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            Link(destination: OnboardingViewModel.ollamaDownloadURL) {
                Label("Get Ollama", systemImage: "arrow.up.right.square")
                    .font(.system(size: 12, weight: .semibold))
            }
            .pointingHandCursor()
        }
        .padding(12)
        .background(Color.orange.opacity(0.1))
        .clipShape(RoundedRectangle(cornerRadius: 11))
    }

    // MARK: - Download Panel
    private var downloadPanel: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 12) {
                Image(systemName: statusIcon)
                    .font(.system(size: 22))
                    .foregroundColor(statusColor)
                    .frame(width: 28)

                VStack(alignment: .leading, spacing: 3) {
                    Text(viewModel.selectedModelIdentifier)
                        .font(.system(size: 12, weight: .bold, design: .monospaced))
                        .foregroundColor(theme.primaryText)
                        .lineLimit(1)
                        .truncationMode(.middle)

                    Text(statusText)
                        .font(.system(size: 12))
                        .foregroundColor(statusColor)
                }

                Spacer()

                if viewModel.isDownloading {
                    VStack(alignment: .trailing, spacing: 2) {
                        Text("\(Int(viewModel.downloadProgress * 100))%")
                            .font(.system(size: 18, weight: .bold, design: .monospaced))
                            .foregroundColor(theme.primaryText)
                        if !viewModel.downloadEtaText.isEmpty {
                            Text(viewModel.downloadEtaText)
                                .font(.system(size: 11))
                                .foregroundColor(theme.secondaryText)
                        }
                    }
                } else if viewModel.isCheckingModelStatus {
                    ProgressView().controlSize(.small)
                }
            }

            if viewModel.isDownloading {
                shimmeringProgressBar
                    .accessibilityElement()
                    .accessibilityLabel("Download progress")
                    .accessibilityValue("\(Int(viewModel.downloadProgress * 100)) percent")

                HStack {
                    if !viewModel.downloadBytesText.isEmpty {
                        Label(viewModel.downloadBytesText, systemImage: "internaldrive")
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundColor(theme.secondaryText)
                    }
                    Spacer()
                    if !viewModel.downloadSpeedText.isEmpty {
                        Label(viewModel.downloadSpeedText, systemImage: "bolt.fill")
                            .font(.system(size: 11, weight: .semibold, design: .monospaced))
                            .foregroundColor(.green)
                    }
                }
            }

            if let error = viewModel.downloadErrorMessage {
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundColor(.red)
                    Text(error)
                        .font(.system(size: 12))
                        .foregroundColor(.red)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 0)
                }
                .padding(10)
                .background(Color.red.opacity(0.1))
                .clipShape(RoundedRectangle(cornerRadius: 9))
            }

            actionRow
        }
        .padding(18)
        .background(theme.secondaryBackground.opacity(0.6))
        .clipShape(RoundedRectangle(cornerRadius: 16))
        .overlay(
            RoundedRectangle(cornerRadius: 16)
                .stroke(theme.dividerColor, lineWidth: 1)
        )
    }

    @ViewBuilder
    private var actionRow: some View {
        if viewModel.isDownloading {
            HStack {
                Spacer()
                OnboardingSecondaryButton("Cancel Download", icon: "xmark") {
                    viewModel.cancelDownload()
                }
            }
        } else if viewModel.isModelInstalled || viewModel.didSkipDownload || viewModel.isCheckingModelStatus {
            EmptyView()
        } else if !viewModel.selectedModelFitsOnDisk, viewModel.downloadRecovery != .skipOnly {
            diskSpaceBanner
        } else {
            switch viewModel.downloadRecovery {
            case .none:
                HStack {
                    Spacer()
                    TactileButton(title: "Download \(viewModel.selectedModel?.formattedSize ?? "")",
                                  icon: "arrow.down.circle", variant: .primary, size: .compact) {
                        viewModel.startModelDownload()
                    }
                }
            case .retry(let remaining):
                HStack {
                    Text(remaining == 1 ? String(localized: "1 retry left.") : String(localized: "\(remaining) retries left."))
                        .font(.system(size: 11))
                        .foregroundColor(theme.secondaryText)
                    Spacer()
                    TactileButton(title: "Retry", icon: "arrow.clockwise", variant: .primary, size: .compact) {
                        viewModel.startModelDownload()
                    }
                }
            case .skipOnly:
                HStack(alignment: .center) {
                    Text("The download failed \(viewModel.failedDownloadAttempts) times. You can skip for now and download it later from the Model Store. Until then, the profile can't run.")
                        .font(.system(size: 11))
                        .foregroundColor(theme.secondaryText)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 12)
                    OnboardingSecondaryButton("Skip for Now", icon: "forward") {
                        viewModel.skipModelDownload()
                    }
                }
            }
        }
    }

    // MARK: - Disk Space

    private var macSummary: String {
        if let free = viewModel.availableDiskBytes {
            return String(localized: "This Mac: \(viewModel.physicalMemoryGB) GB memory · \(Self.bytes(free)) free")
        }
        return String(localized: "This Mac: \(viewModel.physicalMemoryGB) GB memory")
    }

    private var diskSpaceBanner: some View {
        let needed = viewModel.selectedModel.map(OnboardingViewModel.requiredDiskBytes(for:)) ?? 0
        let free = viewModel.availableDiskBytes ?? 0
        return VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: "externaldrive.badge.exclamationmark")
                    .foregroundColor(.red)
                Text(viewModel.noModelFitsOnDisk
                     ? String(localized: "Not enough disk space for any starter model. This one needs \(Self.bytes(needed)) free and only \(Self.bytes(free)) is available. Free up space and check again, or skip for now and download a model later from the Model Store.")
                     : String(localized: "Not enough disk space. This model needs \(Self.bytes(needed)) free and only \(Self.bytes(free)) is available. Free up space, or choose a smaller model."))
                    .font(.system(size: 12))
                    .foregroundColor(theme.primaryText)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                Spacer()
                if viewModel.canSkipDownload {
                    OnboardingSecondaryButton("Skip for Now", icon: "forward") {
                        viewModel.skipModelDownload()
                    }
                }
                TactileButton(title: "Check Again", icon: "arrow.clockwise", variant: .primary, size: .compact) {
                    viewModel.refreshDiskSpace()
                }
            }
        }
        .padding(10)
        .background(Color.red.opacity(0.08))
        .clipShape(RoundedRectangle(cornerRadius: 9))
    }

    private static func bytes(_ count: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: count, countStyle: .file)
    }

    private var statusIcon: String {
        if viewModel.isModelInstalled { return "checkmark.circle.fill" }
        if viewModel.didSkipDownload { return "forward.circle.fill" }
        if viewModel.downloadErrorMessage != nil { return "exclamationmark.circle.fill" }
        return "arrow.down.circle.fill"
    }

    private var statusColor: Color {
        if viewModel.isModelInstalled { return .green }
        if viewModel.didSkipDownload { return .orange }
        if viewModel.downloadErrorMessage != nil { return .red }
        return Color.accentColor
    }

    private var statusText: String {
        if viewModel.isCheckingModelStatus && !viewModel.isDownloading { return String(localized: "Checking whether it's already downloaded...") }
        if viewModel.isModelInstalled { return String(localized: "Downloaded and ready.") }
        if viewModel.didSkipDownload { return String(localized: "Skipped. Not downloaded yet.") }
        if !viewModel.downloadStageText.isEmpty { return viewModel.downloadStageText }
        return String(localized: "Not downloaded yet. Download it to continue.")
    }

    // MARK: - Shimmering Progress Bar Component
    private var shimmeringProgressBar: some View {
        GeometryReader { proxy in
            let totalWidth = proxy.size.width
            let filledWidth = max(0, min(totalWidth, totalWidth * viewModel.downloadProgress))

            ZStack(alignment: .leading) {
                // Background Track
                RoundedRectangle(cornerRadius: 7)
                    .fill(theme.primaryBackground.opacity(0.85))
                    .frame(height: 10)

                // Filled Bar
                RoundedRectangle(cornerRadius: 7)
                    .fill(
                        LinearGradient(
                            colors: [Color.indigo, Color.cyan],
                            startPoint: .leading,
                            endPoint: .trailing
                        )
                    )
                    .frame(width: filledWidth, height: 10)
                    .overlay(
                        // Shimmer wave moving across the filled portion
                        GeometryReader { fillProxy in
                            if viewModel.isDownloading && viewModel.downloadProgress < 1.0 && !reduceMotion {
                                LinearGradient(
                                    stops: [
                                        .init(color: .clear, location: 0),
                                        .init(color: .white.opacity(0.55), location: 0.5),
                                        .init(color: .clear, location: 1.0)
                                    ],
                                    startPoint: .leading,
                                    endPoint: .trailing
                                )
                                .frame(width: 90)
                                .offset(x: shimmerPhase * (fillProxy.size.width + 180) - 90)
                            }
                        }
                        .clipShape(RoundedRectangle(cornerRadius: 7))
                    )
            }
        }
        .frame(height: 10)
    }

    private func startShimmer() {
        guard !reduceMotion else { return }
        withAnimation(.linear(duration: 1.8).repeatForever(autoreverses: false)) {
            shimmerPhase = 1.0
        }
    }
}
