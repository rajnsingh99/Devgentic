// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
//
//  SurfaceModifiers.swift
//  Devgentic
//
//  Created by Raj Singh.
//

import SwiftUI

/// Logical surface elevation layer that determines fill opacity, contrast, and depth.
enum SurfaceElevation {
    /// Canvas background surface (deepest layer).
    case canvas
    /// Sidebar, activity bar, and structural panels.
    case container
    /// Cards, list items, suggestion cells, and action tiles.
    case card
    /// Floating composer, toolbars, HUDs, and island bars.
    case elevated
    /// Small contextual popovers, menus, and overlays.
    case popover
}

/// Applies either Apple Liquid Glass (.glassmorphic) or Pro Solid Matte (.solid)
/// based on the active `SurfaceStyle` in the environment.
struct AppSurfaceModifier<S: InsettableShape>: ViewModifier {
    let shape: S
    let elevation: SurfaceElevation
    var strokeColor: Color? = nil
    var strokeWidth: CGFloat? = nil
    var isFocused: Bool = false
    var solidFillOverride: Color? = nil

    @Environment(\.surfaceStyle) private var surfaceStyle
    @Environment(\.appTheme) private var theme

    private var effectiveStrokeWidth: CGFloat {
        if let strokeWidth {
            return strokeWidth
        }
        // In dark mode, 1pt borders have high visual contrast against dark surfaces and can bleed or appear heavy.
        // A crisp hairline (0.5pt on Retina, matching 1 physical pixel) provides a refined, non-bleeding edge.
        return theme.isDark ? 0.5 : 1.0
    }

    func body(content: Content) -> some View {
        switch surfaceStyle {
        case .glassmorphic:
            content
                .glassEffect(.regular, in: shape)
                .background(shape.fill(glassFill))
                .overlay(shape.strokeBorder(glassStroke, lineWidth: effectiveStrokeWidth))
                .shadow(color: glassShadowColor, radius: glassShadowRadius, x: 0, y: glassShadowY)

        case .solid:
            content
                .background(shape.fill(solidFill))
                .overlay(shape.strokeBorder(solidStroke, lineWidth: effectiveStrokeWidth))
                .shadow(color: solidShadowColor, radius: solidShadowRadius, x: 0, y: solidShadowY)
        }
    }

    // MARK: - Glassmorphic Tokens

    private var glassFill: Color {
        switch elevation {
        case .canvas:
            return theme.primaryBackground
        case .container:
            return theme.secondaryBackground.opacity(0.85)
        case .card:
            return theme.surfaceOverlay
        case .elevated:
            return theme.isDark ? Color.white.opacity(0.04) : theme.secondaryBackground.opacity(0.85)
        case .popover:
            return theme.secondaryBackground.opacity(0.85)
        }
    }

