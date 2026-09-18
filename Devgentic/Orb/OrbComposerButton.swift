// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
//
//  OrbComposerButton.swift
//  Devgentic
//
//  [Orb MVP] The composer entry point — sits next to the voice button in the main
//  chat input bar and toggles the floating Orb panel.
//  Follows the exact toolbar button discipline (28×28, surfaceOverlay at rest, surfaceOverlayStrong on hover,
//  subtle secondaryText stroke matching the voice button, zero blue border).
//

import SwiftUI
import AppKit

struct OrbComposerButton: View {
    @Environment(MainApplicationViewModel.self) private var mainVM
    @Environment(\.appTheme) private var theme
    @State private var isHovered = false
    /// Self-gating on the enable flag keeps the composer's own layout code free of Orb
    /// conditionals — the button simply isn't there when the feature is off.
    @State private var config = OrbConfigManager.shared

    var body: some View {
        if config.isEnabled {
            button
        }
    }

    private var button: some View {
        Button(action: {
            NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .default)
            OrbPanelController.shared.toggle(mainVM: mainVM)
        }) {
            OrbIcon(size: 18, isHovered: isHovered)
                .frame(width: 28, height: 28)
                .background(
                    Circle()
                        .fill(isHovered ? theme.surfaceOverlayStrong : theme.surfaceOverlay)
                )
                .overlay(
                    Circle()
                        .stroke(isHovered ? theme.secondaryText.opacity(0.3) : Color.clear, lineWidth: 1)
                )
                .shadow(color: isHovered ? Color.black.opacity(0.2) : .clear, radius: 4, x: 0, y: 1)
                .scaleEffect(isHovered ? 1.06 : 1.0)
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            withAnimation(.spring(response: 0.25, dampingFraction: 0.7)) { isHovered = hovering }
        }
        .help("Orb Voice HUD")
        .accessibilityLabel("Toggle Orb voice assistant")
    }
}
