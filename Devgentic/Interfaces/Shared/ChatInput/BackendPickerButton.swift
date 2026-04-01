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
    @ObservedObject var backendConfiguration: BackendConfiguration

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
                    .font(.system(size: 13, weight: .medium))
                    .foregroundColor(theme.primaryText)
                    .lineLimit(1)

                Image(systemName: "chevron.down")
                    .font(.system(size: 9, weight: .bold))
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
            BackendSelectorPopup(
                configuration: backendConfiguration,
                isPresented: $showingPopup
            )
        }
        .onHover { hover in withAnimation(.spring(response: 0.3, dampingFraction: 0.7)) { isHovering = hover } }
        .help("Select a backend (Bot, Agent, Workflow, or Image Gen)")
        .accessibilityLabel("\(profileButtonText). Select a backend")
    }
}
