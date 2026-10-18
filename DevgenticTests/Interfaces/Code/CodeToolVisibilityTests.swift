// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
//
//  CodeToolVisibilityTests.swift
//  DevgenticTests
//
//  Created by Raj Singh.
//

import XCTest
@testable import devgentic

final class CodeToolVisibilityTests: XCTestCase {

    /// The legacy monolithic tools withdrawn from the catalogue.
    ///
    /// `execute_shell`, `edit_code`, `code_search`, `create_file`, and `write_file` were withdrawn
    /// in favor of the focused split tools (`run_command`, `edit_code_single`/`edit_code_batch`,
    /// `code_search_*`, `create_new_file`/`overwrite_file`) which are now offered in the Library
    /// to both Chat and Code profiles.
    private static let withdrawnSupersededTools: Set<String> = [
        "edit_code", "code_search", "create_file", "write_file", "execute_shell"
    ]

    /// The 9 precision tools previously restricted to Code that are now shared across all profiles.
    private static let sharedCodingTools: Set<String> = [
        "diff_files", "git", "edit_code_single", "edit_code_batch",
        "code_search_text", "code_search_symbol", "code_search_files",
        "create_new_file", "overwrite_file"
    ]

    func testLockedSetMatchesThePresetTools() {
        let expected = Set(CodeToolPreset.defaultTools.map(\.name))
        XCTAssertEqual(CodeToolPreset.lockedToolNames, expected, """
            the derived locked set no longer matches the preset tools — \
            missing: \(expected.subtracting(CodeToolPreset.lockedToolNames).sorted()), \
            unexpected: \(CodeToolPreset.lockedToolNames.subtracting(expected).sorted())
            """)
    }

    /// With all superseded tools withdrawn, `hiddenFromCodeLibrary` is empty.
    func testCatalogCarriesNoSupersededTools() {
        XCTAssertTrue(NativeToolCatalog.hiddenFromCodeLibrary.isEmpty,
                      "superseded tools remaining in catalogue: \(NativeToolCatalog.hiddenFromCodeLibrary)")
    }

    /// All superseded tools must be absent from the catalogue.
    func testSupersededToolsAreWithdrawnFromCatalog() {
        for name in Self.withdrawnSupersededTools {
            XCTAssertNil(NativeToolCatalog.entry(named: name),
                         "\(name) was superseded and should be withdrawn from the catalogue")
        }
    }

    /// The coding tools are now registered in the shared Library for all profiles (Chat, Code, Workflow).
    @MainActor
    func testCodingToolsAreRegisteredInTheLibrary() {
        let registered = Set(LocalToolManager.shared.availableTools().map(\.name))
        for name in Self.sharedCodingTools {
            XCTAssertTrue(registered.contains(name),
                          "\(name) must be in the Library so Chat and Workflow profiles can use it")
        }
    }

    /// No tools should be withheld as `.codeOnly` — the entire catalogue is available in the Library.
    @MainActor
    func testNoToolsAreRestrictedToCodeOnly() {
        let codeOnly = Set(NativeToolCatalog.codeOnlyTools.map(\.name))
        XCTAssertTrue(codeOnly.isEmpty,
                      "tools still marked .codeOnly: \(codeOnly.sorted())")
    }

    /// A Code profile surfaces preset tools in the Library view as locked core tools rather than hiding them.
    func testPresetToolsAreVisibleAndLockedInCodeProfileLibraryView() {
        let presetNames = Set(CodeToolPreset.defaultTools.map(\.name))
        for name in presetNames {
            XCTAssertFalse(CodeToolPreset.hiddenToolNames.contains(name),
                           "\(name) is in defaultTools and must NOT be hidden from Library view in Code mode")
            XCTAssertTrue(CodeToolPreset.lockedToolNames.contains(name),
                          "\(name) is in defaultTools and must be marked as locked in Code mode")
        }
    }
}
