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
    static let defaultValue: any Theme = AppThemes.DefaultTheme()
}

extension EnvironmentValues {
    /// The currently active application theme.
    ///
    /// Read this in any view with:
    /// ```
    /// @Environment(\.appTheme) private var theme
    /// ```
    var appTheme: any Theme {
        get { self[AppThemeKey.self] }
        set { self[AppThemeKey.self] = newValue }
    }
}

// MARK: - Convenience View Modifier

extension View {
    /// Injects a theme into the environment for this view and its descendants.
    func appTheme(_ theme: any Theme) -> some View {
        environment(\.appTheme, theme)
    }
}
