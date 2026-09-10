// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2026 Raj Singh
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

    @Binding var showingPopup: Bool
    @Environment(\.appTheme) private var theme

    @State private var isHovering = false

    var body: some View {
        Button(action: { showingPopup = true }) {
            HStack(spacing: 7) {
                ZStack {
                    Circle()
                        .fill(profileThemeColor.opacity(0.25))
                        .frame(width: 12, height: 12)
                    Circle()
                        .fill(profileThemeColor)
                        .frame(width: 7, height: 7)
                        .shadow(color: profileThemeColor.opacity(0.7), radius: 3, x: 0, y: 0)
                }

                Text(profileButtonText)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(theme.primaryText)
                    .lineLimit(1)

                Image(systemName: "chevron.down")
                    .font(.system(size: 8, weight: .bold))
                    .foregroundColor(theme.secondaryText.opacity(0.85))
            }
            .padding(.horizontal, 11)
            .padding(.vertical, 6)
            .background(
                Capsule()
                    .fill(isHovering ? theme.surfaceOverlayStrong : theme.surfaceOverlay)
            )
            .overlay(
                Capsule()
                    .strokeBorder(
                        LinearGradient(
                            colors: isHovering
                                ? [profileThemeColor.opacity(0.5), theme.secondaryText.opacity(0.3)]
                                : [theme.secondaryText.opacity(0.2), theme.secondaryText.opacity(0.1)],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        ),
                        lineWidth: 1
                    )
            )
            .scaleEffect(isHovering ? 1.025 : 1.0)
        }
        .buttonStyle(.plain)
        .popover(isPresented: $showingPopup, arrowEdge: .bottom) {
            // Redesigned selector (search + type bubbles + single fixed-width list) — replaced the
            // multi-column BackendSelectorPopup, whose 180pt-per-type columns overflowed the
            // popover's resolved width and clipped.
            ProfileSelectorPopover(
                configuration: backendConfiguration,
                isPresented: $showingPopup,
                allowedProfileTypes: allowedProfileTypes
            )
        }
        .onHover { hover in withAnimation(.spring(response: 0.3, dampingFraction: 0.7)) { isHovering = hover } }
        .help("Select a backend (Bot, Agent, Workflow, or Image Gen)")
        .accessibilityLabel("\(profileButtonText). Select a backend")
    }
}
