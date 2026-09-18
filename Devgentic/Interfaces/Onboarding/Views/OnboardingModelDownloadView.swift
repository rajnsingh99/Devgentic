// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
//
//  OnboardingModelDownloadView.swift
//  Devgentic
//
//  Created by Raj Singh on 17/09/26.
//

import SwiftUI

struct OnboardingModelDownloadView: View {
    @Bindable var viewModel: OnboardingViewModel
    @Environment(\.appTheme) private var theme

    @State private var shimmerPhase: CGFloat = -1.0

    var body: some View {
        VStack(spacing: 0) {
            // Header
            VStack(spacing: 8) {
                HStack(spacing: 6) {
                    Text("STEP 2 OF 3")
                        .font(.system(size: 11, weight: .bold, design: .rounded))
                        .foregroundStyle(Color.accentColor)
                        .tracking(1.0)
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 4)
                .background(Color.accentColor.opacity(0.12))
                .clipShape(Capsule())

                Text(viewModel.downloadProgress >= 1.0 ? "Model Ready!" : "Downloading Model Weights")
                    .font(.system(size: 26, weight: .bold))
                    .foregroundColor(theme.primaryText)

                Text("Preparing your starter weights. All files are stored directly in your local cache.")
                    .font(theme.fontBody)
                    .foregroundColor(theme.secondaryText)
            }
            .padding(.top, 12)
            .padding(.bottom, 22)

            // Download Status Card
            VStack(spacing: 20) {
                // Target Model Info
                HStack(spacing: 16) {
                    ZStack {
                        RoundedRectangle(cornerRadius: 14)
                            .fill(LinearGradient(colors: [Color.indigo.opacity(0.2), Color.cyan.opacity(0.2)], startPoint: .topLeading, endPoint: .bottomTrailing))
                            .frame(width: 54, height: 54)

                        Image(systemName: viewModel.downloadProgress >= 1.0 ? "checkmark.circle.fill" : "arrow.down.circle.fill")
                            .font(.system(size: 26))
                            .foregroundColor(viewModel.downloadProgress >= 1.0 ? .green : .cyan)
                    }

                    VStack(alignment: .leading, spacing: 5) {
                        Text(viewModel.selectedModelIdentifier)
                            .font(.system(size: 14, weight: .bold, design: .monospaced))
                            .foregroundColor(theme.primaryText)

                        Text(viewModel.downloadStageText)
                            .font(.system(size: 12))
                            .foregroundColor(viewModel.downloadProgress >= 1.0 ? .green : Color.accentColor)
                    }

                    Spacer()

                    VStack(alignment: .trailing, spacing: 3) {
                        Text("\(Int(viewModel.downloadProgress * 100))%")
                            .font(.system(size: 22, weight: .bold, design: .monospaced))
                            .foregroundColor(theme.primaryText)

                        if !viewModel.downloadEtaText.isEmpty {
                            Text(viewModel.downloadEtaText)
                                .font(.system(size: 12))
                                .foregroundColor(theme.secondaryText)
                        }
                    }
                }

                // Shimmering Progress Bar
                shimmeringProgressBar

                // Speed and Size Readout
                HStack {
                    if !viewModel.downloadBytesText.isEmpty {
                        HStack(spacing: 5) {
                            Image(systemName: "internaldrive")
                                .font(.system(size: 11))
                            Text(viewModel.downloadBytesText)
                                .font(.system(size: 12, design: .monospaced))
                        }
                        .foregroundColor(theme.secondaryText)
                    }

                    Spacer()

                    if !viewModel.downloadSpeedText.isEmpty {
                        HStack(spacing: 5) {
                            Image(systemName: "bolt.fill")
                                .font(.system(size: 11))
                                .foregroundColor(.green)
                            Text(viewModel.downloadSpeedText)
                                .font(.system(size: 12, weight: .semibold, design: .monospaced))
                                .foregroundColor(.green)
                        }
                    }
                }

                // Error Banner if failed
                if let error = viewModel.downloadErrorMessage {
                    HStack(spacing: 8) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundColor(.red)
                        Text(error)
                            .font(.system(size: 12))
                            .foregroundColor(.red)
                        Spacer()
                        Button("Retry") {
                            viewModel.startModelDownload()
                        }
                        .font(.system(size: 11, weight: .semibold))
                        .buttonStyle(.borderedProminent)
                    }
                    .padding(12)
                    .background(Color.red.opacity(0.1))
                    .clipShape(RoundedRectangle(cornerRadius: 10))
                }

                // Quick Fast-Forward simulator button (helpful for testing & preview)
                if viewModel.downloadProgress < 1.0 {
                    HStack(spacing: 12) {
                        // Fast-Forward button with hover state
                        FastForwardButton {
                            withAnimation(.spring()) {
                                viewModel.downloadProgress = 1.0
                                viewModel.isDownloading = false
                                viewModel.isModelInstalled = true
                                viewModel.downloadStageText = "Model verified and ready!"
                                viewModel.downloadEtaText = "Completed"
                            }
                        }

                        Spacer()

                        OnboardingSecondaryButton("Cancel", icon: "xmark") {
                            viewModel.cancelDownload()
                        }
                    }
                    .padding(.top, 4)
                }
            }
            .padding(24)
            .background(theme.secondaryBackground.opacity(0.6))
            .clipShape(RoundedRectangle(cornerRadius: 18))
            .overlay(
                RoundedRectangle(cornerRadius: 18)
                    .stroke(theme.dividerColor, lineWidth: 1)
            )
            .frame(maxWidth: 620)

            Spacer(minLength: 16)

            // Pinned Bottom Navigation Action
            HStack {
                OnboardingSecondaryButton("Back", icon: "chevron.left") {
                    viewModel.goToStep(.profileSetup)
                }

                Spacer()

                OnboardingPrimaryButton(
                    "Continue to Customization",
                    isEnabled: viewModel.downloadProgress >= 1.0
                ) {
                    viewModel.goToStep(.themeCustomization)
                }
            }
            .frame(maxWidth: 620)
            .padding(.horizontal, 32)
            .padding(.bottom, 22)
        }
        .onAppear {
            startShimmer()
        }
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
                    .frame(height: 12)

