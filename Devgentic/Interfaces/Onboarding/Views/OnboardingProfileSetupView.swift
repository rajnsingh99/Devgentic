// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
//
//  OnboardingProfileSetupView.swift
//  Devgentic
//
//  Created by Raj Singh on 17/09/26.
//

import SwiftUI

struct OnboardingProfileSetupView: View {
    @Bindable var viewModel: OnboardingViewModel
    @Environment(\.appTheme) private var theme

    var body: some View {
        VStack(spacing: 0) {
            // Scrollable Content
            ScrollView(.vertical, showsIndicators: false) {
                VStack(spacing: 20) {
                    // Header
                    VStack(spacing: 8) {
                        HStack(spacing: 6) {
                            Text("STEP 1 OF 3")
                                .font(.system(size: 11, weight: .bold, design: .rounded))
                                .foregroundStyle(Color.accentColor)
                                .tracking(1.0)
                        }
                        .padding(.horizontal, 10)
                        .padding(.vertical, 4)
                        .background(Color.accentColor.opacity(0.12))
                        .clipShape(Capsule())

                        Text("Create Your First AI Profile")
                            .font(.system(size: 26, weight: .bold))
                            .foregroundColor(theme.primaryText)

                        Text("Configure your local intelligence unit. All computation stays 100% on your Mac.")
                            .font(theme.fontBody)
                            .foregroundColor(theme.secondaryText)
                    }
                    .padding(.top, 12)

                    // Setup Options
                    VStack(spacing: 18) {

                        // 1. Profile Name
                        VStack(alignment: .leading, spacing: 6) {
                            Text("Profile Name")
                                .font(.system(size: 13, weight: .semibold))
                                .foregroundColor(theme.primaryText)

                            TextField("e.g. Local Assistant, Coding Bot", text: $viewModel.profileDisplayName)
                                .textFieldStyle(.plain)
                                .font(.system(size: 13))
                                .padding(11)
                                .background(theme.secondaryBackground)
                                .clipShape(RoundedRectangle(cornerRadius: 11))
                                .overlay(
                                    RoundedRectangle(cornerRadius: 11)
                                        .stroke(theme.dividerColor, lineWidth: 1)
                                )
                        }

                        // 2. Intelligence Type (Bot vs Agent)
                        VStack(alignment: .leading, spacing: 6) {
                            Text("Intelligence Type")
                                .font(.system(size: 13, weight: .semibold))
                                .foregroundColor(theme.primaryText)

                            HStack(spacing: 12) {
                                // Bot Card
                                profileTypeCard(
                                    type: .bot,
                                    title: "Chat Bot",
                                    description: "Fast conversational Q&A and text drafting without tool overhead.",
                                    icon: "bubble.left.and.bubble.right.fill",
                                    accent: Color.blue
                                )

                                // Agent Card
                                profileTypeCard(
                                    type: .agent,
                                    title: "Autonomous Agent",
                                    description: "ReAct loop with 72 native macOS tools (Filesystem, Shell, Safari).",
                                    icon: "bolt.shield.fill",
                                    accent: Color.green
                                )
                            }
                        }

                        // 3. Local Engine Provider (MLX vs Ollama)
                        VStack(alignment: .leading, spacing: 6) {
                            HStack {
                                Text("Local Inference Engine")
                                    .font(.system(size: 13, weight: .semibold))
                                    .foregroundColor(theme.primaryText)
                                Spacer()
                                HStack(spacing: 5) {
                                    Circle().fill(Color.green).frame(width: 6, height: 6)
                                    Text("100% Private & Local")
                                        .font(.system(size: 11, weight: .medium))
                                        .foregroundColor(.green)
                                }
                            }

                            HStack(spacing: 12) {
                                // MLX Option
                                engineOptionCard(
                                    provider: .mlx,
                                    title: "MLX (Apple Silicon)",
                                    subtitle: "Native Metal acceleration",
                                    description: "Direct Hugging Face Hub downloads. Highly optimized for Apple M-series chips.",
                                    icon: "apple.logo"
                                )

                                // Ollama Option
                                engineOptionCard(
                                    provider: .ollama,
                                    title: "Ollama",
                                    subtitle: "Local daemon endpoint",
                                    description: "Runs via local Ollama server on localhost:11434 with instant model switching.",
                                    icon: "server.rack"
                                )
                            }
                        }

                        // 4. Starter Model Status Banner
                        modelStatusBanner
                    }
                    .frame(maxWidth: 620)
                }
                .padding(.horizontal, 32)
                .padding(.bottom, 16)
            }

            // Pinned Bottom Navigation Actions (Always fully visible, hover reactive)
            HStack {
                OnboardingSecondaryButton("Back", icon: "chevron.left") {
                    viewModel.goToStep(.welcome)
                }

                Spacer()

                OnboardingPrimaryButton(
                    viewModel.isModelInstalled ? "Continue to Customization" : "Download Model & Continue"
                ) {
                    viewModel.proceedFromProfileSetup()
                }
            }
            .frame(maxWidth: 620)
            .padding(.horizontal, 32)
            .padding(.top, 10)
            .padding(.bottom, 22)
        }
    }

