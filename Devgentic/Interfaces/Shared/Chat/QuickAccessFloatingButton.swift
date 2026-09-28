// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
//
//  QuickAccessFloatingButton.swift
//  Devgentic
//
//  The floating utility pill that wraps the Quick Access handoff button (to move
//  the active chat conversation into the floating QuickAccess overlay panel) and
//  the Orb voice HUD toggle in a single consolidated capsule.
//
//  Mounted alongside `BackgroundTasksFloatingButton` and `CodeViewerFloatingButton` in
//  `MainApplicationView.floatingPills`.
//

import SwiftUI
import AppKit

struct QuickAccessFloatingButton: View {
    @Environment(MainApplicationViewModel.self) private var mainAppViewModel
    @Environment(\.appTheme) private var theme
    @State private var isQuickAccessHovered = false
    @State private var isOrbHovered = false
    @State private var orbConfig = OrbConfigManager.shared

    private var isAnyHovered: Bool {
        isQuickAccessHovered || isOrbHovered
    }

    /// Pure visibility rule for unit-testability.
    static func shouldShow(
        isChatInterfaceActive: Bool,
        hasSelectedConversation: Bool,
        isQuickAccessEnabled: Bool,
        isCoveredByOverlayPanel: Bool
    ) -> Bool {
        isChatInterfaceActive && hasSelectedConversation && isQuickAccessEnabled && !isCoveredByOverlayPanel
    }

    var body: some View {
        HStack(spacing: 3) {
            quickAccessButton

            if orbConfig.isEnabled {
                Rectangle()
                    .fill(theme.dividerColor.opacity(0.5))
                    .frame(width: 1, height: 14)
                    .padding(.horizontal, 1)

                orbButton
            }
        }
        .padding(.horizontal, 4)
        .padding(.vertical, 3)
        .background(
            Capsule()
                .fill(theme.secondaryBackground)
                .shadow(color: .black.opacity(0.18), radius: isAnyHovered ? 6 : 3, y: 2)
        )
        .overlay(
            Capsule()
                .strokeBorder(
                    isAnyHovered ? theme.accentColor.opacity(0.4) : theme.dividerColor.opacity(0.6),
                    lineWidth: 1
                )
        )
        .scaleEffect(isAnyHovered ? 1.02 : 1.0)
        .animation(.easeInOut(duration: 0.15), value: isAnyHovered)
        .transition(.scale.combined(with: .opacity))
    }

    // MARK: - Quick Access Button

    private var quickAccessButton: some View {
        Button {
            NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .default)
            mainAppViewModel.transferSelectedConversationToOverlay()
        } label: {
            Image(systemName: "bolt.horizontal.circle")
                .font(.system(size: 13, weight: .semibold))
                .foregroundColor(theme.accentColor)
                .frame(width: 24, height: 24)
                .background(isQuickAccessHovered ? theme.surfaceOverlayStrong : Color.clear)
                .clipShape(Circle())
                .scaleEffect(isQuickAccessHovered ? 1.08 : 1.0)
        }
        .buttonStyle(.plain)
        .pointingHandCursor()
        .onHover { hovering in
            withAnimation(.spring(response: 0.25, dampingFraction: 0.7)) {
                isQuickAccessHovered = hovering
            }
        }
        .help(String(localized: "Move chat to Quick Access and resume"))
        .accessibilityLabel(String(localized: "Move this chat to Quick Access"))
    }

    // MARK: - Orb Button

    private var orbButton: some View {
        Button {
            NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .default)
            OrbPanelController.shared.toggle(mainVM: mainAppViewModel)
        } label: {
            OrbIcon(size: 15, isHovered: isOrbHovered)
                .frame(width: 24, height: 24)
                .background(isOrbHovered ? theme.surfaceOverlayStrong : Color.clear)
                .clipShape(Circle())
                .scaleEffect(isOrbHovered ? 1.08 : 1.0)
        }
        .buttonStyle(.plain)
        .pointingHandCursor()
        .onHover { hovering in
            withAnimation(.spring(response: 0.25, dampingFraction: 0.7)) {
                isOrbHovered = hovering
            }
        }
        .help(String(localized: "Orb Voice HUD"))
        .accessibilityLabel(String(localized: "Toggle Orb voice assistant"))
    }
}
