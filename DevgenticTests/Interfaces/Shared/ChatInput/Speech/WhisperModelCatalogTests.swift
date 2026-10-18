// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
//
//  WhisperModelCatalogTests.swift
//  DevgenticTests
//
//  Created by Raj Singh.
//

import XCTest
@testable import devgentic

final class WhisperModelCatalogTests: XCTestCase {

    // MARK: - Catalog Integrity

    func testCatalogIsNotEmpty() {
        XCTAssertFalse(WhisperModelCatalog.availableModels.isEmpty)
    }

    func testAllModelsHaveUniqueIDs() {
        let ids = WhisperModelCatalog.availableModels.map(\.id)
        let uniqueIDs = Set(ids)
        XCTAssertEqual(ids.count, uniqueIDs.count, "All model IDs must be unique")
    }

    func testAllModelsHaveNonEmptyDisplayNames() {
        for model in WhisperModelCatalog.availableModels {
            XCTAssertFalse(model.displayName.isEmpty, "Model \(model.id) has empty displayName")
        }
    }

    func testAllModelsHaveNonEmptySizeStrings() {
        for model in WhisperModelCatalog.availableModels {
            XCTAssertFalse(model.size.isEmpty, "Model \(model.id) has empty size")
        }
    }

    // MARK: - isEnglishOnly

    func testEnglishOnlyModelsDetected() {
        let englishModels = WhisperModelCatalog.availableModels.filter(\.isEnglishOnly)
        XCTAssertFalse(englishModels.isEmpty, "There should be at least one English-only model")
        for model in englishModels {
            XCTAssertTrue(model.id.hasSuffix(".en"), "\(model.id) should end in .en")
        }
    }

    func testMultilingualModelsDetected() {
        let multilingualModels = WhisperModelCatalog.availableModels.filter { !$0.isEnglishOnly }
        XCTAssertFalse(multilingualModels.isEmpty, "There should be at least one multilingual model")
        for model in multilingualModels {
            XCTAssertFalse(model.id.hasSuffix(".en"), "\(model.id) should NOT end in .en")
        }
    }

    // MARK: - Expected Models Present

    func testBaseEnModelExists() {
        let match = WhisperModelCatalog.availableModels.first { $0.id == "base.en" }
        XCTAssertNotNil(match, "base.en should be in catalog (it's the default)")
    }

    func testLargeV3ModelExists() {
        let match = WhisperModelCatalog.availableModels.first { $0.id == "large-v3" }
        XCTAssertNotNil(match, "large-v3 should be in catalog")
    }
}
