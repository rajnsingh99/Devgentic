// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2026 Raj Singh
//
//  ButtonDesignSystemValidationTests.swift
//  DevgenticTests
//
//  Regression test suite validating adherence to the button design system
//  specification. Enforces zero bare bordered buttons
//  across UI modules and verifies surface style synchronization.
//

import XCTest
import SwiftUI
@testable import devgentic

@MainActor
final class ButtonDesignSystemValidationTests: XCTestCase {

    func testSurfaceStyleSyncsButtonAccentStyle() {
        let manager = ThemeManager()

        // Material surface (.solid) must configure themeContrast (Style 2 Monochrome Contrast Keycap)
        manager.applySurfaceStyle(.solid)
        XCTAssertEqual(manager.surfaceStyle, .solid)
        XCTAssertEqual(manager.buttonAccentStyle, .themeContrast)

        // Glassmorphic surface (.glassmorphic) must configure accent (Style 3 Tactile Glass Surface)
        manager.applySurfaceStyle(.glassmorphic)
        XCTAssertEqual(manager.surfaceStyle, .glassmorphic)
        XCTAssertEqual(manager.buttonAccentStyle, .accent)
    }

    func testTactileButtonVariantsAndSizesInstantiate() {
        // Verify all TactileButton variants instantiate cleanly without crashing
        let variants: [TactileButtonVariant] = [.primary, .secondary, .subtle, .destructive]
        let sizes: [TactileButtonSize] = [.compact, .regular]

        for variant in variants {
            for size in sizes {
                let button = TactileButton(
                    title: "Test Button",
                    icon: "star.fill",
                    variant: variant,
                    size: size,
                    isLoading: false,
                    isDisabled: false
                ) {
                    // no-op
                }
                XCTAssertNotNil(button.body)
            }
        }
    }

    func testTactileIconButtonSizesInstantiate() {
        let iconButtonCompact = TactileIconButton(icon: "xmark", tooltip: "Close", size: .compact) {}
        XCTAssertNotNil(iconButtonCompact.body)

        let iconButtonRegular = TactileIconButton(icon: "gearshape", tooltip: "Settings", size: .regular) {}
        XCTAssertNotNil(iconButtonRegular.body)
    }

    func testNoBareBorderedButtonsInInterfaces() throws {
        // Finds the Devgentic/Interfaces directory from repository root
        let fileManager = FileManager.default
        let currentDir = URL(fileURLWithPath: fileManager.currentDirectoryPath)
        let interfacesDir = currentDir.appendingPathComponent("Devgentic/Interfaces")

        guard fileManager.fileExists(atPath: interfacesDir.path) else {
            // In case tests run in a sandbox or derived data directory where repo path differs, skip gracefully
            return
        }

        let enumerator = fileManager.enumerator(
            at: interfacesDir,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        )

        var violatingSites: [String] = []

        while let fileURL = enumerator?.nextObject() as? URL {
            guard fileURL.pathExtension == "swift" else { continue }
            // Skip the canonical implementation file where the deprecation comment is documented
            if fileURL.lastPathComponent == "SettingsButtonComponents.swift" { continue }

            let content = try String(contentsOf: fileURL, encoding: .utf8)
            let lines = content.components(separatedBy: .newlines)

            for (index, line) in lines.enumerated() {
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                if trimmed.hasPrefix("//") { continue }

                if trimmed.contains(".buttonStyle(.bordered)") || trimmed.contains(".buttonStyle(.borderedProminent)") {
                    violatingSites.append("\(fileURL.lastPathComponent):\(index + 1): \(trimmed)")
                }
            }
        }

        XCTAssertTrue(
            violatingSites.isEmpty,
            "Bare .bordered / .borderedProminent buttons violate the button design system specification. Found in:\n" + violatingSites.joined(separator: "\n")
        )
    }

    func testNoEllipsesInSidebarActionButtonsAndPlaceholders() throws {
        let fileManager = FileManager.default
        let currentDir = URL(fileURLWithPath: fileManager.currentDirectoryPath)
        let sidebarDir = currentDir.appendingPathComponent("Devgentic/Interfaces/Main/Views/Sidebar")

        guard fileManager.fileExists(atPath: sidebarDir.path) else {
            return
        }

        let enumerator = fileManager.enumerator(
            at: sidebarDir,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        )

        var violatingSites: [String] = []

        while let fileURL = enumerator?.nextObject() as? URL {
            guard fileURL.pathExtension == "swift" else { continue }

            let content = try String(contentsOf: fileURL, encoding: .utf8)
            let lines = content.components(separatedBy: .newlines)

            for (index, line) in lines.enumerated() {
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                if trimmed.hasPrefix("//") || trimmed.hasPrefix("/*") || trimmed.hasPrefix("*") { continue }

                if (trimmed.contains("buttonTitle:") || trimmed.contains("placeholder:") || trimmed.contains("Button(\""))
                    && (trimmed.contains("...") || trimmed.contains("…")) {
                    violatingSites.append("\(fileURL.lastPathComponent):\(index + 1): \(trimmed)")
                }
            }
        }

        XCTAssertTrue(
            violatingSites.isEmpty,
            "Sidebar action buttons and placeholders should not have ellipses ('...' or '…'). Found in:\n" + violatingSites.joined(separator: "\n")
        )
    }
}
