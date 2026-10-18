// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
//
//  OnboardingPermissionsView.swift
//  Devgentic
//
//  Created by Raj Singh.
//

import SwiftUI

/// The macOS permissions the user's choices need, and only those.
/// Every one is optional: Continue never waits, and a skipped permission is asked again when first needed.
struct OnboardingPermissionsView: View {
    @Bindable var viewModel: OnboardingViewModel
    @Environment(\.appTheme) private var theme

    var body: some View {
        VStack(spacing: 0) {
            ScrollView(.vertical, showsIndicators: false) {
                VStack(spacing: 18) {
                    header

                    VStack(spacing: 10) {
                        ForEach(viewModel.relevantPermissions) { permission in
                            permissionRow(permission)
                        }
                    }

                    HStack(alignment: .top, spacing: 8) {
                        Image(systemName: "info.circle")
                            .foregroundColor(theme.secondaryText)
                        Text("All optional. Folders, Notes and other apps are asked by macOS the first time your agent needs them, and every answer can be changed in System Settings → Privacy & Security.")
                            .font(.system(size: 11))
                            .foregroundColor(theme.secondaryText)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .frame(maxWidth: 620)
                .padding(.horizontal, 32)
                .padding(.bottom, 16)
            }

            HStack {
                OnboardingSecondaryButton("Back", icon: "chevron.left") {
                    viewModel.goToStep(.features)
                }
                Spacer()
                OnboardingPrimaryButton("Continue") {
                    viewModel.goToStep(.privacy)
                }
            }
            .frame(maxWidth: 620)
            .padding(.horizontal, 32)
            .padding(.top, 10)
            .padding(.bottom, 22)
        }
        .onAppear { viewModel.refreshPermissionStatuses() }
        // Coming back from System Settings: show what the user changed there.
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            viewModel.refreshPermissionStatuses()
        }
    }

    // MARK: - Header
    private var header: some View {
        VStack(spacing: 8) {
            Text(OnboardingViewModel.Step.permissions.progressLabel ?? "")
                .font(.system(size: 11, weight: .bold, design: .rounded))
                .foregroundStyle(Color.accentColor)
                .tracking(1.0)
                .padding(.horizontal, 10)
                .padding(.vertical, 4)
                .background(Color.accentColor.opacity(0.12))
                .clipShape(Capsule())

            Text("Allow Access")
                .font(.system(size: 26, weight: .bold))
                .foregroundColor(theme.primaryText)

            Text("Only what your choices need. macOS asks you to confirm each one.")
                .font(theme.fontBody)
                .foregroundColor(theme.secondaryText)
                .multilineTextAlignment(.center)
        }
        .padding(.top, 12)
    }

    // MARK: - Row
    @ViewBuilder
    private func permissionRow(_ permission: OnboardingPermission) -> some View {
        let status = viewModel.status(of: permission)

        HStack(spacing: 12) {
            Image(systemName: permission.iconName)
                .font(.system(size: 16))
                .foregroundColor(status == .granted ? .green : Color.accentColor)
                .frame(width: 26)

            VStack(alignment: .leading, spacing: 3) {
                Text(permission.title)
                    .font(.system(size: 13, weight: .bold))
                    .foregroundColor(theme.primaryText)
                Text(viewModel.reason(for: permission))
                    .font(.system(size: 11))
                    .foregroundColor(theme.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 8)

            switch status {
            case .granted:
                Label("Allowed", systemImage: "checkmark.circle.fill")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(.green)
            case .notAsked:
                if viewModel.requestingPermission == permission {
                    ProgressView().controlSize(.small)
                } else {
                    TactileButton(title: "Allow", icon: "hand.raised", variant: .primary, size: .compact) {
                        Task { await viewModel.requestPermission(permission) }
                    }
                    .disabled(viewModel.requestingPermission != nil)
                }
            case .denied:
                TactileButton(title: "Open Settings", icon: "gear", variant: .secondary, size: .compact) {
                    viewModel.systemSettings.openSystemSettings(for: permission)
                }
                .help("macOS won't ask again. Turn it on in System Settings, then come back.")
            }
        }
        .padding(12)
        .background(theme.secondaryBackground.opacity(0.6))
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(status == .granted ? Color.green.opacity(0.4) : theme.dividerColor, lineWidth: 1)
        )
        .accessibilityElement(children: .contain)
        .accessibilityLabel(permission.title)
        .accessibilityValue(status == .granted ? String(localized: "Allowed")
                            : status == .denied ? String(localized: "Not allowed") : String(localized: "Not asked yet"))
    }
}
