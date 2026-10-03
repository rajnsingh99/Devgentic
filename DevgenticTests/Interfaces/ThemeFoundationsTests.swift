// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
//
//  ThemeFoundationsTests.swift
//  DevgenticTests
//
//  Created on 03/09/26.
//

import XCTest
import SwiftUI
@testable import devgentic

@MainActor
final class ThemeFoundationsTests: XCTestCase {

    func testThemeColorSchemeDeclarations() {
        let materialTheme = AppThemes.MaterialTheme()
        XCTAssertEqual(materialTheme.colorScheme, .dark)
        XCTAssertTrue(materialTheme.isDark)
        XCTAssertEqual(materialTheme.codeHighlightThemeName, "material-darker")

        let cosmicDarkTheme = AppThemes.CosmicDarkTheme()
        XCTAssertEqual(cosmicDarkTheme.colorScheme, .dark)
        XCTAssertTrue(cosmicDarkTheme.isDark)
        XCTAssertEqual(cosmicDarkTheme.codeHighlightThemeName, "dracula")

        let highContrastTheme = AppThemes.HighContrastTheme()
        XCTAssertEqual(highContrastTheme.colorScheme, .dark)
        XCTAssertTrue(highContrastTheme.isDark)
        XCTAssertEqual(highContrastTheme.codeHighlightThemeName, "a11y-dark")

        let oneLightTheme = AppThemes.OneLightTheme()
        XCTAssertEqual(oneLightTheme.colorScheme, .light)
        XCTAssertFalse(oneLightTheme.isDark)
        XCTAssertEqual(oneLightTheme.codeHighlightThemeName, "github")

        let solarizedLightTheme = AppThemes.SolarizedLightTheme()
        XCTAssertEqual(solarizedLightTheme.colorScheme, .light)
        XCTAssertFalse(solarizedLightTheme.isDark)
        XCTAssertEqual(solarizedLightTheme.codeHighlightThemeName, "solarized-light")
    }

    func testSyntaxThemePatchedPreservesKeywords() {
        let cosmicDark = AppThemes.CosmicDarkTheme()
        let originalKeywords = cosmicDark.syntaxTheme.keywords

        // Patch with an accent color override (e.g. green)
        let patched = cosmicDark.syntaxTheme.patched(with: NSColor.green)

        // Keywords must NOT be overwritten by the UI accent color
        XCTAssertEqual(patched.keywords, originalKeywords, "Patched syntax theme must preserve original language keywords")

        // Bracket highlight should take the accent color with 0.4 alpha
        XCTAssertEqual(patched.bracketHighlight, NSColor.green.withAlphaComponent(0.4))
    }

    func testAppAccentColorPaletteAndBackwardCompatibility() {
        // Test all cases produce valid display names and colors
        for accent in AppAccentColor.allCases {
            XCTAssertFalse(accent.displayName.isEmpty)
            if accent != .default {
                XCTAssertNotNil(accent.color)
                XCTAssertNotNil(accent.nsColor)
            }
        }

        // Test Spotify Green
        let spotify = AppAccentColor.spotify
        XCTAssertEqual(spotify.displayName, "Spotify Green")
        XCTAssertNotNil(spotify.color)

        // Test White, Grey, and Black
        let white = AppAccentColor.white
        XCTAssertEqual(white.displayName, "Pure White")
        XCTAssertNotNil(white.color)
        XCTAssertNotNil(white.nsColor)

        let grey = AppAccentColor.grey
        XCTAssertEqual(grey.displayName, "Slate Grey")
        XCTAssertNotNil(grey.color)
        XCTAssertNotNil(grey.nsColor)

        let black = AppAccentColor.black
        XCTAssertEqual(black.displayName, "Onyx Black")
        XCTAssertNotNil(black.color)
        XCTAssertNotNil(black.nsColor)

        // Canonical rawValues only — retired aliases are no longer read.
        XCTAssertEqual(AppAccentColor(rawValue: "modern_spotify"), .modernSpotify)
        XCTAssertEqual(AppAccentColor(rawValue: "white"), .white)
        XCTAssertEqual(AppAccentColor(rawValue: "grey"), .grey)
        XCTAssertEqual(AppAccentColor(rawValue: "black"), .black)
        XCTAssertNil(AppAccentColor(rawValue: "spotify_green"))

        // Test isAccentLight and accentForegroundColor behavior
        let whiteDecorator = ThemeDecorator(base: AppThemes.MaterialTheme(), accentColorOverride: .white)
        XCTAssertTrue(whiteDecorator.isAccentLight)
        XCTAssertEqual(whiteDecorator.accentForegroundColor, Color(red: 0.08, green: 0.08, blue: 0.08))

        let blackDecorator = ThemeDecorator(base: AppThemes.MaterialTheme(), accentColorOverride: .black)
        XCTAssertFalse(blackDecorator.isAccentLight)
        XCTAssertEqual(blackDecorator.accentForegroundColor, .white)

        let blueDecorator = ThemeDecorator(base: AppThemes.MaterialTheme(), accentColorOverride: .blue)
        XCTAssertFalse(blueDecorator.isAccentLight)
        XCTAssertEqual(blueDecorator.accentForegroundColor, .white)
        XCTAssertEqual(blueDecorator.warningForegroundColor, Color(red: 0.08, green: 0.08, blue: 0.08))
    }

