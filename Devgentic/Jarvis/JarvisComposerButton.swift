// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2026 Raj Singh
//
//  JarvisComposerButton.swift
//  Devgentic
//
//  [Jarvis MVP] The composer entry point — sits next to the voice button in the main
//  chat input bar and toggles the floating Jarvis panel. Follows ComposerIconButton's
//  discipline (28×28, transparent at rest, circle on hover) with a hologram-cyan
//  hover tint as its signature.
//
//  This is also where the shared object graph crosses into Jarvis: the panel lives
//  outside the SwiftUI environment (it's a separate NSPanel window), so the view
//  model is handed over explicitly here — the same way AppDelegate threads it into
//  the QuickAccess panel.
//

import SwiftUI

struct JarvisComposerButton: View {
    @Environment(MainApplicationViewModel.self) private var mainVM
    @Environment(\.appTheme) private var theme
    @State private var isHovered = false
    /// Self-gating on the enable flag keeps the composer's own layout code free of Jarvis
    /// conditionals — the button simply isn't there when the feature is off.
    @State private var config = JarvisConfigManager.shared

    var body: some View {
        if config.isEnabled {
            button
        }
    }

    private var button: some View {
        Button(action: { JarvisPanelController.shared.toggle(mainVM: mainVM) }) {
            Image(systemName: "atom")
                .font(.system(.body, weight: .semibold))
                .foregroundColor(isHovered ? JarvisPalette.hologram : theme.secondaryText.opacity(0.85))
                .frame(width: 28, height: 28)
                .background(
                    Circle()
                        .fill(isHovered ? JarvisPalette.hologram.opacity(0.20) : theme.surfaceOverlay)
                )
                .overlay(
                    Circle()
                        .stroke(isHovered ? JarvisPalette.hologram.opacity(0.5) : Color.clear, lineWidth: 1)
                )
                .shadow(color: isHovered ? JarvisPalette.hologram.opacity(0.5) : .clear, radius: 5)
                .scaleEffect(isHovered ? 1.06 : 1.0)
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            withAnimation(.spring(response: 0.25, dampingFraction: 0.7)) { isHovered = hovering }
        }
        .help("Jarvis (experimental)")
        .accessibilityLabel("Toggle Jarvis voice assistant")
    }
}
