// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
//
//  SettingsButtonComponents.swift
//  Devgentic
//
//  Unified, premium button components designed for macOS Settings, toolbars, and inspection cards.
//  Replaces bare SwiftUI `.buttonStyle(.bordered)` which renders with near-zero contrast on dark themes.
//

import SwiftUI

// MARK: - Button Variants

enum SettingsButtonVariant {
    /// Solid high-contrast call-to-action (e.g. Save, Create).
    case primary
    /// Neutral tactile glass button with subtle border and hover elevation.
    case secondary
    /// Subtle, low-emphasis action with transparent rest background.
    case subtle
    /// Semantic red destructive action (e.g. Remove, Delete).
    case destructive
}

enum SettingsButtonSize {
    /// Standard compact size for settings rows and inspector cards (height ~26pt).
    case compact
    /// Standard regular size for standalone dialogs and footers (height ~32pt).
    case regular

    var font: Font {
        switch self {
        case .compact: return .system(size: 11.5, weight: .semibold)
        case .regular: return .system(size: 13, weight: .semibold)
        }
    }

    var iconFont: Font {
        switch self {
        case .compact: return .system(size: 11.5, weight: .semibold)
        case .regular: return .system(size: 13, weight: .semibold)
        }
    }

    var horizontalPadding: CGFloat {
        switch self {
        case .compact: return 10
        case .regular: return 14
        }
    }

    var verticalPadding: CGFloat {
        switch self {
        case .compact: return 4.5
        case .regular: return 6.5
        }
    }

    var cornerRadius: CGFloat {
        switch self {
        case .compact: return 6
        case .regular: return 8
        }
    }
}

typealias TactileButtonVariant = SettingsButtonVariant
typealias TactileButtonSize = SettingsButtonSize

// MARK: - TactileButton

/// A refined, tactile button with clear dark-mode boundaries, subtle depth, and smooth spring feedback.
struct TactileButton: View {
    let title: LocalizedStringKey
    var icon: String? = nil
    var variant: SettingsButtonVariant = .secondary
    var size: SettingsButtonSize = .compact
    var isLoading: Bool = false
    var isEnabled: Bool = true
    var tooltip: String? = nil
    let action: () -> Void

    init(
        title: LocalizedStringKey,
        icon: String? = nil,
        variant: SettingsButtonVariant = .secondary,
        size: SettingsButtonSize = .compact,
        isLoading: Bool = false,
        isEnabled: Bool = true,
        isDisabled: Bool? = nil,
        tooltip: String? = nil,
        action: @escaping () -> Void
    ) {
        self.title = title
        self.icon = icon
        self.variant = variant
        self.size = size
        self.isLoading = isLoading
        self.isEnabled = isDisabled != nil ? !isDisabled! : isEnabled
        self.tooltip = tooltip
        self.action = action
    }

    init(
        title: String,
        icon: String? = nil,
        variant: SettingsButtonVariant = .secondary,
        size: SettingsButtonSize = .compact,
        isLoading: Bool = false,
        isEnabled: Bool = true,
        isDisabled: Bool? = nil,
        tooltip: String? = nil,
        action: @escaping () -> Void
    ) {
        self.init(
            title: LocalizedStringKey(title),
            icon: icon,
            variant: variant,
            size: size,
            isLoading: isLoading,
            isEnabled: isEnabled,
            isDisabled: isDisabled,
            tooltip: tooltip,
            action: action
        )
    }

    @State private var isHovered = false
    @Environment(\.appTheme) private var theme
    @Environment(\.buttonAccentStyle) private var buttonAccentStyle
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var isPrimaryContrast: Bool {
        variant == .primary && buttonAccentStyle == .themeContrast
    }