    // MARK: - Profile Type Card
    @ViewBuilder
    private func profileTypeCard(
        type: ProfileType,
        title: String,
        description: String,
        icon: String,
        accent: Color
    ) -> some View {
        let isSelected = viewModel.selectedProfileType == type

        Button(action: { viewModel.selectedProfileType = type }) {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    ZStack {
                        Circle()
                            .fill(isSelected ? accent.opacity(0.2) : theme.primaryBackground)
                            .frame(width: 36, height: 36)
                        ProfileTypeIcon(
                            type: type,
                            size: 18,
                            color: isSelected ? accent : theme.secondaryText,
                            isFilled: isSelected
                        )
                    }

                    Spacer()

                    if isSelected {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundColor(accent)
                            .font(.system(size: 18))
                    } else {
                        Circle()
                            .stroke(theme.dividerColor, lineWidth: 1.5)
                            .frame(width: 18, height: 18)
                    }
                }

                Text(title)
                    .font(.system(size: 14, weight: .bold))
                    .foregroundColor(theme.primaryText)

                Text(description)
                    .font(.system(size: 12))
                    .foregroundColor(theme.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
                    .lineLimit(2)
                    .lineSpacing(2)
            }
            .padding(14)
            .background(isSelected ? accent.opacity(0.08) : theme.secondaryBackground.opacity(0.65))
            .clipShape(RoundedRectangle(cornerRadius: 14))
            .overlay(
                RoundedRectangle(cornerRadius: 14)
                    .stroke(isSelected ? accent : theme.dividerColor, lineWidth: isSelected ? 1.5 : 1)
            )
        }
        .buttonStyle(.plain)
    }

    // MARK: - Engine Option Card
    @ViewBuilder
    private func engineOptionCard(
        provider: ApiProvider,
        title: String,
        subtitle: String,
        description: String,
        icon: String
    ) -> some View {
        let isSelected = viewModel.selectedBackend == provider

        Button(action: {
            viewModel.selectedBackend = provider
            viewModel.checkInstalledModelStatus()
        }) {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    Image(systemName: icon)
                        .font(.system(size: 14, weight: .bold))
                        .foregroundColor(isSelected ? Color.accentColor : theme.secondaryText)

                    Text(title)
                        .font(.system(size: 13, weight: .bold))
                        .foregroundColor(theme.primaryText)

                    Spacer()

                    if isSelected {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundColor(Color.accentColor)
                            .font(.system(size: 15))
                    }
                }

                Text(description)
                    .font(.system(size: 11))
                    .foregroundColor(theme.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
                    .lineLimit(2)
                    .lineSpacing(2)
            }
            .padding(12)
            .background(isSelected ? Color.accentColor.opacity(0.08) : theme.secondaryBackground.opacity(0.65))
            .clipShape(RoundedRectangle(cornerRadius: 12))
            .overlay(
                RoundedRectangle(cornerRadius: 12)
                    .stroke(isSelected ? Color.accentColor : theme.dividerColor, lineWidth: isSelected ? 1.5 : 1)
            )
        }
        .buttonStyle(.plain)
    }

    // MARK: - Starter Model Status Banner
    private var modelStatusBanner: some View {
        HStack(spacing: 14) {
            ZStack {
                RoundedRectangle(cornerRadius: 10)
                    .fill(viewModel.isModelInstalled ? Color.green.opacity(0.15) : Color.indigo.opacity(0.15))
                    .frame(width: 42, height: 42)
                Image(systemName: viewModel.isModelInstalled ? "checkmark.seal.fill" : "arrow.down.circle.fill")
                    .font(.system(size: 18))
                    .foregroundColor(viewModel.isModelInstalled ? .green : .indigo)
            }

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 8) {
                    Text(viewModel.selectedBackend == .mlx ? "Llama 3.2 3B Instruct" : "llama3.2:3b")
                        .font(.system(size: 13, weight: .bold))
                        .foregroundColor(theme.primaryText)

                    Text("Recommended Starter")
                        .font(.system(size: 10, weight: .medium))
                        .padding(.horizontal, 7)
                        .padding(.vertical, 2)
                        .background(Color.accentColor.opacity(0.15))
                        .foregroundColor(Color.accentColor)
                        .clipShape(Capsule())
                }

                Text(viewModel.isModelInstalled ? "Model weights already verified in local cache." : "Lightweight (~1.9 GB), fast local inference on Apple Silicon.")
                    .font(.system(size: 11))
                    .foregroundColor(theme.secondaryText)
            }

            Spacer()

            if viewModel.isCheckingModelStatus {
                ProgressView()
                    .controlSize(.small)
            } else if viewModel.isModelInstalled {
                Text("Installed")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(.green)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 4)
                    .background(Color.green.opacity(0.12))
                    .clipShape(Capsule())
            } else {
                Text("Needs Download")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(.orange)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 4)
                    .background(Color.orange.opacity(0.12))
                    .clipShape(Capsule())
            }
        }
        .padding(12)
        .background(theme.secondaryBackground.opacity(0.55))
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(theme.dividerColor.opacity(0.8), lineWidth: 1)
        )
    }
}
