// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
//
//  SidebarAnimations.swift
//  Devgentic
//
//  Shared animation utilities and reusable components for the sidebar.
//

import SwiftUI

// MARK: - Streaming Pulse Indicator
/// An animated pulsing dot indicating an active streaming conversation.
struct StreamingPulseIndicator: View {
    /// `nil` → the theme's streaming color. The sidebar row passes `warningColor`
    /// for the needs-input state — ONE indicator, two colors (user decision
    /// 2026-07-19: yellow = waiting on you, streaming color = generating).
    var color: Color? = nil

    @State private var isPulsing = false
    @Environment(\.appTheme) private var theme

    private var fillColor: Color { color ?? theme.streamingIndicator }

    var body: some View {
        Circle()
            .fill(fillColor)
            .frame(width: 8, height: 8)
            .scaleEffect(isPulsing ? 1.3 : 0.8)
            .opacity(isPulsing ? 1.0 : 0.5)
            .shadow(color: fillColor.opacity(isPulsing ? 0.4 : 0.0), radius: 4)
            .animation(
                .easeInOut(duration: 0.8)
                .repeatForever(autoreverses: true),
                value: isPulsing
            )
            .onAppear { isPulsing = true }
    }
}

// MARK: - Hover Action Button
/// A small icon button that reveals on hover, used for inline row actions.
struct HoverActionButton: View {
    let icon: String
    var label: LocalizedStringKey = ""
    var tint: Color = .secondary
    let action: () -> Void
    @State private var isHovering = false
    @Environment(\.appTheme) private var theme

    var body: some View {
        Button(action: action) {
            ZStack {
                Color.clear
                Image(systemName: icon)
                    .font(.system(.caption, weight: .medium))
                    .foregroundColor(isHovering ? tint : theme.tertiaryText)
                    .offset(y: icon.contains("pin") ? -1.5 : 0)
            }
            .frame(width: 22, height: 22)
        }
        .buttonStyle(.plain)
        .frame(width: 22, height: 22)
        .background(
            RoundedRectangle(cornerRadius: 5, style: .continuous)
                .fill(isHovering ? theme.surfaceOverlay : Color.clear)
        )
        .onHover { isHovering = $0 }
        .accessibilityLabel(label)
    }
}