    var body: some View {
        Button(action: {
            guard isEnabled && !isLoading else { return }
            action()
        }) {
            HStack(spacing: 5) {
                if isLoading {
                    ProgressView()
                        .controlSize(.mini)
                        .tint(foregroundColor)
                } else if let icon {
                    Image(systemName: icon)
                        .font(size.iconFont)
                        .foregroundColor(iconColor)
                        .accessibilityHidden(true)
                }

                Text(title)
                    .font(size.font)
                    .foregroundColor(foregroundColor)
                    .lineLimit(1)
            }
            .padding(.horizontal, size.horizontalPadding)
            .padding(.vertical, size.verticalPadding)
            .background(
                RoundedRectangle(cornerRadius: size.cornerRadius, style: .continuous)
                    .fill(backgroundColor)
            )
            .overlay(
                RoundedRectangle(cornerRadius: size.cornerRadius, style: .continuous)
                    .strokeBorder(strokeColor, lineWidth: 1)
            )
            .shadow(
                color: shadowColor,
                radius: isHovered && isEnabled ? 3 : 1,
                x: 0,
                y: 1
            )
            .scaleEffect(isHovered && isEnabled && !reduceMotion ? 1.02 : 1.0)
            .contentShape(RoundedRectangle(cornerRadius: size.cornerRadius, style: .continuous))
        }
        .buttonStyle(.plain)
        .pointingHandCursor(enabled: isEnabled && !isLoading)
        .disabled(!isEnabled || isLoading)
        .onHover { hovering in
            withAnimation(.spring(response: 0.22, dampingFraction: 0.72)) {
                isHovered = hovering
            }
        }
        .modifier(SettingsButtonHelpModifier(help: tooltip))
    }

    private var foregroundColor: Color {
        if !isEnabled {
            // High-contrast clean disabled state: NEVER muddy dark text on translucent dark backgrounds!
            if isPrimaryContrast {
                return theme.isDark ? Color.white.opacity(0.40) : Color.black.opacity(0.40)
            } else if variant == .primary {
                return theme.secondaryText.opacity(0.45)
            } else {
                return theme.secondaryText.opacity(0.45)
            }
        }

        switch variant {
        case .primary:
            if buttonAccentStyle == .themeContrast {
                // Dark theme: White button -> Dark text (STYLE 2)
                // Light theme: Dark button -> White text
                return theme.isDark ? Color(red: 0.08, green: 0.08, blue: 0.08) : .white
            }
            // Glassmorphic mode: Primary text label (STYLE 3)
            return isHovered ? theme.primaryText : theme.primaryText.opacity(0.95)

        case .secondary:
            return isHovered ? theme.primaryText : theme.primaryText.opacity(0.92)

        case .subtle:
            return isHovered
                ? (buttonAccentStyle == .themeContrast ? theme.primaryText : theme.accentColor)
                : theme.secondaryText

        case .destructive:
            return isHovered ? .white : theme.errorColor
        }
    }

    private var iconColor: Color {
        if !isEnabled { return foregroundColor }
        switch variant {
        case .primary:
            if buttonAccentStyle == .accent {
                // Glassmorphic mode: Accent-colored icon (STYLE 3)
                return theme.accentColor
            }
            return foregroundColor
        case .secondary:
            if buttonAccentStyle == .accent && isHovered {
                return theme.accentColor
            }
            return foregroundColor
        case .subtle:
            if buttonAccentStyle == .accent && isHovered {
                return theme.accentColor
            }
            return foregroundColor
        case .destructive:
            return foregroundColor
        }
    }

    private var backgroundColor: Color {
        if !isEnabled {
            if isPrimaryContrast {
                return theme.isDark
                    ? Color.white.opacity(0.08)
                    : Color.black.opacity(0.06)
            } else if variant == .primary {
                return Color.white.opacity(0.04)
            } else {
                return Color.white.opacity(0.04)
            }
        }

        switch variant {
        case .primary:
            if buttonAccentStyle == .themeContrast {
                return theme.isDark
                    ? Color.white.opacity(isHovered ? 1.0 : 0.95)
                    : Color(red: 0.12, green: 0.12, blue: 0.14).opacity(isHovered ? 1.0 : 0.95)
            }
            // Glassmorphic mode: Refined dark surface overlay (STYLE 3)
            return isHovered ? theme.surfaceOverlayStrong : theme.surfaceOverlay

        case .secondary:
            return isHovered ? theme.surfaceOverlayStrong : theme.surfaceOverlay

        case .subtle:
            if buttonAccentStyle == .themeContrast {
                return isHovered ? theme.surfaceOverlayStrong : Color.clear
            }
            return isHovered ? theme.accentColor.opacity(0.12) : Color.clear

        case .destructive:
            return isHovered ? theme.errorColor : theme.errorColor.opacity(0.12)
        }
    }

