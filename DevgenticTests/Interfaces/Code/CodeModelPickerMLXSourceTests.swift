// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
//
//  CodeModelPickerMLXSourceTests.swift
//  DevgenticTests
//
//  The Code picker's MLX tab (2026-09-27). It scanned `~/.cache/huggingface/hub` — not the app's
//  MLX model store — so it listed a stray embedding model and none of the installed chat models,
//  and saved names the runtime (which resolves against the store) could not load.
//

import XCTest
@testable import devgentic

final class CodeModelPickerMLXSourceTests: XCTestCase {

    private func source() throws -> String {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let path = "Devgentic/Interfaces/Code/CodeModelPickerButton.swift"
        guard let text = try? String(contentsOf: root.appendingPathComponent(path), encoding: .utf8) else {
            throw XCTSkip("\(path) not reachable — running outside a checkout")
        }
        return text.components(separatedBy: "\n")
            .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
            .joined(separator: "\n")
    }

    func testTheMLXTabListsTheModelStore() throws {
        let code = try source()
        XCTAssertTrue(code.contains("localModels = await listInstalledMLXModels()"), "the MLX tab is not wired to the store listing")
        XCTAssertTrue(code.contains("service.installedModels.map"), "the MLX tab does not read the model store")
        XCTAssertTrue(code.contains("name: model.displayName"),
                      "the saved name is not the store's canonical id, so the runtime cannot resolve it")
        XCTAssertFalse(code.contains(".cache/huggingface/hub\")"),
                       "the picker scans the generic HuggingFace cache again, not the app's model store")
    }
}
