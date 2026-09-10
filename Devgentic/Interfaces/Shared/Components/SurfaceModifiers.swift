// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2026 Raj Singh
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
    var isFocused: Bool = false
    var solidFillOverride: Color? = nil

    @Environment(\.surfaceStyle) private var surfaceStyle
    @Environment(\.appTheme) private var theme

    func body(content: Content) -> some View {
        switch surfaceStyle {
        case .glassmorphic:
            content
                .glassEffect(.regular, in: shape)
                .background(shape.fill(glassFill))
                .overlay(shape.strokeBorder(glassStroke, lineWidth: 1))
                .shadow(color: glassShadowColor, radius: glassShadowRadius, x: 0, y: glassShadowY)

        case .solid:
            content
                .background(shape.fill(solidFill))
                .overlay(shape.strokeBorder(solidStroke, lineWidth: 1))
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
            return theme.secondaryBackground.opacity(0.45)
        case .popover:
            return theme.secondaryBackground.opacity(0.8)
        }
    }

    private var glassStroke: some ShapeStyle {
        if isFocused {
            return AnyShapeStyle(
                LinearGradient(
                    colors: [theme.accentColor.opacity(0.4), theme.accentColor.opacity(0.15)],
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
        return AnyShapeStyle(
            LinearGradient(
                colors: [Color.white.opacity(0.12), Color.white.opacity(0.03)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        )
    }

    private var glassShadowColor: Color {
        if isFocused {
            return theme.accentColor.opacity(0.12)
        }
        return Color.black.opacity(0.16)
    }

    private var glassShadowRadius: CGFloat {
        switch elevation {
        case .canvas: return 0
        case .container: return 12
        case .card: return 6
        case .elevated: return isFocused ? 10 : 6
        case .popover: return 10
        }
    }

    private var glassShadowY: CGFloat {
        switch elevation {
        case .canvas: return 0
        case .container: return 4
        case .card: return 2
        case .elevated: return 3
        case .popover: return 4
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
            return theme.isDark ? Color(hex: "#222225") : (theme.colorScheme == .light ? Color.white : theme.primaryBackground)
        case .popover:
            return theme.isDark ? Color(hex: "#26262A") : (theme.colorScheme == .light ? Color.white : theme.secondaryBackground)
        }
    }

    private var solidStroke: some ShapeStyle {
        if isFocused {
            return AnyShapeStyle(theme.accentColor.opacity(0.70))
        }
        if let strokeColor {
            return AnyShapeStyle(strokeColor)
        }
        // Razor-sharp 1px hairline border with intentional contrast
        return AnyShapeStyle(theme.isDark ? Color.white.opacity(0.09) : Color.black.opacity(0.08))
    }

    private var solidShadowColor: Color {
        if isFocused {
            return theme.accentColor.opacity(0.12)
        }
        switch elevation {
        case .elevated:
            return Color.black.opacity(theme.isDark ? 0.35 : 0.08)
        case .popover:
            return Color.black.opacity(theme.isDark ? 0.40 : 0.12)
        case .card:
            return Color.black.opacity(theme.isDark ? 0.20 : 0.04)
        default:
            return Color.clear
        }
    }

    private var solidShadowRadius: CGFloat {
        switch elevation {
        case .canvas, .container: return 0
        case .card: return 4
        case .elevated: return isFocused ? 10 : 8
        case .popover: return 10
        }
    }

    private var solidShadowY: CGFloat {
        switch elevation {
        case .canvas, .container: return 0
        case .card: return 2
        case .elevated: return 3
        case .popover: return 4
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
        isFocused: Bool = false,
        solidFillOverride: Color? = nil
    ) -> some View {
        self.modifier(
            AppSurfaceModifier(
                shape: shape,
                elevation: elevation,
                strokeColor: strokeColor,
                isFocused: isFocused,
                solidFillOverride: solidFillOverride
            )
        )
    }
}