    private var strokeColor: Color {
        if !isEnabled {
            if isPrimaryContrast {
                return theme.isDark ? Color.white.opacity(0.12) : Color.black.opacity(0.10)
            } else if variant == .primary {
                return theme.dividerColor.opacity(0.20)
            } else {
                return theme.dividerColor.opacity(0.20)
            }
        }

        switch variant {
        case .primary:
            if buttonAccentStyle == .themeContrast {
                return theme.isDark
                    ? Color.white
                    : Color(red: 0.12, green: 0.12, blue: 0.14)
            }
            // Glassmorphic mode: Subtle border with accent hover glow (STYLE 3)
            return isHovered
                ? theme.accentColor.opacity(0.45)
                : theme.secondaryText.opacity(0.18)

        case .secondary:
            if buttonAccentStyle == .themeContrast {
                return isHovered ? theme.primaryText.opacity(0.40) : theme.secondaryText.opacity(0.20)
            }
            return isHovered
                ? theme.accentColor.opacity(0.45)
                : theme.secondaryText.opacity(0.20)

        case .subtle:
            if buttonAccentStyle == .themeContrast {
                return isHovered ? theme.secondaryText.opacity(0.30) : Color.clear
            }
            return isHovered ? theme.accentColor.opacity(0.35) : Color.clear

        case .destructive:
            return isHovered ? theme.errorColor : theme.errorColor.opacity(0.35)
        }
    }

    private var shadowColor: Color {
        guard isEnabled else { return Color.clear }
        switch variant {
        case .primary:
            if buttonAccentStyle == .themeContrast {
                return theme.isDark
                    ? Color.black.opacity(isHovered ? 0.35 : 0.20)
                    : Color.black.opacity(isHovered ? 0.25 : 0.12)
            }
            // Glassmorphic mode: Subtle shadow with accent glow on hover (STYLE 3)
            return isHovered ? theme.accentColor.opacity(0.15) : theme.shadowColor.opacity(0.3)
        case .secondary:
            if buttonAccentStyle == .accent && isHovered {
                return theme.accentColor.opacity(0.18)
            }
            return isHovered ? theme.shadowColor.opacity(0.2) : Color.black.opacity(0.06)
        case .subtle:
            if buttonAccentStyle == .accent && isHovered {
                return theme.accentColor.opacity(0.15)
            }
            return Color.clear
        case .destructive:
            return isHovered ? theme.errorColor.opacity(0.25) : Color.clear
        }
    }
}

// MARK: - TactileIconButton

/// Compact icon-only button (26×26pt) for secondary row actions like Reveal, Reset, Copy, or Delete.
struct TactileIconButton: View {
    let icon: String
    var tooltip: String? = nil
    var accessibilityLabel: String? = nil
    var variant: SettingsButtonVariant = .secondary
    var size: CGFloat = 26
    var isEnabled: Bool = true
    let action: () -> Void

    init(
        icon: String,
        tooltip: String? = nil,
        accessibilityLabel: String? = nil,
        variant: SettingsButtonVariant = .secondary,
        size: CGFloat = 26,
        isEnabled: Bool = true,
        isDisabled: Bool? = nil,
        action: @escaping () -> Void
    ) {
        self.icon = icon
        self.tooltip = tooltip
        self.accessibilityLabel = accessibilityLabel
        self.variant = variant
        self.size = size
        self.isEnabled = isDisabled != nil ? !isDisabled! : isEnabled
        self.action = action
    }

    init(
        icon: String,
        tooltip: String? = nil,
        accessibilityLabel: String? = nil,
        variant: SettingsButtonVariant = .secondary,
        size: SettingsButtonSize,
        isEnabled: Bool = true,
        isDisabled: Bool? = nil,
        action: @escaping () -> Void
    ) {
        self.init(
            icon: icon,
            tooltip: tooltip,
            accessibilityLabel: accessibilityLabel,
            variant: variant,
            size: size == .compact ? 26 : 32,
            isEnabled: isEnabled,
            isDisabled: isDisabled,
            action: action
        )
    }

    @State private var isHovered = false
    @Environment(\.appTheme) private var theme
    @Environment(\.buttonAccentStyle) private var buttonAccentStyle
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var isPrimaryContrast: Bool {
        variant == .primary && buttonAccentStyle == .themeContrast
    }

