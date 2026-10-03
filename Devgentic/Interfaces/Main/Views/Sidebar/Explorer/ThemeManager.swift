// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
//
//  ThemeManager.swift
//  Devgentic
//
//  Created by Raj Singh on 25/07/25.
//

import SwiftUI

// MARK: - Code Viewer Theme Override

/// Defines the theme override options for the Code Viewer panel.
/// Specialized syntax highlighting theme for code blocks and the editor.
enum CodeViewerThemeOverride: String, CaseIterable {
    case cosmicDark = "cosmic_dark"
    case highContrast = "high_contrast"
    case oneLight = "one_light"
    case solarizedLight = "solarized_light"

    var displayName: String {
        switch self {
        case .cosmicDark: return "Cosmic Dark"
        case .highContrast: return "High Contrast"
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
        case .glassmorphic: return "Glassmorphic"
        case .solid: return "Material Surface"
        }
    }

    var subtitle: LocalizedStringKey {
        switch self {
        case .glassmorphic: return "Translucent glass surfaces paired with tactile glass accent buttons."
        case .solid: return "Solid opaque surfaces paired with high-contrast monochrome buttons."
        }
    }

    var icon: String {
        switch self {
        case .glassmorphic: return "sparkles"
        case .solid: return "square.fill"
        }
    }
}

// MARK: - Button Accent Style

/// Controls whether primary buttons and interactive controls adopt the active theme accent color
/// or follow a high-contrast theme-based material palette (white buttons with dark icons on dark theme,
/// dark buttons with white icons on light theme).
enum ButtonAccentStyle: String, CaseIterable, Identifiable {
    case themeContrast = "theme_contrast"
    case accent = "accent"

    var id: String { rawValue }

    init?(rawValue: String) {
        switch rawValue {
        case "theme_contrast", "monochrome": self = .themeContrast
        case "accent": self = .accent
        default: return nil
        }
    }

    var displayName: LocalizedStringKey {
        switch self {
        case .themeContrast: return "Theme Contrast (Material)"
        case .accent: return "Dynamic Accent"
        }
    }

    var subtitle: LocalizedStringKey {
        switch self {
        case .themeContrast: return "Crisp white button on dark theme, solid dark button on light theme with theme-based icons."
        case .accent: return "Primary CTAs adopt your selected accent color with subtle glow."
        }
    }

    var icon: String {
        switch self {
        case .themeContrast: return "circle.lefthalf.filled"
        case .accent: return "paintpalette.fill"
        }
    }
}

// MARK: - Chat Font Family