                // Filled Bar
                RoundedRectangle(cornerRadius: 7)
                    .fill(
                        LinearGradient(
                            colors: [Color.indigo, Color.cyan],
                            startPoint: .leading,
                            endPoint: .trailing
                        )
                    )
                    .frame(width: filledWidth, height: 12)
                    .overlay(
                        // Shimmer wave moving across the filled portion
                        GeometryReader { fillProxy in
                            if viewModel.isDownloading && viewModel.downloadProgress < 1.0 {
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
        .frame(height: 12)
    }

    private func startShimmer() {
        withAnimation(.linear(duration: 1.8).repeatForever(autoreverses: false)) {
            shimmerPhase = 1.0
        }
    }
}

// MARK: - Fast Forward Simulator Button with Hover
private struct FastForwardButton: View {
    let action: () -> Void
    @Environment(\.appTheme) private var theme
    @State private var isHovered: Bool = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Image(systemName: "forward.fill")
                    .font(.system(size: 11))
                Text("Fast-Forward / Skip Download")
                    .font(.system(size: 12))
            }
            .foregroundColor(isHovered ? theme.primaryText : theme.secondaryText)
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(
                isHovered ? theme.secondaryBackground.opacity(0.9) : theme.primaryBackground.opacity(0.8)
            )
            .clipShape(Capsule())
            .overlay(
                Capsule().stroke(isHovered ? Color.accentColor.opacity(0.5) : theme.dividerColor, lineWidth: 1)
            )
            .scaleEffect(isHovered ? 1.02 : 1.0)
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            withAnimation(.easeInOut(duration: 0.15)) {
                isHovered = hovering
            }
        }
    }
}
