// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
//
//  OnboardingFeaturesView.swift
//  Devgentic
//
//  Opt-in switches for Quick Access and the Orb, each with its global shortcut. They apply
//  immediately, through the same path as their Settings panes. Microphone access for the Orb is
//  asked on the next step, alongside the other permissions, not here.
//

import SwiftUI

struct OnboardingFeaturesView: View {
    @Bindable var viewModel: OnboardingViewModel
    @Environment(\.appTheme) private var theme

    private let quickAccess = QuickAccessConfigManager.shared
    private let orb = OrbConfigManager.shared

    var body: some View {
        VStack(spacing: 0) {
            ScrollView(.vertical, showsIndicators: false) {
                VStack(spacing: 18) {
                    header

                    featureCard(
                        title: "Quick Access",
                        badge: nil,
                        description: "A floating panel over any app. Ask a question, attach a screenshot, and get back to work.",
                        icon: "sparkles.rectangle.stack.fill",
                        accent: .orange,
                        isOn: Binding(get: { viewModel.quickAccessEnabled }, set: { viewModel.setQuickAccessEnabled($0) })
                    ) {
                        shortcutRow(
                            label: "Open with",
                            description: quickAccess.shortcutDescription,
                            isEnabled: viewModel.quickAccessEnabled,
                            onRecorded: { code, mods in
                                quickAccess.setShortcut(carbonKeyCode: code, carbonModifiers: mods)
                                AppDelegate.shared?.applyHotkeyConfig()
                            },
                            onRecordingStateChanged: { AppDelegate.shared?.setHotkeyPaused($0) },
                            onReset: {
                                quickAccess.resetShortcutToDefault()
                                AppDelegate.shared?.applyHotkeyConfig()
                            }
                        )
                    }

                    featureCard(
                        title: "Orb Voice Assistant",
                        badge: "Experimental",
                        description: "A floating orb you talk to. Hold the shortcut, speak, and release — it runs the task and can read the answer back.",
                        icon: "waveform.circle.fill",
                        accent: .cyan,
                        isOn: Binding(get: { viewModel.orbEnabled }, set: { viewModel.setOrbEnabled($0) })
                    ) {
                        if orb.activationMode == .holdShortcut {
                            shortcutRow(
                                label: "Hold to talk",
                                description: orb.shortcutDescription,
                                isEnabled: viewModel.orbEnabled,
                                onRecorded: { code, mods in
                                    orb.setShortcut(carbonKeyCode: code, carbonModifiers: mods)
                                    AppDelegate.shared?.applyOrbHotkeyConfig()
                                },
                                onRecordingStateChanged: { AppDelegate.shared?.setOrbHotkeyPaused($0) },
                                onReset: {
                                    orb.resetShortcutToDefault()
                                    AppDelegate.shared?.applyOrbHotkeyConfig()
                                }
                            )
                        }
                    }

                    Text("Both can be changed any time in Settings.")
                        .font(.system(size: 11))
                        .foregroundColor(theme.secondaryText)
                }
                .frame(maxWidth: 620)
                .padding(.horizontal, 32)
                .padding(.bottom, 16)
            }

            HStack {
                OnboardingSecondaryButton("Back", icon: "chevron.left") {
                    viewModel.goToStep(.behavior)
                }
                Spacer()
                OnboardingPrimaryButton("Continue") {
                    viewModel.goToStep(.permissions)
                }
            }
            .frame(maxWidth: 620)
            .padding(.horizontal, 32)
            .padding(.top, 10)
            .padding(.bottom, 22)
        }
    }

    // MARK: - Header
    private var header: some View {
        VStack(spacing: 8) {
            Text(OnboardingViewModel.Step.features.progressLabel ?? "")
                .font(.system(size: 11, weight: .bold, design: .rounded))
                .foregroundStyle(Color.accentColor)
                .tracking(1.0)
                .padding(.horizontal, 10)
                .padding(.vertical, 4)
                .background(Color.accentColor.opacity(0.12))
                .clipShape(Capsule())

            Text("Choose Your Shortcuts")
                .font(.system(size: 26, weight: .bold))
                .foregroundColor(theme.primaryText)

            Text("Reach Devgentic from any app. Turn on what you'll use.")
                .font(theme.fontBody)
                .foregroundColor(theme.secondaryText)
                .multilineTextAlignment(.center)
        }
        .padding(.top, 12)
    }

    // MARK: - Feature Card
    @ViewBuilder
    private func featureCard<Detail: View>(
        title: LocalizedStringKey,
        badge: LocalizedStringKey?,
        description: LocalizedStringKey,
        icon: String,
        accent: Color,
        isOn: Binding<Bool>,
        @ViewBuilder detail: () -> Detail
    ) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: icon)
                    .font(.system(size: 20))
                    .foregroundColor(isOn.wrappedValue ? accent : theme.secondaryText)
                    .frame(width: 28)

                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 6) {
                        Text(title)
                            .font(.system(size: 14, weight: .bold))
                            .foregroundColor(theme.primaryText)
                        if let badge {
                            Text(badge)
                                .font(.system(size: 10, weight: .medium))
                                .padding(.horizontal, 7)
                                .padding(.vertical, 2)
                                .background(Color.orange.opacity(0.14))
                                .foregroundColor(.orange)
                                .clipShape(Capsule())
                        }
                    }
                    Text(description)
                        .font(.system(size: 12))
                        .foregroundColor(theme.secondaryText)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Spacer(minLength: 8)

                Toggle("", isOn: isOn)
                    .toggleStyle(.switch)
                    .labelsHidden()
                    .tint(theme.accentColor)
                    .accessibilityLabel(Text(title))
            }

            detail()
        }
        .padding(14)
        .background(isOn.wrappedValue ? accent.opacity(0.06) : theme.secondaryBackground.opacity(0.6))
        .clipShape(RoundedRectangle(cornerRadius: 14))
        .overlay(
            RoundedRectangle(cornerRadius: 14)
                .stroke(isOn.wrappedValue ? accent.opacity(0.5) : theme.dividerColor, lineWidth: 1)
        )
    }

    // MARK: - Shortcut Row
    private func shortcutRow(
        label: LocalizedStringKey,
        description: String,
        isEnabled: Bool,
        onRecorded: @escaping (UInt32, UInt32) -> Void,
        onRecordingStateChanged: @escaping (Bool) -> Void,
        onReset: @escaping () -> Void
    ) -> some View {
        HStack(spacing: 8) {
            Text(label)
                .font(.system(size: 12, weight: .medium))
                .foregroundColor(theme.secondaryText)
                .padding(.leading, 40)
            Spacer()
            HotkeyRecorderView(
                currentDescription: description,
                onRecorded: onRecorded,
                onRecordingStateChanged: onRecordingStateChanged
            )
            TactileIconButton(icon: "arrow.counterclockwise", tooltip: String(localized: "Reset to default"),
                              accessibilityLabel: String(localized: "Reset shortcut"), size: 24, isDisabled: !isEnabled, action: onReset)
        }
        .disabled(!isEnabled)
        .opacity(isEnabled ? 1 : 0.5)
    }
}