    private var glassStroke: some ShapeStyle {
        if isFocused {
            return AnyShapeStyle(
                LinearGradient(
                    colors: [
                        theme.accentColor.opacity(theme.isDark ? 0.45 : 0.65),
                        theme.accentColor.opacity(theme.isDark ? 0.12 : 0.20)
                    ],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
            )
        }
        if let strokeColor {
            return AnyShapeStyle(
                LinearGradient(
                    colors: [strokeColor, strokeColor.opacity(0.5)],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
            )
        }
        switch elevation {
        case .elevated:
            // Specular Liquid Glass rim with accent catch-light reflection
            return AnyShapeStyle(
                LinearGradient(
                    colors: [
                        theme.isDark ? Color.white.opacity(0.16) : theme.dividerColor.opacity(0.65),
                        theme.dividerColor.opacity(0.40),
                        theme.accentColor.opacity(theme.isDark ? 0.12 : 0.22)
                    ],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
            )
        case .container:
            return AnyShapeStyle(
                LinearGradient(
                    colors: [
                        theme.isDark ? Color.white.opacity(0.18) : theme.dividerColor,
                        theme.dividerColor.opacity(0.5),
                        theme.accentColor.opacity(0.20)
                    ],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
            )
        default:
            return AnyShapeStyle(
                LinearGradient(
                    colors: [Color.white.opacity(0.14), Color.white.opacity(0.04)],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
            )
        }
    }

    private var glassShadowColor: Color {
        if isFocused {
            return theme.accentColor.opacity(theme.isDark ? 0.08 : 0.22)
        }
        switch elevation {
        case .elevated:
            return Color.black.opacity(theme.isDark ? 0.38 : 0.14)
        case .container:
            return theme.shadowColor.opacity(0.6)
        case .popover:
            return Color.black.opacity(0.25)
        default:
            return Color.black.opacity(0.16)
        }
    }

    private var glassShadowRadius: CGFloat {
        switch elevation {
        case .canvas: return 0
        case .container: return 16
        case .card: return 6
        case .elevated: return isFocused ? (theme.isDark ? 8 : 22) : 18
        case .popover: return 12
        }
    }

    private var glassShadowY: CGFloat {
        switch elevation {
        case .canvas: return 0
        case .container: return 6
        case .card: return 2
        case .elevated: return 8
        case .popover: return 5
        }
    }

    // MARK: - Solid Matte Tokens

    private var solidFill: Color {
        if let solidFillOverride {
            return solidFillOverride
        }
        switch elevation {
        case .canvas:
            return theme.primaryBackground
        case .container:
            return theme.secondaryBackground
        case .card:
            return theme.isDark ? Color(hex: "#1E1E22") : theme.secondaryBackground
        case .elevated:
            // Match the solid grounding of container panels (sidebar) across dark and light themes
            return theme.secondaryBackground
        case .popover:
            return theme.isDark ? Color(hex: "#242428") : theme.secondaryBackground
        }
    }

    private var solidStroke: some ShapeStyle {
        if isFocused {
            return AnyShapeStyle(theme.accentColor.opacity(theme.isDark ? 0.45 : 0.70))
        }
        if let strokeColor {
            return AnyShapeStyle(strokeColor)
        }
        switch elevation {
        case .elevated:
            // Crisp, razor-sharp border matching the solid sidebar
            return AnyShapeStyle(theme.isDark ? Color.white.opacity(0.10) : theme.dividerColor.opacity(0.8))
        case .card, .container, .popover:
            return AnyShapeStyle(theme.isDark ? Color.white.opacity(0.10) : theme.dividerColor.opacity(0.6))
        default:
            return AnyShapeStyle(theme.isDark ? Color.white.opacity(0.08) : Color.black.opacity(0.08))
        }
    }

    private var solidShadowColor: Color {
        if isFocused {
            return theme.accentColor.opacity(theme.isDark ? 0.05 : 0.15)
        }
        switch elevation {
        case .elevated:
            return Color.black.opacity(theme.isDark ? 0.28 : 0.08)
        case .popover:
            return Color.black.opacity(theme.isDark ? 0.30 : 0.10)
        case .card:
            return Color.black.opacity(theme.isDark ? 0.15 : 0.04)
        default:
            return Color.clear
        }
    }

    private var solidShadowRadius: CGFloat {
        switch elevation {
        case .canvas, .container: return 0
        case .card: return 3
        case .elevated: return isFocused ? (theme.isDark ? 4 : 8) : 4
        case .popover: return 6
        }
    }

    private var solidShadowY: CGFloat {
        switch elevation {
        case .canvas, .container: return 0
        case .card: return 1
        case .elevated: return 2
        case .popover: return 3
        }
    }
}

// MARK: - View Extension

extension View {
    /// Applies either Apple Liquid Glass or Pro Solid Matte treatment depending on the active `surfaceStyle`.
    func appSurface<S: InsettableShape>(
        in shape: S,
        elevation: SurfaceElevation = .card,
        strokeColor: Color? = nil,
        strokeWidth: CGFloat? = nil,
        isFocused: Bool = false,
        solidFillOverride: Color? = nil
    ) -> some View {
        self.modifier(
            AppSurfaceModifier(
                shape: shape,
                elevation: elevation,
                strokeColor: strokeColor,
                strokeWidth: strokeWidth,
                isFocused: isFocused,
                solidFillOverride: solidFillOverride
            )
        )
    }

    /// Applies a unified control surface style (pills, buttons, chips) matching the current `surfaceStyle`.
    func composerControlSurface<S: InsettableShape>(
        in shape: S,
        isHovered: Bool,
        isSelected: Bool = false,
        selectedTint: Color? = nil
    ) -> some View {
        self.modifier(
            ComposerControlSurfaceModifier(
                shape: shape,
                isHovered: isHovered,
                isSelected: isSelected,
                selectedTint: selectedTint
            )
        )
    }
}

// MARK: - Composer Control Surface Modifier

/// Applies surface treatment for composer buttons, pills, and chips according to `surfaceStyle`.
/// In `.glassmorphic`, uses subtle translucent glass overlays.
/// In `.solid`, uses crisp, opaque solid fills with hairline borders.
struct ComposerControlSurfaceModifier<S: InsettableShape>: ViewModifier {
    let shape: S
    var isHovered: Bool
    var isSelected: Bool = false
    var selectedTint: Color? = nil

    @Environment(\.surfaceStyle) private var surfaceStyle
    @Environment(\.appTheme) private var theme

    func body(content: Content) -> some View {
        content
            .background(shape.fill(fillColor))
            .overlay(shape.strokeBorder(strokeColor, lineWidth: 0.75))
    }

    private var fillColor: Color {
        if isSelected, let selectedTint {
            return selectedTint.opacity(isHovered ? 0.24 : 0.14)
        }
        switch surfaceStyle {
        case .glassmorphic:
            return isHovered ? theme.surfaceOverlayStrong : theme.surfaceOverlay
        case .solid:
            if theme.isDark {
                return isHovered ? Color(hex: "#34343A") : Color(hex: "#26262B")
            } else {
                return isHovered ? theme.tertiaryBackground.opacity(0.75) : theme.tertiaryBackground
            }
        }
    }

    private var strokeColor: Color {
        if isSelected, let selectedTint {
            return selectedTint.opacity(isHovered ? 0.65 : 0.40)
        }
        switch surfaceStyle {
        case .glassmorphic:
            return isHovered ? theme.dividerColor.opacity(0.65) : theme.dividerColor.opacity(0.35)
        case .solid:
            if theme.isDark {
                return isHovered ? Color.white.opacity(0.20) : Color.white.opacity(0.11)
            } else {
                return isHovered ? theme.dividerColor.opacity(0.60) : theme.dividerColor.opacity(0.35)
            }
        }
    }
}