    func testThemeManagerAvailableThemes() {
        let manager = ThemeManager()
        let availableIDs = manager.availableThemes.map(\.id)

        // Must contain exactly 4 themes (2 dark, 2 light)
        XCTAssertEqual(availableIDs, ["material", "cosmic_dark", "one_light", "solarized_light"])
        XCTAssertFalse(availableIDs.contains("default"))
        XCTAssertFalse(availableIDs.contains("dracula"))
        XCTAssertFalse(availableIDs.contains("one_dark"))
        XCTAssertFalse(availableIDs.contains("github_light"))
    }

    func testThemeManagerBaseThemePreserved() {
        let manager = ThemeManager()
        let initialBase = manager.baseTheme

        // Apply an accent color override
        manager.applyAccentColor(.purple)

        // Base theme must still be the un-decorated theme
        XCTAssertEqual(manager.baseTheme.id, initialBase.id)
        XCTAssertEqual(manager.selectedAccentColor, .purple)
        XCTAssertEqual(manager.currentTheme.id, initialBase.id)
    }

    func testCodeThemeOverridePropagatesToCurrentTheme() {
        let manager = ThemeManager()

        // 1. With the Cosmic Dark override, the code theme uses material-darker stylesheet
        manager.applyTheme(AppThemes.CosmicDarkTheme())
        manager.applyCodeViewerTheme(.cosmicDark)
        XCTAssertEqual(manager.currentTheme.codeHighlightThemeName, "material-darker")

        // 2. Override with High Contrast (a11y-dark stylesheet)
        manager.applyCodeViewerTheme(.highContrast)
        XCTAssertEqual(manager.currentTheme.codeHighlightThemeName, "a11y-dark")
        XCTAssertEqual(manager.currentTheme.syntaxTheme.background, AppThemes.HighContrastTheme().syntaxTheme.background)

        // 3. Override with One Light (GitHub Highlightr stylesheet)
        manager.applyCodeViewerTheme(.oneLight)
        XCTAssertEqual(manager.currentTheme.codeHighlightThemeName, "github")
        XCTAssertEqual(manager.currentTheme.syntaxTheme.background, AppThemes.OneLightTheme().syntaxTheme.background)

        // 4. Override with Solarized Light
        manager.applyCodeViewerTheme(.solarizedLight)
        XCTAssertEqual(manager.currentTheme.codeHighlightThemeName, "solarized-light")
        XCTAssertEqual(manager.currentTheme.syntaxTheme.background, AppThemes.SolarizedLightTheme().syntaxTheme.background)

        // Canonical rawValues only — retired names are no longer read.
        XCTAssertEqual(CodeViewerThemeOverride(rawValue: "cosmic_dark"), .cosmicDark)
        XCTAssertEqual(CodeViewerThemeOverride(rawValue: "high_contrast"), .highContrast)
        XCTAssertEqual(CodeViewerThemeOverride(rawValue: "one_light"), .oneLight)
        XCTAssertEqual(CodeViewerThemeOverride(rawValue: "solarized_light"), .solarizedLight)
        XCTAssertNil(CodeViewerThemeOverride(rawValue: "dracula"))

        // 5. Reset to Cosmic Dark
        manager.applyCodeViewerTheme(.cosmicDark)
        XCTAssertEqual(manager.currentTheme.codeHighlightThemeName, "material-darker")
    }

    func testCodeBlockHeaderTextTokens() {
        let oneLight = AppThemes.OneLightTheme()
        XCTAssertNotNil(oneLight.codeBlockHeaderText)
        XCTAssertNotNil(oneLight.codeBlockHeaderSecondaryText)

        let solarizedLight = AppThemes.SolarizedLightTheme()
        XCTAssertNotNil(solarizedLight.codeBlockHeaderText)
        XCTAssertNotNil(solarizedLight.codeBlockHeaderSecondaryText)

        let cosmicDark = AppThemes.CosmicDarkTheme()
        XCTAssertNotNil(cosmicDark.codeBlockHeaderText)
        XCTAssertNotNil(cosmicDark.codeBlockHeaderSecondaryText)

        let highContrast = AppThemes.HighContrastTheme()
        XCTAssertNotNil(highContrast.codeBlockHeaderText)
        XCTAssertNotNil(highContrast.codeBlockHeaderSecondaryText)
    }

