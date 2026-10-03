// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
//
//  OnboardingComponents.swift
//  Devgentic
//
//  Created by Raj Singh on 17/09/26.
//

import SwiftUI

// MARK: - Secondary Button (Back, Cancel, etc.) with Hover Effect
struct OnboardingSecondaryButton: View {
    let title: String
    let icon: String?
    let action: () -> Void

    @Environment(\.appTheme) private var theme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isHovered: Bool = false

    init(_ title: String, icon: String? = nil, action: @escaping () -> Void) {
        self.title = title
        self.icon = icon
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                if let icon = icon {
                    Image(systemName: icon)
                        .font(.system(size: 11, weight: .semibold))
                }
                Text(title)
                    .font(theme.fontBody)
            }
            .foregroundColor(isHovered ? theme.primaryText : theme.secondaryText)
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(isHovered ? theme.surfaceOverlayStrong : theme.surfaceOverlay.opacity(0.5))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(isHovered ? theme.secondaryText.opacity(0.30) : theme.dividerColor.opacity(0.6), lineWidth: 1)
            )
            .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            .scaleEffect(isHovered && !reduceMotion ? 1.02 : 1.0)
        }
        .buttonStyle(.plain)
        .pointingHandCursor()
        .onHover { hovering in
            withAnimation(.easeInOut(duration: 0.15)) {
                isHovered = hovering
            }
        }
    }
}

// MARK: - Primary Action Button with Hover Lift and Arrow Nudge
struct OnboardingPrimaryButton: View {
    let title: String
    let icon: String
    let isEnabled: Bool
    let action: () -> Void

    @Environment(\.appTheme) private var theme
    @Environment(\.buttonAccentStyle) private var buttonAccentStyle
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isHovered: Bool = false

    init(_ title: String, icon: String = "arrow.right", isEnabled: Bool = true, action: @escaping () -> Void) {
        self.title = title
        self.icon = icon
        self.isEnabled = isEnabled
        self.action = action
    }

    private var isPrimaryContrast: Bool {
        buttonAccentStyle == .themeContrast
    }

    private var backgroundColor: Color {
        guard isEnabled else {
            if isPrimaryContrast {
                return theme.isDark ? Color.white.opacity(0.12) : Color.black.opacity(0.10)
            }
            return theme.surfaceOverlay.opacity(0.4)
        }

        if isPrimaryContrast {
            // Style 2: Solid contrast keycap
            return theme.isDark
                ? (isHovered ? Color.white : Color.white.opacity(0.95))
                : (isHovered ? Color.black : Color(red: 0.12, green: 0.12, blue: 0.14))
        }

        // Style 3: Tactile Glass Surface
        return isHovered ? theme.surfaceOverlayStrong : theme.surfaceOverlay
    }

    private var labelColor: Color {
        guard isEnabled else {
            if isPrimaryContrast {
                return theme.isDark ? Color.white.opacity(0.35) : Color.black.opacity(0.35)
            }
            return theme.secondaryText.opacity(0.45)
        }

        if isPrimaryContrast {
            // Dark mode: Dark text on white keycap; Light mode: White text on dark keycap
            return theme.isDark ? Color(red: 0.08, green: 0.08, blue: 0.08) : .white
        }

        // Style 3: Clean primary white text
        return isHovered ? theme.primaryText : theme.primaryText.opacity(0.95)
    }

    private var iconColor: Color {
        guard isEnabled else {
            return labelColor
        }

        if isPrimaryContrast {
            return labelColor
        }

        // Style 3: Vibrant accent color icon
        return theme.accentColor
    }

    private var strokeColor: Color {
        guard isEnabled else {
            return theme.dividerColor.opacity(0.3)
        }

        if isPrimaryContrast {
            return theme.isDark ? Color.white.opacity(0.4) : Color.black.opacity(0.2)
        }

        // Style 3: Subtle border glowing with accent tint on hover
        return isHovered ? theme.accentColor.opacity(0.55) : theme.secondaryText.opacity(0.20)
    }

    private var shadowColor: Color {
        guard isEnabled else { return .clear }

        if isPrimaryContrast {
            return Color.black.opacity(isHovered ? 0.35 : 0.20)
        }

        // Style 3: Ambient accent glow on hover
        return theme.accentColor.opacity(isHovered ? 0.35 : 0.08)
    }

    var body: some View {
        Button(action: {
            guard isEnabled else { return }
            action()
        }) {
            HStack(spacing: 8) {
                Text(title)
                    .font(theme.fontBody.weight(.semibold))
                    .foregroundColor(labelColor)
                Image(systemName: icon)
                    .font(.system(size: 12, weight: .bold))
                    .foregroundColor(iconColor)
                    .offset(x: isHovered && isEnabled && !reduceMotion ? 2 : 0)
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 12)
            .background(backgroundColor)
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(strokeColor, lineWidth: 1)
            )
            .shadow(
                color: shadowColor,
                radius: isHovered ? 10 : 4,
                x: 0,
                y: isHovered ? 3 : 1
            )
            .scaleEffect(isEnabled && isHovered && !reduceMotion ? 1.02 : 1.0)
            .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
        .buttonStyle(.plain)
        .pointingHandCursor(enabled: isEnabled)
        .disabled(!isEnabled)
        .onHover { hovering in
            withAnimation(.spring(response: 0.25, dampingFraction: 0.7)) {
                isHovered = hovering
            }
        }
    }
}
