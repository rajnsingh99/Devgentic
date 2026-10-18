// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
//
//  OnboardingReadyView.swift
//  Devgentic
//
//  Created by Raj Singh.
//

import SwiftUI

struct OnboardingReadyView: View {
    @Bindable var viewModel: OnboardingViewModel
    let onComplete: (_ createdProfileID: UUID?) -> Void

    @Environment(ThemeManager.self) private var themeManager
    @Environment(\.appTheme) private var theme

    @State private var isHoveringLaunch: Bool = false

    var body: some View {
        VStack(spacing: 0) {
            Spacer(minLength: 8)

            // Header with Success Badge
            VStack(spacing: 10) {
                ZStack {
                    Circle()
                        .fill(
                            LinearGradient(
                                colors: [Color.green.opacity(0.3), Color.cyan.opacity(0.2)],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                        )
                        .frame(width: 68, height: 68)
                        .blur(radius: 8)

                    Circle()
                        .fill(
                            LinearGradient(
                                colors: [Color.green, Color.cyan],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                        )
                        .frame(width: 52, height: 52)
                        .shadow(color: Color.green.opacity(0.4), radius: 10)

                    Image(systemName: "checkmark")
                        .font(.system(size: 24, weight: .bold))
                        .foregroundColor(.white)
                }

                Text(viewModel.isModelInstalled ? String(localized: "Setup Complete!") : String(localized: "Almost There"))
                    .font(.system(size: 26, weight: .bold))
                    .foregroundColor(theme.primaryText)

                Text(viewModel.isModelInstalled
                     ? String(localized: "Review your profile, then launch. You can change any of this later.")
                     : String(localized: "Your profile will be created, but its model isn't downloaded yet. Download it from the Model Store before your first chat."))
                    .font(theme.fontBody)
                    .foregroundColor(theme.secondaryText)
                    .multilineTextAlignment(.center)
            }
            .padding(.top, 8)
            .padding(.bottom, 20)

            // Setup Timeline View
            timelineCard
                .frame(maxWidth: 520)

            Spacer(minLength: 16)

            if let error = viewModel.completionErrorMessage {
                HStack(spacing: 8) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundColor(.red)
                    Text(error)
                        .font(.system(size: 12))
                        .foregroundColor(.red)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(10)
                .frame(maxWidth: 520)
                .background(Color.red.opacity(0.1))
                .clipShape(RoundedRectangle(cornerRadius: 9))
                .padding(.bottom, 8)
            }

            // Circular "Launch Devgentic" Button with Hover Effect
            roundLaunchButton

            Spacer(minLength: 16)
        }
        .padding(.horizontal, 32)
        .padding(.bottom, 20)
    }

    // MARK: - Setup Timeline Card
    private var timelineCard: some View {
        VStack(alignment: .leading, spacing: 0) {
            timelineItem(
                label: String(localized: "Profile"),
                value: viewModel.trimmedProfileName,
                tag: viewModel.selectedProfileType == .agent ? String(localized: "Agent") : String(localized: "Chat Bot"),
                nodeColor: Color.blue,
                isLast: false
            )

            timelineItem(
                label: viewModel.selectedBackend == .mlx ? String(localized: "Model · MLX") : String(localized: "Model · Ollama"),
                value: viewModel.selectedModel?.displayName ?? viewModel.selectedModelIdentifier,
                tag: viewModel.isModelInstalled ? String(localized: "Downloaded") : String(localized: "Not downloaded"),
                nodeColor: viewModel.isModelInstalled ? Color.cyan : Color.orange,
                isLast: false
            )

            if viewModel.selectedProfileType == .agent {
                timelineItem(
                    label: String(localized: "Tools"),
                    value: String(localized: "\(viewModel.enabledToolNames.count) of \(OnboardingToolPreset.tools.count) enabled"),
                    tag: toolApprovalTag,
                    nodeColor: Color.indigo,
                    isLast: false
                )
            }

            timelineItem(
                label: String(localized: "Shortcuts"),
                value: shortcutsSummary,
                tag: viewModel.orbEnabled ? String(localized: "Orb on") : String(localized: "Orb off"),
                nodeColor: Color.orange,
                isLast: false
            )

            timelineItem(
                label: String(localized: "Updates"),
                value: viewModel.automaticUpdateChecks == true ? String(localized: "Checked automatically") : String(localized: "Only when you ask"),
                tag: viewModel.diagnosticsEnabled ? String(localized: "Diagnostics on this Mac") : String(localized: "Diagnostics off"),
                nodeColor: Color.green,
                isLast: false
            )

            timelineItem(
                label: String(localized: "System Prompt"),
                value: viewModel.systemPrompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    ? String(localized: "None") : (viewModel.systemPrompt == OnboardingPromptDefaults.prompt(for: viewModel.selectedProfileType) ? String(localized: "Default") : String(localized: "Custom")),
                tag: String(localized: "\(viewModel.systemPrompt.count) chars"),
                nodeColor: Color.purple,
                isLast: true
            )
        }
        .padding(.vertical, 16)
        .padding(.horizontal, 20)
        .background(theme.secondaryBackground.opacity(0.65))
        .clipShape(RoundedRectangle(cornerRadius: 16))
        .overlay(
            RoundedRectangle(cornerRadius: 16)
                .stroke(theme.dividerColor.opacity(0.7), lineWidth: 1)
        )
    }

    private var shortcutsSummary: String {
        viewModel.quickAccessEnabled
            ? String(localized: "Quick Access \(QuickAccessConfigManager.shared.shortcutDescription)")
            : String(localized: "Quick Access off")
    }

    private var toolApprovalTag: String {
        let allowed = viewModel.autoApprovedToolNames.intersection(viewModel.enabledToolNames).count
        return allowed == 0 ? String(localized: "All ask first") : String(localized: "\(allowed) without asking")
    }

    // MARK: - Timeline Item Row
    @ViewBuilder
    private func timelineItem(
        label: String,
        value: String,
        tag: String,
        nodeColor: Color,
        isLast: Bool
    ) -> some View {
        HStack(alignment: .top, spacing: 14) {
            // Node circle & connecting line
            VStack(spacing: 0) {
                ZStack {
                    Circle()
                        .fill(nodeColor.opacity(0.16))
                        .frame(width: 22, height: 22)

                    Circle()
                        .stroke(nodeColor.opacity(0.85), lineWidth: 1.5)
                        .frame(width: 22, height: 22)

                    Image(systemName: "checkmark")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundColor(nodeColor)
                }

                if !isLast {
                    Rectangle()
                        .fill(
                            LinearGradient(
                                colors: [nodeColor.opacity(0.5), nodeColor.opacity(0.15)],
                                startPoint: .top,
                                endPoint: .bottom
                            )
                        )
                        .frame(width: 2, height: 20)
                }
            }

            // Timeline Content
            VStack(alignment: .leading, spacing: 2) {
                HStack {
                    Text(label)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(theme.secondaryText)

                    Spacer()

                    Text(tag)
                        .font(.system(size: 10, weight: .semibold, design: .rounded))
                        .foregroundColor(nodeColor)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 2)
                        .background(nodeColor.opacity(0.12))
                        .clipShape(Capsule())
                }

                Text(value)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(theme.primaryText)
            }
            .padding(.bottom, isLast ? 0 : 6)
        }
    }

    // MARK: - Circular Launch Button with Hover Effect
    private var roundLaunchButton: some View {
        Button(action: {
            viewModel.completeOnboarding(themeManager: themeManager, onComplete: onComplete)
        }) {
            VStack(spacing: 10) {
                ZStack {
                    // Outer pulsating glow ring on hover
                    Circle()
                        .stroke(
                            LinearGradient(
                                colors: [Color.indigo.opacity(0.6), Color.cyan.opacity(0.6)],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            ),
                            lineWidth: 2
                        )
                        .frame(width: 80, height: 80)
                        .scaleEffect(isHoveringLaunch ? 1.14 : 1.0)
                        .opacity(isHoveringLaunch ? 0.8 : 0)

                    // Main round button
                    Circle()
                        .fill(
                            LinearGradient(
                                colors: [Color.indigo, Color.cyan],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                        )
                        .frame(width: 66, height: 66)
                        .shadow(
                            color: Color.indigo.opacity(isHoveringLaunch ? 0.6 : 0.35),
                            radius: isHoveringLaunch ? 16 : 10,
                            x: 0,
                            y: isHoveringLaunch ? 6 : 3
                        )
                        .scaleEffect(isHoveringLaunch ? 1.08 : 1.0)

                    // Icon inside round button
                    Image(systemName: "arrow.right")
                        .font(.system(size: 24, weight: .bold))
                        .foregroundColor(.white)
                        .offset(x: isHoveringLaunch ? 3 : 0)
                }

                VStack(spacing: 2) {
                    Text("Launch Devgentic")
                        .font(.system(size: 14, weight: .bold))
                        .foregroundColor(theme.primaryText)

                    Text("Click to enter your workspace")
                        .font(.system(size: 11))
                        .foregroundColor(theme.secondaryText)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .keyboardShortcut(.defaultAction)
        .pointingHandCursor()
        .accessibilityLabel("Launch Devgentic")
        .accessibilityHint("Creates your profile and opens the app")
        .onHover { hovering in
            withAnimation(.spring(response: 0.3, dampingFraction: 0.7)) {
                isHoveringLaunch = hovering
            }
        }
    }
}