    func testChatTypographyAndCodeScaling() {
        let manager = ThemeManager()

        // Test default typography
        manager.applyChatFontSize(15)
        manager.applyChatLineSpacing(4)
        XCTAssertEqual(manager.chatFontSize, 15)
        XCTAssertEqual(manager.chatLineSpacing, 4)

        // Code font size tracks 2pt below chat font size
        XCTAssertEqual(ChatUIConstants.codeFontSize(forChatFontSize: manager.chatFontSize), 13)

        // Test custom font size & line spacing
        manager.applyChatFontSize(18)
        manager.applyChatLineSpacing(6)
        XCTAssertEqual(manager.chatFontSize, 18)
        XCTAssertEqual(manager.chatLineSpacing, 6)
        XCTAssertEqual(ChatUIConstants.codeFontSize(forChatFontSize: manager.chatFontSize), 16)

        // Reset to default
        manager.applyChatFontSize(15)
        manager.applyChatLineSpacing(4)
        XCTAssertEqual(manager.chatFontSize, 15)
        XCTAssertEqual(manager.chatLineSpacing, 4)
    }

    func testSurfaceStyleDefaultsAndPersistence() {
        let manager = ThemeManager()

        // Verify raw values
        XCTAssertEqual(SurfaceStyle.glassmorphic.rawValue, "glassmorphic")
        XCTAssertEqual(SurfaceStyle.solid.rawValue, "solid")
        XCTAssertEqual(SurfaceStyle.allCases.count, 2)

        // Switch to solid
        manager.applySurfaceStyle(.solid)
        XCTAssertEqual(manager.surfaceStyle, .solid)
        XCTAssertEqual(TestHost.defaults.string(forKey: "selectedSurfaceStyle"), "solid")

        // Switch back to glassmorphic
        manager.applySurfaceStyle(.glassmorphic)
        XCTAssertEqual(manager.surfaceStyle, .glassmorphic)
        XCTAssertEqual(TestHost.defaults.string(forKey: "selectedSurfaceStyle"), "glassmorphic")
    }

    func testChatFontFamilyAndTypographySettings() {
        let manager = ThemeManager()

        // Verify all font families
        XCTAssertEqual(ChatFontFamily.allCases.count, 4)
        XCTAssertEqual(ChatFontFamily.system.rawValue, "system")
        XCTAssertEqual(ChatFontFamily.monospaced.rawValue, "monospaced")
        XCTAssertEqual(ChatFontFamily.serif.rawValue, "serif")
        XCTAssertEqual(ChatFontFamily.rounded.rawValue, "rounded")

        // Verify design mappings
        XCTAssertEqual(ChatFontFamily.system.design, .default)
        XCTAssertEqual(ChatFontFamily.monospaced.design, .monospaced)
        XCTAssertEqual(ChatFontFamily.serif.design, .serif)
        XCTAssertEqual(ChatFontFamily.rounded.design, .rounded)

        // Verify display metadata
        for family in ChatFontFamily.allCases {
            XCTAssertFalse(family.displayName.isEmpty)
            XCTAssertFalse(family.shortName.isEmpty)
            XCTAssertFalse(family.subtitle.isEmpty)
            XCTAssertFalse(family.sampleGlyph.isEmpty)
        }

        // Apply Monospaced
        manager.applyChatFontFamily(.monospaced)
        XCTAssertEqual(manager.chatFontFamily, .monospaced)
        XCTAssertEqual(TestHost.defaults.string(forKey: AppSettings.chatFontFamilyKey), "monospaced")

        // Apply Serif
        manager.applyChatFontFamily(.serif)
        XCTAssertEqual(manager.chatFontFamily, .serif)
        XCTAssertEqual(TestHost.defaults.string(forKey: AppSettings.chatFontFamilyKey), "serif")

        // Reset to System
        manager.applyChatFontFamily(.system)
        XCTAssertEqual(manager.chatFontFamily, .system)
        XCTAssertEqual(TestHost.defaults.string(forKey: AppSettings.chatFontFamilyKey), "system")
    }

    func testThemeWritesDoNotReachTheUsersDomain() {
        let key = "selectedAccentColor"
        let userValueBefore = UserDefaults.standard.string(forKey: key)

        let manager = ThemeManager()
        manager.applyAccentColor(.pink)

        // The write must reach TestHost.defaults
        XCTAssertEqual(TestHost.defaults.string(forKey: key), "pink")

        // The write must NEVER pollute the developer's real UserDefaults domain
        XCTAssertEqual(UserDefaults.standard.string(forKey: key), userValueBefore)
    }
}
