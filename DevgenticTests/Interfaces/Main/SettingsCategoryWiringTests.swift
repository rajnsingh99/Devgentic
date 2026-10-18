// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
//
//  SettingsCategoryWiringTests.swift
//  DevgenticTests
//
//  Created by Raj Singh.
//

import XCTest
import SwiftUI
@testable import devgentic

@MainActor
final class SettingsCategoryWiringTests: XCTestCase {

    func testMLXModelStoreCategoryIsPresentInAllCases() {
        XCTAssertTrue(
            SettingsCategory.allCases.contains(.mlxModelStore),
            "SettingsCategory.allCases must contain .mlxModelStore"
        )
    }

    func testMLXModelStoreMetadata() {
        let category = SettingsCategory.mlxModelStore
        XCTAssertEqual(category.rawValue, "MLX Model Store")
        XCTAssertEqual(category.id, "MLX Model Store")
        XCTAssertEqual(category.iconName, "shippingbox")
        XCTAssertEqual(category.subtitle, String(localized: "Browse Apple Silicon models"))
    }

    func testMLXModelStoreDestinationInstantiation() {
        let category = SettingsCategory.mlxModelStore
        let destination = category.destination
        XCTAssertNotNil(destination, "SettingsCategory.mlxModelStore must produce a valid destination view")
    }

    func testSettingsDetailContainerHandlesMLXModelStore() throws {
        let source = try Self.read("Devgentic/Interfaces/Main/Views/SettingsDetailContainerView.swift")
        XCTAssertTrue(
            source.contains("if category == .mlxModelStore"),
            "SettingsDetailContainerView must handle .mlxModelStore directly without duplicate DynamicIslandBar"
        )
    }

    func testCommandPaletteIncludesMLXModelStoreSettingsCommand() throws {
        let source = try Self.read("Devgentic/Interfaces/CommandPalette/CommandPaletteView.swift")
        XCTAssertTrue(
            source.contains("Settings: MLX Model Store"),
            "CommandPaletteView must include a 'Settings: MLX Model Store' command"
        )
        XCTAssertTrue(
            source.contains("router.navigateToSettings(.mlxModelStore)"),
            "CommandPaletteView must route to router.navigateToSettings(.mlxModelStore)"
        )
    }

    private static func read(_ relativePath: String) throws -> String {
        var dir = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        for _ in 0..<10 {
            let candidate = dir.appendingPathComponent(relativePath)
            if FileManager.default.fileExists(atPath: candidate.path) {
                return try String(contentsOf: candidate, encoding: .utf8)
            }
            dir = dir.deletingLastPathComponent()
        }
        throw XCTSkip("Could not locate \(relativePath) from \(#filePath) — source-reading tests need the checkout present.")
    }
}
