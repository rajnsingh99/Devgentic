// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2026 Raj Singh
//
//  ThemeManager.swift
//  Devgentic
//
//  Created by Raj Singh on 25/07/25.
//

import SwiftUI

// MARK: - Code Viewer Theme Override

/// Defines the theme override options for the Code Viewer panel.
/// When set to `.default`, the code viewer follows the global app theme.
/// Selecting a specific theme overrides the global theme for the code viewer only.
enum CodeViewerThemeOverride: String, CaseIterable {
    case `default` = "default"
    case material = "material"
    case cosmicDark = "cosmic_dark"
    case oneLight = "one_light"
    case solarizedLight = "solarized_light"

    init?(rawValue: String) {
        switch rawValue {
        case "default": self = .default
        case "material", "dracula", "one_dark": self = .material // Backward-compatible migration
        case "cosmic_dark": self = .cosmicDark
        case "one_light", "github_light": self = .oneLight // One Light (renamed GitHub Light)
        case "solarized_light": self = .solarizedLight
        default: return nil
        }
    }

    var displayName: String {
        switch self {
        case .default: return "Default (Follow App Theme)"
        case .material: return "Material Darker"
        case .cosmicDark: return "Cosmic Dark"
        case .oneLight: return "One Light"
        case .solarizedLight: return "Solarized Light"
        }
    }
}

// MARK: - Surface Presentation Style

/// Controls whether the application renders using Apple Liquid Glass (translucent materials,
/// ambient auras, specular highlights) or Solid Matte (deep opaque surfaces, razor-sharp 1px
/// hairlines, zero blur).
enum SurfaceStyle: String, CaseIterable, Identifiable {
    case glassmorphic = "glassmorphic"
    case solid = "solid"

    var id: String { rawValue }

    var displayName: LocalizedStringKey {
        switch self {
        case .glassmorphic: return "Glassmorphic (Liquid Glass)"
        case .solid: return "Solid Matte (Pro Minimal)"
        }
    }

    var subtitle: LocalizedStringKey {
        switch self {
        case .glassmorphic: return "Translucent acrylic materials, ambient colored auras, and specular highlights."
        case .solid: return "Deep opaque surfaces, razor-sharp 1px hairline borders, and zero background glare."
        }
    }