/// Controls the typography family design used for rendering chat message text.
enum ChatFontFamily: String, CaseIterable, Identifiable {
    case system = "system"
    case monospaced = "monospaced"
    case serif = "serif"
    case rounded = "rounded"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .system: return "System (SF Pro)"
        case .monospaced: return "Monospaced (SF Mono)"
        case .serif: return "Serif (New York)"
        case .rounded: return "Rounded"
        }
    }

    var shortName: String {
        switch self {
        case .system: return "SF Pro"
        case .monospaced: return "SF Mono"
        case .serif: return "New York"
        case .rounded: return "Rounded"
        }
    }

    var categoryName: String {
        switch self {
        case .system: return "System"
        case .monospaced: return "Monospace"
        case .serif: return "Serif"
        case .rounded: return "Geometric"
        }
    }

    var subtitle: String {
        switch self {
        case .system: return "Default Apple UI font, optimized for clarity and balance."
        case .monospaced: return "Fixed-width grid typography, loved by developers for technical reading."
        case .serif: return "Editorial literary aesthetic, crafted for relaxed long-form reading."
        case .rounded: return "Friendly, rounded geometric letterforms with a contemporary touch."
        }
    }

    var icon: String {
        switch self {
        case .system: return "textformat"
        case .monospaced: return "chevron.left.forwardslash.chevron.right"
        case .serif: return "text.book.closed"
        case .rounded: return "character.textbox"
        }
    }

    var design: Font.Design {
        switch self {
        case .system: return .default
        case .monospaced: return .monospaced
        case .serif: return .serif
        case .rounded: return .rounded
        }
    }

    var sampleGlyph: String {
        switch self {
        case .system: return "Ag"
        case .monospaced: return "</>"
        case .serif: return "¶"
        case .rounded: return "Aa"
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
    private static let buttonAccentStyleKey = "selectedButtonAccentStyle"

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

    /// The button accent presentation style (Dynamic Accent vs. Monochrome Pro).
    private(set) var buttonAccentStyle: ButtonAccentStyle

    // MARK: - Chat Font Customization
    /// The font family design for chat message text. Default: .system.
    private(set) var chatFontFamily: ChatFontFamily
    /// The font size for chat message body text. Default: 15pt (matches fontBody).
    var chatFontSize: CGFloat
    /// The line spacing for chat message text. Default: 4pt.
    var chatLineSpacing: CGFloat

    /// A computed `Font` built from the user's chat font family and size preference.
    var chatFont: Font {
        .system(size: chatFontSize, weight: .regular, design: chatFontFamily.design)
    }

    /// Helper to produce variations of chat font matching the chosen family.
    func chatFont(size: CGFloat? = nil, weight: Font.Weight = .regular) -> Font {
        .system(size: size ?? chatFontSize, weight: weight, design: chatFontFamily.design)
    }

    /// ⚠️ COMPUTED and routed through `TestHost.defaults`, not `UserDefaults.standard`.
    /// Under XCTest, writes and reads are redirected to an isolated in-memory test suite so
    /// test runs never overwrite the developer's real machine settings.
    private static var defaults: UserDefaults { TestHost.defaults }
    private var defaults: UserDefaults { Self.defaults }

    init() {
        // Load the saved app theme. An unknown id falls back to the first theme below.
        let savedThemeID = Self.defaults.string(forKey: Self.selectedThemeKey) ?? "material"

        let allThemes: [any Theme] = [
            AppThemes.MaterialTheme(),
            AppThemes.CosmicDarkTheme(),
            AppThemes.OneLightTheme(),
            AppThemes.SolarizedLightTheme()
        ]
        let base = allThemes.first { $0.id == savedThemeID } ?? allThemes[0]
        self.baseTheme = base

        // Load the saved code viewer override.
        let savedOverride = Self.defaults.string(forKey: Self.codeViewerThemeKey)
        let codeOverride = savedOverride.flatMap { CodeViewerThemeOverride(rawValue: $0) } ?? .cosmicDark
        self.codeViewerThemeOverride = codeOverride

        // Load the saved accent color.
        let savedAccent = Self.defaults.string(forKey: Self.accentColorKey)
        let accent = savedAccent.flatMap { AppAccentColor(rawValue: $0) } ?? .default
        self.selectedAccentColor = accent

        // Load the saved surface style (default: glassmorphic).
        let savedSurface = Self.defaults.string(forKey: Self.surfaceStyleKey)
        let resolvedSurface = savedSurface.flatMap { SurfaceStyle(rawValue: $0) } ?? .glassmorphic
        self.surfaceStyle = resolvedSurface

        // Load the saved button accent presentation style (auto-paired with surface style).
        let savedButtonStyle = Self.defaults.string(forKey: Self.buttonAccentStyleKey)
        self.buttonAccentStyle = savedButtonStyle.flatMap { ButtonAccentStyle(rawValue: $0) } ?? (resolvedSurface == .glassmorphic ? .accent : .themeContrast)

        // Load chat font settings (default: system family, 14pt body, 4pt line spacing)
        let savedFontFamily = Self.defaults.string(forKey: AppSettings.chatFontFamilyKey)
        self.chatFontFamily = savedFontFamily.flatMap { ChatFontFamily(rawValue: $0) } ?? .system
        let savedFontSize = Self.defaults.object(forKey: AppSettings.chatFontSizeKey) as? CGFloat
        self.chatFontSize = savedFontSize ?? 14
        let savedLineSpacing = Self.defaults.object(forKey: AppSettings.chatLineSpacingKey) as? CGFloat
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
        defaults.set(theme.id, forKey: Self.selectedThemeKey)
        Self.syncWindowAppearance(colorScheme: theme.colorScheme)
    }

    /// Applies a Code Viewer theme override.
    func applyCodeViewerTheme(_ override: CodeViewerThemeOverride) {
        self.codeViewerThemeOverride = override
        self.currentTheme = ThemeDecorator(base: baseTheme, accentColorOverride: selectedAccentColor, codeThemeOverride: override)
        defaults.set(override.rawValue, forKey: Self.codeViewerThemeKey)
    }

    /// Applies a new accent color override.
    func applyAccentColor(_ accent: AppAccentColor) {
        self.selectedAccentColor = accent
        self.currentTheme = ThemeDecorator(base: baseTheme, accentColorOverride: accent, codeThemeOverride: codeViewerThemeOverride)
        defaults.set(accent.rawValue, forKey: Self.accentColorKey)
    }

    /// Applies a new surface presentation style and automatically synchronizes the corresponding button presentation style:
    /// - `.glassmorphic` -> Dynamic Accent buttons (.accent)
    /// - `.solid` -> High-contrast Material buttons (.themeContrast)
    func applySurfaceStyle(_ style: SurfaceStyle) {
        self.surfaceStyle = style
        defaults.set(style.rawValue, forKey: Self.surfaceStyleKey)
        let buttonStyle: ButtonAccentStyle = (style == .glassmorphic ? .accent : .themeContrast)
        self.buttonAccentStyle = buttonStyle
        defaults.set(buttonStyle.rawValue, forKey: Self.buttonAccentStyleKey)
    }

    /// Applies a new button accent presentation style (Dynamic Accent vs. Monochrome Pro).
    func applyButtonAccentStyle(_ style: ButtonAccentStyle) {
        self.buttonAccentStyle = style
        defaults.set(style.rawValue, forKey: Self.buttonAccentStyleKey)
    }

    // MARK: - Chat Font Actions

    func applyChatFontFamily(_ family: ChatFontFamily) {
        self.chatFontFamily = family
        defaults.set(family.rawValue, forKey: AppSettings.chatFontFamilyKey)
    }

    func applyChatFontSize(_ size: CGFloat) {
        self.chatFontSize = size
        defaults.set(size, forKey: AppSettings.chatFontSizeKey)
    }

    func applyChatLineSpacing(_ spacing: CGFloat) {
        self.chatLineSpacing = spacing
        defaults.set(spacing, forKey: AppSettings.chatLineSpacingKey)
    }

    /// The resolved syntax theme for the Code Viewer and in-chat code blocks.
    var resolvedCodeViewerSyntaxTheme: SyntaxTheme {
        currentTheme.syntaxTheme
    }
}
