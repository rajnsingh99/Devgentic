// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2026 Raj Singh
//
//  ThemeEnvironmentKey.swift
//  Devgentic
//
//  Created by Raj Singh.
//
//  Provides a custom SwiftUI EnvironmentKey so any view can read
//  the current theme via `@Environment(\.appTheme)`.
//

import SwiftUI

// MARK: - Environment Key

private struct AppThemeKey: EnvironmentKey {
    static let defaultValue: any Theme = AppThemes.MaterialTheme()
}

private struct AppAccentColorKey: EnvironmentKey {
    static let defaultValue: Color? = nil
}

private struct SurfaceStyleKey: EnvironmentKey {
    static let defaultValue: SurfaceStyle = .glassmorphic
}

extension EnvironmentValues {
    /// The currently active application theme.
    var appTheme: any Theme {
        get { self[AppThemeKey.self] }
        set { self[AppThemeKey.self] = newValue }
    }

    /// The customizable accent color override.
    var appAccentColor: Color? {
        get { self[AppAccentColorKey.self] }
        set { self[AppAccentColorKey.self] = newValue }
    }

    /// The current surface presentation style (Liquid Glass vs. Solid Matte).
    var surfaceStyle: SurfaceStyle {
        get { self[SurfaceStyleKey.self] }
        set { self[SurfaceStyleKey.self] = newValue }
    }
}

// MARK: - Convenience View Modifier

extension View {
    /// Injects a theme into the environment for this view and its descendants.
    func appTheme(_ theme: any Theme) -> some View {
        environment(\.appTheme, theme)
    }

    /// Injects an accent color override into the environment.
    func appAccentColor(_ color: Color?) -> some View {
        environment(\.appAccentColor, color)
    }

    /// Injects a surface style into the environment for this view and its descendants.
    func appSurfaceStyle(_ style: SurfaceStyle) -> some View {
        environment(\.surfaceStyle, style)
    }
}
