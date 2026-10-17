// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
//
//  OnboardingPolishTests.swift
//  DevgenticTests
//
//  The Setup Assistant's P2 contract: the window is sized once and given back, a re-run can be
//  cancelled without side effects, the accent stays readable on every theme, and the copy is
//  localizable and accurate.
//

import XCTest
import AppKit
@testable import devgentic

@MainActor
final class OnboardingPolishTests: XCTestCase {

    private func makeViewModel() -> OnboardingViewModel {
        OnboardingViewModel(physicalMemoryBytes: 16 * 1_073_741_824, checksInstallStatus: false,
                            systemSettings: FakeOnboardingSystemSettings())
    }

    // MARK: - Window

    /// The accessor configures a window once, and hands back the minimum size it found. It used to
    /// re-centre on every view update (so the window could not be resized) and leave onboarding's
    /// 840×720 minimum on the main window forever.
    func testTheWindowIsConfiguredOnceAndItsMinimumSizeIsGivenBack() {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1200, height: 900),
                              styleMask: [.titled, .resizable], backing: .buffered, defer: true)
        window.minSize = NSSize(width: 400, height: 300)
        let coordinator = OnboardingWindowAccessor.Coordinator()

        OnboardingWindowAccessor.configureOnce(window, coordinator: coordinator)
        XCTAssertEqual(window.minSize, OnboardingWindowAccessor.minimumSize)
        XCTAssertNotNil(coordinator.previousFrame, "a window at least onboarding's size is given back its frame")

        // A later update must not reconfigure: whatever the user did since stands.
        window.minSize = NSSize(width: 100, height: 100)
        OnboardingWindowAccessor.configureOnce(window, coordinator: coordinator)
        XCTAssertEqual(window.minSize, NSSize(width: 100, height: 100), "configured twice")

        OnboardingWindowAccessor.dismantleNSView(NSView(), coordinator: coordinator)
        XCTAssertEqual(window.minSize, NSSize(width: 400, height: 300), "the main window kept onboarding's minimum size")
    }

    /// Wiring: the update path only configures a window that has not been configured yet.
    func testTheUpdatePathDoesNotReconfigure() throws {
        let container = try source("Devgentic/Interfaces/Onboarding/Views/OnboardingContainerView.swift")
        XCTAssertTrue(container.contains("guard context.coordinator.window == nil else { return }"))
        XCTAssertTrue(container.contains(".background(OnboardingWindowAccessor())"))
    }

    // MARK: - Cancel (re-runs only)

    func testCancelIsOnlyOfferedToSomeoneWhoAlreadyHasAProfile() {
        let vm = makeViewModel()
        XCTAssertFalse(vm.canCancelSetup, "a first run must end with a profile")

        var completed = false
        vm.cancelSetup(themeManager: ThemeManager()) { _ in completed = true }
        XCTAssertFalse(completed)

        vm.existingProfileNames = ["Research"]
        XCTAssertTrue(vm.canCancelSetup)
    }

    func testCancelPutsBackTheThemeTheUserHad() {
        let themeManager = ThemeManager()
        let vm = makeViewModel()
        vm.adoptCurrentTheme(from: themeManager)
        let originalTheme = themeManager.baseTheme.id
        let originalSurface = themeManager.surfaceStyle

        let otherTheme = themeManager.availableThemes.first { $0.id != originalTheme }!.id
        vm.selectTheme(otherTheme, themeManager: themeManager)
        themeManager.applySurfaceStyle(originalSurface == .solid ? .glassmorphic : .solid)
        XCTAssertEqual(themeManager.baseTheme.id, otherTheme)

        vm.existingProfileNames = ["Research"]
        var completed = false
        vm.cancelSetup(themeManager: themeManager) { _ in completed = true }

        XCTAssertTrue(completed)
        XCTAssertEqual(themeManager.baseTheme.id, originalTheme)
        XCTAssertEqual(themeManager.surfaceStyle, originalSurface)
    }

    // MARK: - Accent

    func testTheLastAccentSlotMirrorsTheTheme() {
        let dark = OnboardingViewModel.accentPalette(isDarkTheme: true)
        let light = OnboardingViewModel.accentPalette(isDarkTheme: false)
        XCTAssertEqual(dark.count, 8)
        XCTAssertEqual(light.count, 8)
        XCTAssertTrue(dark.contains(.white) && !dark.contains(.black))
        XCTAssertTrue(light.contains(.black) && !light.contains(.white), "Pure White is unreadable on a light theme")
    }

    /// Wiring: picking a theme through the view model swaps a mismatched accent and applies it.
    func testPickingALightThemeSwapsPureWhiteForOnyxBlack() {
        let themeManager = ThemeManager()
        let vm = makeViewModel()
        guard let light = themeManager.availableThemes.first(where: { !$0.isDark }),
              let dark = themeManager.availableThemes.first(where: { $0.isDark }) else {
            return XCTFail("expected both a light and a dark theme")
        }
        vm.selectedAccentColor = .white

        vm.selectTheme(light.id, themeManager: themeManager)
        XCTAssertEqual(vm.selectedAccentColor, .black)
        XCTAssertEqual(themeManager.selectedAccentColor, .black)

        vm.selectTheme(dark.id, themeManager: themeManager)
        XCTAssertEqual(vm.selectedAccentColor, .white)

        vm.selectedAccentColor = .blue
        vm.selectTheme(light.id, themeManager: themeManager)
        XCTAssertEqual(vm.selectedAccentColor, .blue, "an accent that reads on both is left alone")
    }

    // MARK: - Copy

    /// `Text(cond ? "a" : "b")` resolves to the `StringProtocol` overload: rendered verbatim and
    /// never extracted to the String Catalog. Every onboarding ternary must localize its branches.
    func testNoOnboardingTextRendersARawLiteralTernary() throws {
        let pattern = try NSRegularExpression(pattern: #"Text\([^\n]*\?\s*"[^"]+"\s*:"#)
        for file in ["OnboardingBehaviorView", "OnboardingModelDownloadView", "OnboardingProfileSetupView",
                     "OnboardingReadyView", "OnboardingThemeView", "OnboardingWelcomeSlideView", "OnboardingContainerView",
                     "OnboardingFeaturesView", "OnboardingPermissionsView", "OnboardingPrivacyView"] {
            let text = try source("Devgentic/Interfaces/Onboarding/Views/\(file).swift")
            let hits = pattern.numberOfMatches(in: text, range: NSRange(text.startIndex..., in: text))
            XCTAssertEqual(hits, 0, "\(file) renders an unlocalized literal ternary")
        }
        let components = try source("Devgentic/Interfaces/Onboarding/Views/OnboardingComponents.swift")
        XCTAssertEqual(components.components(separatedBy: "let title: LocalizedStringKey").count - 1, 2,
                       "onboarding button titles must be LocalizedStringKey, not String")
    }

    /// The feature is Quick Access, and its shortcut is the user's — "⌘ Space" was Spotlight's.
    func testTheQuickAccessSlideUsesTheRealNameAndShortcut() throws {
        let welcome = try source("Devgentic/Interfaces/Onboarding/Views/OnboardingWelcomeSlideView.swift")
        let vm = try source("Devgentic/Interfaces/Onboarding/OnboardingViewModel.swift")
        for text in [welcome, vm] {
            XCTAssertFalse(text.contains("QuickOverlay"))
            XCTAssertFalse(text.contains("Text(\"⌘ Space\")"), "a hardcoded shortcut is rendered")
            XCTAssertFalse(text.contains("Screen Capture OCR"), "Quick Access captures the screen; it does not OCR it")
        }
        XCTAssertTrue(welcome.contains("QuickAccessConfigManager.shared.shortcutDescription"))
    }

    private func source(_ path: String) throws -> String {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent()
        guard let text = try? String(contentsOf: root.appendingPathComponent(path), encoding: .utf8) else {
            throw XCTSkip("\(path) not reachable — running outside a checkout")
        }
        return text
    }
}
