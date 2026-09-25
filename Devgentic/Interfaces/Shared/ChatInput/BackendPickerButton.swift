// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
//
//  BackendPickerButton.swift
//  Devgentic
//
//  Extracted from ChatInputAreaView.swift
//

import SwiftUI

struct BackendPickerButton: View {

    let profileThemeColor: Color
    let profileButtonText: String
    var backendConfiguration: BackendConfiguration

    /// Profile types to show in the popup. Nil = show all (legacy).
    var allowedProfileTypes: Set<ProfileType>? = nil

    /// Optional callback to navigate to profile management / settings.
    var onManageProfiles: (() -> Void)? = nil

    @Binding var showingPopup: Bool
    @Environment(\.appTheme) private var theme

    @State private var isHovering = false

    var body: some View {
        Button(action: { showingPopup = true }) {
            HStack(spacing: 7) {
                ZStack {
                    Circle()
                        .fill(profileThemeColor.opacity(0.18))
                        .frame(width: 12, height: 12)
                    Circle()
                        .fill(profileThemeColor)
                        .frame(width: 6.5, height: 6.5)
                }

                Text(profileButtonText)
                    .font(theme.fontCaption.weight(.medium))
                    .foregroundColor(theme.primaryText)
                    .lineLimit(1)

                Image(systemName: "chevron.down")
                    .font(.system(size: 8.5, weight: .semibold))
                    .foregroundColor(theme.secondaryText.opacity(isHovering ? 0.9 : 0.65))
            }
            .padding(.horizontal, 11)
            .padding(.vertical, 6)
            .composerControlSurface(in: Capsule(), isHovered: isHovering)
        }
        .buttonStyle(.plain)
        .popover(isPresented: $showingPopup, arrowEdge: .bottom) {
            ProfileSelectorPopover(
                configuration: backendConfiguration,
                isPresented: $showingPopup,
                allowedProfileTypes: allowedProfileTypes,
                onManageProfiles: onManageProfiles
            )
            .frame(width: 356, height: 460)
            .environment(\.appTheme, theme)
            .tint(theme.accentColor)
            .preferredColorScheme(theme.colorScheme)
        }
        .onHover { hover in withAnimation(.easeInOut(duration: 0.15)) { isHovering = hover } }
        .help("Select a backend (Bot, Agent, Workflow, or Image Gen)")
        .accessibilityLabel("\(profileButtonText). Select a backend")
    }
}
