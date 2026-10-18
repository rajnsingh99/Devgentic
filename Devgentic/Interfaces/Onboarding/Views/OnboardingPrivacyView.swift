// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
//
//  OnboardingPrivacyView.swift
//  Devgentic
//
//  Created by Raj Singh.
//

import SwiftUI

/// What stays on the Mac, what leaves it and when, the diagnostics opt-out and the update-check
/// question; mirrors PRIVACY.md. The update question has no pre-selected answer, since nothing is
/// requested before the user answers.
struct OnboardingPrivacyView: View {
    @Bindable var viewModel: OnboardingViewModel
    @Environment(\.appTheme) private var theme
    @State private var isShowingPolicy = false

    var body: some View {
        VStack(spacing: 0) {
            ScrollView(.vertical, showsIndicators: false) {
                VStack(spacing: 16) {
                    header

                    VStack(alignment: .leading, spacing: 10) {
                        statement(
                            icon: "lock.shield.fill", color: .green,
                            title: "Stays on your Mac",
                            body: "Your conversations, files, profiles and settings. Local models run entirely on this Mac. No account, no analytics, no telemetry."
                        )
                        statement(
                            icon: "arrow.up.forward.circle.fill", color: .orange,
                            title: "Leaves it only when you choose",
                            body: "Model downloads (Hugging Face or Ollama). Messages to a cloud AI provider or remote MCP server, if you add one. Anything your agent does online, such as web requests or commands — it asks first unless you've allowed that tool. Slack, Discord or Telegram, if you connect them. Update checks, if you allow them below."
                        )
                        statement(
                            icon: "stethoscope", color: .indigo,
                            title: "Diagnostics stay local",
                            body: "Sanitized error and warning traces are kept on this Mac for 30 days to help fix problems. They are never sent anywhere unless you export a report and share it yourself."
                        )
                    }

                    Button {
                        isShowingPolicy = true
                    } label: {
                        Label("Read the full privacy policy", systemImage: "doc.text")
                            .font(.system(size: 12, weight: .medium))
                    }
                    .buttonStyle(.link)
                    .pointingHandCursor()
                    .frame(maxWidth: .infinity, alignment: .leading)

                    diagnosticsToggle

                    updatesChoice
                }
                .frame(maxWidth: 620)
                .padding(.horizontal, 32)
                .padding(.bottom, 16)
            }

            HStack {
                OnboardingSecondaryButton("Back", icon: "chevron.left") {
                    viewModel.goToStep(.permissions)
                }
                Spacer()
                OnboardingPrimaryButton("Continue", isEnabled: viewModel.canContinueFromPrivacy) {
                    viewModel.goToStep(.themeCustomization)
                }
                .help(viewModel.canContinueFromPrivacy ? "" : String(localized: "Choose how to check for updates first."))
            }
            .frame(maxWidth: 620)
            .padding(.horizontal, 32)
            .padding(.top, 10)
            .padding(.bottom, 22)
        }
        .sheet(isPresented: $isShowingPolicy) {
            BundledDocumentView(document: .privacyPolicy) { isShowingPolicy = false }
                .frame(width: 640, height: 600)
        }
    }

    // MARK: - Header
    private var header: some View {
        VStack(spacing: 8) {
            Text(OnboardingViewModel.Step.privacy.progressLabel ?? "")
                .font(.system(size: 11, weight: .bold, design: .rounded))
                .foregroundStyle(Color.accentColor)
                .tracking(1.0)
                .padding(.horizontal, 10)
                .padding(.vertical, 4)
                .background(Color.accentColor.opacity(0.12))
                .clipShape(Capsule())

            Text("Privacy & Updates")
                .font(.system(size: 26, weight: .bold))
                .foregroundColor(theme.primaryText)

            Text("Local-first by design. Here's exactly what that means.")
                .font(theme.fontBody)
                .foregroundColor(theme.secondaryText)
                .multilineTextAlignment(.center)
        }
        .padding(.top, 12)
    }

    // MARK: - Statement
    private func statement(icon: String, color: Color, title: LocalizedStringKey, body: LocalizedStringKey) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 16))
                .foregroundColor(color)
                .frame(width: 24)
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.system(size: 13, weight: .bold))
                    .foregroundColor(theme.primaryText)
                Text(body)
                    .font(.system(size: 12))
                    .foregroundColor(theme.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .accessibilityElement(children: .combine)
    }

    // MARK: - Diagnostics
    private var diagnosticsToggle: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Store diagnostic traces")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(theme.primaryText)
                Text("On this Mac only. Change it any time in Settings → General → Developer.")
                    .font(.system(size: 11))
                    .foregroundColor(theme.secondaryText)
            }
            Spacer()
            Toggle("", isOn: $viewModel.diagnosticsEnabled)
                .toggleStyle(.switch)
                .labelsHidden()
                .tint(theme.accentColor)
                .accessibilityLabel("Store diagnostic traces")
        }
        .padding(12)
        .background(theme.secondaryBackground.opacity(0.6))
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(theme.dividerColor, lineWidth: 1))
    }

    // MARK: - Updates
    private var updatesChoice: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Updates")
                .font(.system(size: 13, weight: .semibold))
                .foregroundColor(theme.primaryText)

            HStack(spacing: 10) {
                updateCard(
                    value: true,
                    title: "Check automatically",
                    detail: "About once a day, fetches a small public file listing the latest version. Sends no system information.",
                    icon: "arrow.triangle.2.circlepath"
                )
                updateCard(
                    value: false,
                    title: "Only when I ask",
                    detail: "Nothing is checked until you choose Devgentic → Check for Updates.",
                    icon: "hand.raised"
                )
            }

            Text("Updates are verified against a signing key built into the app before they install.")
                .font(.system(size: 11))
                .foregroundColor(theme.secondaryText)
        }
    }

    @ViewBuilder
    private func updateCard(value: Bool, title: LocalizedStringKey, detail: LocalizedStringKey, icon: String) -> some View {
        let isSelected = viewModel.automaticUpdateChecks == value

        Button(action: { viewModel.automaticUpdateChecks = value }) {
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Image(systemName: icon)
                        .foregroundColor(isSelected ? Color.accentColor : theme.secondaryText)
                    Text(title)
                        .font(.system(size: 13, weight: .bold))
                        .foregroundColor(theme.primaryText)
                    Spacer()
                    Image(systemName: isSelected ? "largecircle.fill.circle" : "circle")
                        .foregroundColor(isSelected ? Color.accentColor : theme.secondaryText.opacity(0.7))
                }
                Text(detail)
                    .font(.system(size: 11))
                    .foregroundColor(theme.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .topLeading)
            .background(isSelected ? Color.accentColor.opacity(0.08) : theme.secondaryBackground.opacity(0.6))
            .clipShape(RoundedRectangle(cornerRadius: 12))
            .overlay(
                RoundedRectangle(cornerRadius: 12)
                    .stroke(isSelected ? Color.accentColor : theme.dividerColor, lineWidth: isSelected ? 1.5 : 1)
            )
            .contentShape(RoundedRectangle(cornerRadius: 12))
        }
        .buttonStyle(.plain)
        .pointingHandCursor()
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}