    var body: some View {
        Button(action: {
            guard isEnabled else { return }
            action()
        }) {
            Image(systemName: icon)
                .font(.system(size: size * 0.44, weight: .semibold))
                .foregroundColor(iconColor)
                .frame(width: size, height: size)
                .background(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(backgroundColor)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .strokeBorder(strokeColor, lineWidth: 1)
                )
                .shadow(
                    color: isHovered && isEnabled ? theme.shadowColor.opacity(0.18) : Color.clear,
                    radius: 2,
                    x: 0,
                    y: 1
                )
                .scaleEffect(isHovered && isEnabled && !reduceMotion ? 1.05 : 1.0)
            .contentShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        }
        .buttonStyle(.plain)
        .pointingHandCursor(enabled: isEnabled)
        .disabled(!isEnabled)
        .onHover { hovering in
            withAnimation(.spring(response: 0.22, dampingFraction: 0.72)) {
                isHovered = hovering
            }
        }
        .modifier(SettingsButtonHelpModifier(help: tooltip))
        .accessibilityLabel(resolvedAccessibilityLabel)
    }

    private var resolvedAccessibilityLabel: Text {
        if let accessibilityLabel { return Text(accessibilityLabel) }
        if let tooltip { return Text(tooltip) }
        return Text(icon)
    }

    private var iconColor: Color {
        if !isEnabled {
            if isPrimaryContrast {
                return theme.isDark ? Color.white.opacity(0.40) : Color.black.opacity(0.40)
            } else if variant == .primary {
                return theme.secondaryText.opacity(0.45)
            } else {
                return theme.secondaryText.opacity(0.45)
            }
        }

        switch variant {
        case .primary:
            if buttonAccentStyle == .themeContrast {
                return theme.isDark ? Color(red: 0.08, green: 0.08, blue: 0.08) : .white
            }
            return theme.accentColor
        case .secondary:
            return isHovered ? (buttonAccentStyle == .themeContrast ? theme.primaryText : theme.accentColor) : theme.secondaryText
        case .subtle:
            return isHovered ? (buttonAccentStyle == .themeContrast ? theme.primaryText : theme.accentColor) : theme.secondaryText
        case .destructive:
            return isHovered ? .white : theme.errorColor
        }
    }

    private var backgroundColor: Color {
        if !isEnabled {
            if isPrimaryContrast {
                return theme.isDark
                    ? Color.white.opacity(0.08)
                    : Color.black.opacity(0.06)
            } else if variant == .primary {
                return Color.white.opacity(0.04)
            } else {
                return Color.white.opacity(0.04)
            }
        }

        switch variant {
        case .primary:
            if buttonAccentStyle == .themeContrast {
                return theme.isDark
                    ? Color.white.opacity(isHovered ? 1.0 : 0.95)
                    : Color(red: 0.12, green: 0.12, blue: 0.14).opacity(isHovered ? 1.0 : 0.95)
            }
            return isHovered ? theme.surfaceOverlayStrong : theme.surfaceOverlay
        case .secondary:
            return isHovered ? theme.surfaceOverlayStrong : theme.surfaceOverlay
        case .subtle:
            if buttonAccentStyle == .themeContrast {
                return isHovered ? theme.surfaceOverlayStrong : Color.clear
            }
            return isHovered ? theme.accentColor.opacity(0.12) : Color.clear
        case .destructive:
            return isHovered ? theme.errorColor : theme.errorColor.opacity(0.12)
        }
    }

    private var strokeColor: Color {
        if !isEnabled {
            if isPrimaryContrast {
                return theme.isDark ? Color.white.opacity(0.12) : Color.black.opacity(0.10)
            } else if variant == .primary {
                return theme.dividerColor.opacity(0.20)
            } else {
                return theme.dividerColor.opacity(0.18)
            }
        }

        switch variant {
        case .primary:
            if buttonAccentStyle == .themeContrast {
                return theme.isDark ? Color.white : Color(red: 0.12, green: 0.12, blue: 0.14)
            }
            return isHovered
                ? theme.accentColor.opacity(0.45)
                : theme.secondaryText.opacity(0.18)
        case .secondary:
            if buttonAccentStyle == .themeContrast {
                return isHovered ? theme.primaryText.opacity(0.35) : theme.secondaryText.opacity(0.18)
            }
            return isHovered
                ? theme.accentColor.opacity(0.4)
                : theme.secondaryText.opacity(0.18)
        case .subtle:
            if buttonAccentStyle == .themeContrast {
                return isHovered ? theme.secondaryText.opacity(0.3) : Color.clear
            }
            return isHovered ? theme.accentColor.opacity(0.3) : Color.clear
        case .destructive:
            return isHovered ? theme.errorColor : theme.errorColor.opacity(0.3)
        }
    }
}

// MARK: - Helper

struct SettingsButtonHelpModifier: ViewModifier {
    let help: String?

    func body(content: Content) -> some View {
        if let help = help {
            content.help(help)
        } else {
            content
        }
    }
}
