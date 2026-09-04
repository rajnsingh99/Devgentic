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
        XCTAssertEqual(cosmicDarkTheme.codeHighlightThemeName, "nord")

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

        // Test backward compatibility with saved rawValues
        XCTAssertEqual(AppAccentColor(rawValue: "modern_spotify"), .modernSpotify)
        XCTAssertEqual(AppAccentColor(rawValue: "cosmic_cyan"), .modernSpotify)
        XCTAssertEqual(AppAccentColor(rawValue: "spotify_green"), .spotify)
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

        // 1. When default, code theme follows app theme (Material Darker)
        manager.applyTheme(AppThemes.MaterialTheme())
        manager.applyCodeViewerTheme(.default)
        XCTAssertEqual(manager.currentTheme.codeHighlightThemeName, "material-darker")

        // 2. Override with One Light (GitHub Highlightr stylesheet)
        manager.applyCodeViewerTheme(.oneLight)
        XCTAssertEqual(manager.currentTheme.codeHighlightThemeName, "github")
        XCTAssertEqual(manager.currentTheme.syntaxTheme.background, AppThemes.OneLightTheme().syntaxTheme.background)

        // 3. Override with Cosmic Dark
        manager.applyCodeViewerTheme(.cosmicDark)
        XCTAssertEqual(manager.currentTheme.codeHighlightThemeName, "nord")
        XCTAssertEqual(manager.currentTheme.syntaxTheme.background, AppThemes.CosmicDarkTheme().syntaxTheme.background)

        // 4. Override with Solarized Light
        manager.applyCodeViewerTheme(.solarizedLight)
        XCTAssertEqual(manager.currentTheme.codeHighlightThemeName, "solarized-light")
        XCTAssertEqual(manager.currentTheme.syntaxTheme.background, AppThemes.SolarizedLightTheme().syntaxTheme.background)

        // Backward compatibility mappings
        XCTAssertEqual(CodeViewerThemeOverride(rawValue: "dracula"), .material)
        XCTAssertEqual(CodeViewerThemeOverride(rawValue: "one_dark"), .material)
        XCTAssertEqual(CodeViewerThemeOverride(rawValue: "material"), .material)
        XCTAssertEqual(CodeViewerThemeOverride(rawValue: "github_light"), .oneLight)
        XCTAssertEqual(CodeViewerThemeOverride(rawValue: "one_light"), .oneLight)

        // 5. Reset to default
        manager.applyCodeViewerTheme(.default)
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
}
