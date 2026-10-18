// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
//
//  TestRepositorySource.swift
//  DevgenticTests
//
//  Created by Raj Singh.
//

import Foundation
import XCTest

enum TestRepositorySource {

    /// The checkout root, found by walking up from this file to `Devgentic.xcodeproj`.
    static func root() throws -> URL {
        var dir = URL(fileURLWithPath: #filePath)
        while dir.path != "/" {
            dir.deleteLastPathComponent()
            if FileManager.default.fileExists(atPath: dir.appendingPathComponent("Devgentic.xcodeproj").path) {
                return dir
            }
        }
        throw XCTSkip("repository root not found above \(#filePath)")
    }

    /// The text of a source file, by path relative to the checkout root.
    static func read(_ relativePath: String) throws -> String {
        try String(contentsOf: root().appendingPathComponent(relativePath), encoding: .utf8)
    }
}
