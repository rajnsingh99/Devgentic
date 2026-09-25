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
        // ⚠️ "dracula" is a HIGHLIGHTR STYLESHEET, not the deleted Dracula app theme. The app
        // ships four themes (Material, CosmicDark, OneLight, SolarizedLight) and `ThemeManager`
        // migrates a stored "dracula" id to `.material` — but CosmicDark deliberately renders its
        // CODE with Highlightr's dracula palette, which `Theme.swift` documents at the property.
        // Was "nord": the third stale reference to the same rename in this file, and the last.
        XCTAssertEqual(cosmicDarkTheme.codeHighlightThemeName, "dracula")

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
        let material = AppThemes.MaterialTheme()
        let originalKeywords = material.syntaxTheme.keywords

        // Patch with an accent color override (e.g. green)
        let patched = material.syntaxTheme.patched(with: NSColor.green)

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

        // Test backward compatibility with saved rawValues and aliases
        XCTAssertEqual(AppAccentColor(rawValue: "modern_spotify"), .modernSpotify)
        XCTAssertEqual(AppAccentColor(rawValue: "cosmic_cyan"), .modernSpotify)
        XCTAssertEqual(AppAccentColor(rawValue: "spotify_green"), .spotify)
        XCTAssertEqual(AppAccentColor(rawValue: "white"), .white)
        XCTAssertEqual(AppAccentColor(rawValue: "pure_white"), .white)
        XCTAssertEqual(AppAccentColor(rawValue: "studio_white"), .white)
        XCTAssertEqual(AppAccentColor(rawValue: "grey"), .grey)
        XCTAssertEqual(AppAccentColor(rawValue: "gray"), .grey)
        XCTAssertEqual(AppAccentColor(rawValue: "slate_grey"), .grey)
        XCTAssertEqual(AppAccentColor(rawValue: "slate_gray"), .grey)
        XCTAssertEqual(AppAccentColor(rawValue: "black"), .black)
        XCTAssertEqual(AppAccentColor(rawValue: "onyx_black"), .black)
        XCTAssertEqual(AppAccentColor(rawValue: "jet_black"), .black)
        XCTAssertEqual(AppAccentColor(rawValue: "pure_black"), .black)

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

    func testThemeManagerAvailableThemesAndMigration() {
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

        // 1. With the Material override, the code theme follows the app theme (Material Darker).
        // ⚠️ Was `.default`, a case the override rename removed — "default" survives only as a
        // backward-compatible rawValue (asserted below), not as a case. The sweep updated the
        // other two call sites in this file and missed this one, which broke the whole test
        // BUNDLE's compile — so every test in the target was unrunnable, not just this one.
        manager.applyTheme(AppThemes.MaterialTheme())
        manager.applyCodeViewerTheme(.material)
        XCTAssertEqual(manager.currentTheme.codeHighlightThemeName, "material-darker")

        // 2. Override with One Light (GitHub Highlightr stylesheet)
        manager.applyCodeViewerTheme(.oneLight)
        XCTAssertEqual(manager.currentTheme.codeHighlightThemeName, "github")
        XCTAssertEqual(manager.currentTheme.syntaxTheme.background, AppThemes.OneLightTheme().syntaxTheme.background)

        // 3. Override with Cosmic Dark
        manager.applyCodeViewerTheme(.cosmicDark)
        XCTAssertEqual(manager.currentTheme.codeHighlightThemeName, "dracula")
        XCTAssertEqual(manager.currentTheme.syntaxTheme.background, AppThemes.CosmicDarkTheme().syntaxTheme.background)

        // 4. Override with Solarized Light
        manager.applyCodeViewerTheme(.solarizedLight)
        XCTAssertEqual(manager.currentTheme.codeHighlightThemeName, "solarized-light")
        XCTAssertEqual(manager.currentTheme.syntaxTheme.background, AppThemes.SolarizedLightTheme().syntaxTheme.background)

        // Backward compatibility mappings
        XCTAssertEqual(CodeViewerThemeOverride(rawValue: "default"), .material)
        XCTAssertEqual(CodeViewerThemeOverride(rawValue: "dracula"), .material)
        XCTAssertEqual(CodeViewerThemeOverride(rawValue: "one_dark"), .material)
        XCTAssertEqual(CodeViewerThemeOverride(rawValue: "material"), .material)
        XCTAssertEqual(CodeViewerThemeOverride(rawValue: "github_light"), .oneLight)
        XCTAssertEqual(CodeViewerThemeOverride(rawValue: "one_light"), .oneLight)

        // 5. Reset to Material
        manager.applyCodeViewerTheme(.material)
        XCTAssertEqual(manager.currentTheme.codeHighlightThemeName, "material-darker")
    }

    func testCodeBlockHeaderTextTokens() {
        let oneLight = AppThemes.OneLightTheme()
        XCTAssertNotNil(oneLight.codeBlockHeaderText)
        XCTAssertNotNil(oneLight.codeBlockHeaderSecondaryText)

        let solarizedLight = AppThemes.SolarizedLightTheme()
        XCTAssertNotNil(solarizedLight.codeBlockHeaderText)
        XCTAssertNotNil(solarizedLight.codeBlockHeaderSecondaryText)

        let material = AppThemes.MaterialTheme()
        XCTAssertNotNil(material.codeBlockHeaderText)
        XCTAssertNotNil(material.codeBlockHeaderSecondaryText)

        let cosmicDark = AppThemes.CosmicDarkTheme()
        XCTAssertNotNil(cosmicDark.codeBlockHeaderText)
        XCTAssertNotNil(cosmicDark.codeBlockHeaderSecondaryText)
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
        XCTAssertEqual(UserDefaults.standard.string(forKey: "selectedSurfaceStyle"), "solid")

        // Switch back to glassmorphic
        manager.applySurfaceStyle(.glassmorphic)
        XCTAssertEqual(manager.surfaceStyle, .glassmorphic)
        XCTAssertEqual(UserDefaults.standard.string(forKey: "selectedSurfaceStyle"), "glassmorphic")
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
        XCTAssertEqual(UserDefaults.standard.string(forKey: AppSettings.chatFontFamilyKey), "monospaced")

        // Apply Serif
        manager.applyChatFontFamily(.serif)
        XCTAssertEqual(manager.chatFontFamily, .serif)
        XCTAssertEqual(UserDefaults.standard.string(forKey: AppSettings.chatFontFamilyKey), "serif")

        // Reset to System
        manager.applyChatFontFamily(.system)
        XCTAssertEqual(manager.chatFontFamily, .system)
        XCTAssertEqual(UserDefaults.standard.string(forKey: AppSettings.chatFontFamilyKey), "system")
    }
}