    var icon: String {
        switch self {
        case .glassmorphic: return "sparkles"
        case .solid: return "square.fill"
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
@Observable final class ThemeManager {

    /// The key used to store the selected theme's ID in UserDefaults.
    private static let selectedThemeKey = "selectedThemeID"
    private static let codeViewerThemeKey = "codeViewerThemeOverride"
    private static let accentColorKey = "selectedAccentColor"
    private static let surfaceStyleKey = "selectedSurfaceStyle"

    /// The array of all themes available in the application.
    let availableThemes: [any Theme] = [
        AppThemes.MaterialTheme(),
        AppThemes.CosmicDarkTheme(),
        AppThemes.OneLightTheme(),
        AppThemes.SolarizedLightTheme()
    ]

    /// The currently active theme. Published to allow SwiftUI views to automatically
    /// update when the theme changes.
    private(set) var currentTheme: any Theme

    /// The base theme without dynamic decorators/overrides.
    public private(set) var baseTheme: any Theme

    /// The Code Viewer theme override. When `.default`, follows the global app theme.
    private(set) var codeViewerThemeOverride: CodeViewerThemeOverride

    /// The customizable accent color override.
    private(set) var selectedAccentColor: AppAccentColor

    /// The surface presentation style (Liquid Glass vs. Solid Matte).
    private(set) var surfaceStyle: SurfaceStyle

    // MARK: - Chat Font Customization
    /// The font size for chat message body text. Default: 15pt (matches fontBody).
    var chatFontSize: CGFloat
    /// The line spacing for chat message text. Default: 4pt.
    var chatLineSpacing: CGFloat

    /// A computed `Font` built from the user's chat font size preference.
    var chatFont: Font {
        .system(size: chatFontSize, weight: .regular)
    }

    init() {
        // Load the saved app theme (migrating legacy "dracula", "one_dark", "default", or "github_light").
        let rawSavedThemeID = UserDefaults.standard.string(forKey: Self.selectedThemeKey)
        let savedThemeID: String
        if rawSavedThemeID == "dracula" || rawSavedThemeID == "one_dark" || rawSavedThemeID == "default" || rawSavedThemeID == nil {
            savedThemeID = "material"
            if rawSavedThemeID != nil {
                UserDefaults.standard.set("material", forKey: Self.selectedThemeKey)
            }
        } else if rawSavedThemeID == "github_light" {
            savedThemeID = "one_light"
            UserDefaults.standard.set("one_light", forKey: Self.selectedThemeKey)
        } else {
            savedThemeID = rawSavedThemeID ?? "material"
        }

        let allThemes: [any Theme] = [
            AppThemes.MaterialTheme(),
            AppThemes.CosmicDarkTheme(),
            AppThemes.OneLightTheme(),
            AppThemes.SolarizedLightTheme()
        ]
        let base = allThemes.first { $0.id == savedThemeID } ?? allThemes[0]
        self.baseTheme = base

        // Load the saved code viewer override.
        let savedOverride = UserDefaults.standard.string(forKey: Self.codeViewerThemeKey)
        let codeOverride = savedOverride.flatMap { CodeViewerThemeOverride(rawValue: $0) } ?? .default
        self.codeViewerThemeOverride = codeOverride

        // Load the saved accent color.
        let savedAccent = UserDefaults.standard.string(forKey: Self.accentColorKey)
        let accent = savedAccent.flatMap { AppAccentColor(rawValue: $0) } ?? .default
        self.selectedAccentColor = accent

        // Load the saved surface style (default: glassmorphic).
        let savedSurface = UserDefaults.standard.string(forKey: Self.surfaceStyleKey)
        self.surfaceStyle = savedSurface.flatMap { SurfaceStyle(rawValue: $0) } ?? .glassmorphic

        // Load chat font settings (default: 15pt body, 4pt line spacing)
        let savedFontSize = UserDefaults.standard.object(forKey: AppSettings.chatFontSizeKey) as? CGFloat
        self.chatFontSize = savedFontSize ?? 15
        let savedLineSpacing = UserDefaults.standard.object(forKey: AppSettings.chatLineSpacingKey) as? CGFloat
        self.chatLineSpacing = savedLineSpacing ?? 4

        // Initialize currentTheme with decorator
        self.currentTheme = ThemeDecorator(base: base, accentColorOverride: accent, codeThemeOverride: codeOverride)

        // Sync initial window chrome appearance
        Self.syncWindowAppearance(colorScheme: base.colorScheme)
    }

    /// Synchronizes native NSWindow appearance with the active color scheme.
    static func syncWindowAppearance(colorScheme: ColorScheme?) {
        #if canImport(AppKit) && !targetEnvironment(macCatalyst)
        DispatchQueue.main.async {
            let appearance: NSAppearance? = colorScheme.map {
                NSAppearance(named: $0 == .dark ? .darkAqua : .aqua)
            } ?? nil
            for window in NSApp.windows {
                window.appearance = appearance
            }
        }
        #endif
    }

    /// Applies a new theme to the application.
    func applyTheme(_ theme: any Theme) {
        self.baseTheme = theme
        self.currentTheme = ThemeDecorator(base: theme, accentColorOverride: selectedAccentColor, codeThemeOverride: codeViewerThemeOverride)
        UserDefaults.standard.set(theme.id, forKey: Self.selectedThemeKey)
        Self.syncWindowAppearance(colorScheme: theme.colorScheme)
    }

    /// Applies a Code Viewer theme override.
    func applyCodeViewerTheme(_ override: CodeViewerThemeOverride) {
        self.codeViewerThemeOverride = override
        self.currentTheme = ThemeDecorator(base: baseTheme, accentColorOverride: selectedAccentColor, codeThemeOverride: override)
        UserDefaults.standard.set(override.rawValue, forKey: Self.codeViewerThemeKey)
    }

    /// Applies a new accent color override.
    func applyAccentColor(_ accent: AppAccentColor) {
        self.selectedAccentColor = accent
        self.currentTheme = ThemeDecorator(base: baseTheme, accentColorOverride: accent, codeThemeOverride: codeViewerThemeOverride)
        UserDefaults.standard.set(accent.rawValue, forKey: Self.accentColorKey)
    }

    /// Applies a new surface presentation style (Liquid Glass vs. Solid Matte).
    func applySurfaceStyle(_ style: SurfaceStyle) {
        self.surfaceStyle = style
        UserDefaults.standard.set(style.rawValue, forKey: Self.surfaceStyleKey)
    }

    // MARK: - Chat Font Actions

    func applyChatFontSize(_ size: CGFloat) {
        self.chatFontSize = size
        UserDefaults.standard.set(size, forKey: AppSettings.chatFontSizeKey)
    }

    func applyChatLineSpacing(_ spacing: CGFloat) {
        self.chatLineSpacing = spacing
        UserDefaults.standard.set(spacing, forKey: AppSettings.chatLineSpacingKey)
    }

    /// The resolved syntax theme for the Code Viewer and in-chat code blocks.
    var resolvedCodeViewerSyntaxTheme: SyntaxTheme {
        currentTheme.syntaxTheme
    }
}
