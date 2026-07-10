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
            HStack(spacing: 6) {
                Circle()
                    .fill(profileThemeColor)
                    .frame(width: 8, height: 8)
                    .shadow(color: profileThemeColor.opacity(0.4), radius: 2, x: 0, y: 0)

                Text(profileButtonText)
                    .font(theme.fontSubheadline.weight(.medium))
                    .foregroundColor(theme.primaryText)
                    .lineLimit(1)

                Image(systemName: "chevron.down")
                    .font(.system(size: 9, weight: .bold)) // Fixed size: intentional (badge/chip text)
                    .foregroundColor(theme.secondaryText.opacity(0.8))
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(
                Capsule()
                    .fill(isHovering ? theme.surfaceOverlay : Color.clear)
            )
            .overlay(
                Capsule()
                    .stroke(theme.secondaryText.opacity(isHovering ? 0.3 : 0.15), lineWidth: 1)
            )
            .scaleEffect(isHovering ? 1.02 : 1.0)
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
