// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
//
//  WebSearchSettingsViewTests.swift
//  DevgenticTests
//
//  Created by Raj Singh.
//

import XCTest
import SwiftUI
@testable import devgentic

@MainActor
final class WebSearchSettingsViewTests: XCTestCase {

    func testWebSearchSettingsViewInstantiates() {
        let view = WebSearchSettingsView()
        XCTAssertNotNil(view.body, "WebSearchSettingsView must produce a valid body")
    }

    func testViewDoesNotHaveRedundantInnerScrollView() throws {
        let source = try Self.read("Devgentic/Interfaces/Main/Views/Sidebar/Settings/WebSearchSettingsView.swift")
        // SettingsDetailContainerView wraps destinations in an outer ScrollView + padding(24).
        // Having an inner ScrollView around the root VStack causes double-scroll conflicts.
        XCTAssertFalse(
            source.contains("var body: some View {\n        ScrollView"),
            "WebSearchSettingsView root body must not be wrapped in a redundant ScrollView"
        )
    }

    func testViewUsesTactileButtonsThroughout() throws {
        let source = try Self.read("Devgentic/Interfaces/Main/Views/Sidebar/Settings/WebSearchSettingsView.swift")
        XCTAssertTrue(
            source.contains("TactileButton("),
            "WebSearchSettingsView must use TactileButton for actions"
        )
        XCTAssertTrue(
            source.contains("TactileIconButton("),
            "WebSearchSettingsView must use TactileIconButton for secondary utility actions"
        )
    }

    func testViewUsesSecretInputField() throws {
        let source = try Self.read("Devgentic/Interfaces/Main/Views/Sidebar/Settings/WebSearchSettingsView.swift")
        XCTAssertTrue(
            source.contains("SecretInputField("),
            "WebSearchSettingsView must use SecretInputField for API keys per §6.1"
        )
    }

    func testDiagnosticsInspectorUsesInPlaceOpacityTransition() throws {
        let source = try Self.read("Devgentic/Interfaces/Main/Views/Sidebar/Settings/WebSearchSettingsView.swift")
        XCTAssertTrue(
            source.contains(".transition(.opacity)"),
            "Accordions and disclosures in cards must use .transition(.opacity) per §13.2"
        )
        XCTAssertFalse(
            source.contains(".transition(.move(edge: .top))"),
            "In-card accordions must not translate from .top per §13.1 / §13.3"
        )
    }

    func testAllProvidersAreHandled() {
        for provider in WebSearchProvider.allCases {
            XCTAssertFalse(provider.displayName.isEmpty)
            XCTAssertFalse(provider.summary.isEmpty)
            XCTAssertNotNil(provider.signupURL)
        }
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
        throw XCTSkip("Could not locate \(relativePath) from \(#filePath) — source-reading tests need checkout present.")
    }
}
