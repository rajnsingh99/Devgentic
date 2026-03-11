//
//  ThemeManager.swift
//  Devgentic
//
//  Created by Raj Singh on 25/07/25.
//

import SwiftUI
import Combine

// MARK: - Code Viewer Theme Override

/// Defines the theme override options for the Code Viewer panel.
/// When set to `.default`, the code viewer follows the global app theme.
/// Selecting a specific theme overrides the global theme for the code viewer only.
enum CodeViewerThemeOverride: String, CaseIterable {
    case `default` = "default"
    case oneLight = "one_light"
    case oneDark = "one_dark"
    case cosmicDark = "cosmic_dark"
    case dracula = "dracula"

    var displayName: String {
        switch self {
        case .default: return "Default (Follow App Theme)"
        case .oneLight: return "One Light"
        case .oneDark: return "One Dark"
        case .cosmicDark: return "Cosmic Dark"
        case .dracula: return "Dracula"
        }
    }
}

// MARK: - Theme Manager

/// A class that manages the application's themes.
///
/// This `ObservableObject` is responsible for:
/// - Holding the list of all available themes.
/// - Keeping track of the currently active theme.
/// - Persisting the user's theme choice to `UserDefaults`.
/// - Applying a new theme and ensuring the UI updates reactively.
/// - Managing the per-component Code Viewer theme override.
final class ThemeManager: ObservableObject {

    /// The key used to store the selected theme's ID in UserDefaults.
    private static let selectedThemeKey = "selectedThemeID"
    private static let codeViewerThemeKey = "codeViewerThemeOverride"
    private static let accentColorKey = "selectedAccentColor"

    /// The array of all themes available in the application.
    let availableThemes: [any Theme] = [
        AppThemes.DefaultTheme(),
        AppThemes.DraculaTheme(),
        AppThemes.OneLightTheme(),
        AppThemes.OneDarkTheme(),
        AppThemes.CosmicDarkTheme()
    ]

    /// The currently active theme. Published to allow SwiftUI views to automatically
    /// update when the theme changes.
    @Published private(set) var currentTheme: any Theme

    private var baseTheme: any Theme

    /// The Code Viewer theme override. When `.default`, follows the global app theme.
    @Published private(set) var codeViewerThemeOverride: CodeViewerThemeOverride

    /// The customizable accent color override.
    @Published private(set) var selectedAccentColor: AppAccentColor

    init() {
        // Load the saved app theme.
        let savedThemeID = UserDefaults.standard.string(forKey: Self.selectedThemeKey)
        let allThemes: [any Theme] = [
            AppThemes.DefaultTheme(),
            AppThemes.DraculaTheme(),
            AppThemes.OneLightTheme(),
            AppThemes.OneDarkTheme(),
            AppThemes.CosmicDarkTheme()
        ]
        let base = allThemes.first { $0.id == savedThemeID } ?? allThemes[0]
        self.baseTheme = base

        // Load the saved code viewer override.
        let savedOverride = UserDefaults.standard.string(forKey: Self.codeViewerThemeKey)
        self.codeViewerThemeOverride = savedOverride.flatMap { CodeViewerThemeOverride(rawValue: $0) } ?? .default

        // Load the saved accent color.
        let savedAccent = UserDefaults.standard.string(forKey: Self.accentColorKey)
        let accent = savedAccent.flatMap { AppAccentColor(rawValue: $0) } ?? .default
        self.selectedAccentColor = accent

        // Initialize currentTheme with decorator
        self.currentTheme = ThemeDecorator(base: base, accentColorOverride: accent)
    }

    /// Applies a new theme to the application.
    func applyTheme(_ theme: any Theme) {
        self.baseTheme = theme
        self.currentTheme = ThemeDecorator(base: theme, accentColorOverride: selectedAccentColor)
        UserDefaults.standard.set(theme.id, forKey: Self.selectedThemeKey)
    }

    /// Applies a Code Viewer theme override.
    func applyCodeViewerTheme(_ override: CodeViewerThemeOverride) {
        self.codeViewerThemeOverride = override
        UserDefaults.standard.set(override.rawValue, forKey: Self.codeViewerThemeKey)
    }

    /// Applies a new accent color override.
    func applyAccentColor(_ accent: AppAccentColor) {
        self.selectedAccentColor = accent
        self.currentTheme = ThemeDecorator(base: baseTheme, accentColorOverride: accent)
        UserDefaults.standard.set(accent.rawValue, forKey: Self.accentColorKey)
    }

    /// The resolved syntax theme for the Code Viewer, accounting for the override setting.
    /// If override is `.default`, uses the current app theme's syntax colors.
    /// Otherwise, uses the specified theme's syntax colors regardless of the global theme.
    var resolvedCodeViewerSyntaxTheme: SyntaxTheme {
        switch codeViewerThemeOverride {
        case .default:
            return currentTheme.syntaxTheme
        case .oneLight:
            return AppThemes.OneLightTheme().syntaxTheme.patched(with: selectedAccentColor.nsColor)
        case .oneDark:
            return AppThemes.OneDarkTheme().syntaxTheme.patched(with: selectedAccentColor.nsColor)
        case .cosmicDark:
            return AppThemes.CosmicDarkTheme().syntaxTheme.patched(with: selectedAccentColor.nsColor)
        case .dracula:
            return AppThemes.DraculaTheme().syntaxTheme.patched(with: selectedAccentColor.nsColor)
        }
    }
}
