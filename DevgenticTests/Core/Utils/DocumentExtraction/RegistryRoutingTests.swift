// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
//
//  RegistryRoutingTests.swift
//  devgenticTests
//
//  Tier 1 + 2: Registry dispatches to correct extractor, error handling.
//

import XCTest
@testable import devgentic

final class RegistryRoutingTests: XCTestCase {

    private let registry = DocumentExtractionRegistry.shared

    // MARK: - Tier 1: canExtract Routing

    func testCanExtract_PDF() {
        let url = URL(fileURLWithPath: "/tmp/test.pdf")
        XCTAssertTrue(registry.canExtract(from: url), "Registry should support PDF")
    }

    func testCanExtract_DOCX() {
        let url = URL(fileURLWithPath: "/tmp/test.docx")
        XCTAssertTrue(registry.canExtract(from: url), "Registry should support DOCX")
    }

    func testCanExtract_XLSX() {
        let url = URL(fileURLWithPath: "/tmp/test.xlsx")
        XCTAssertTrue(registry.canExtract(from: url), "Registry should support XLSX")
    }

    func testCanExtract_CSV() {
        let url = URL(fileURLWithPath: "/tmp/test.csv")
        XCTAssertTrue(registry.canExtract(from: url), "Registry should support CSV")
    }

    func testCanExtract_TSV() {
        let url = URL(fileURLWithPath: "/tmp/test.tsv")
        XCTAssertTrue(registry.canExtract(from: url), "Registry should support TSV")
    }

    func testCanExtract_PPTX() {
        let url = URL(fileURLWithPath: "/tmp/test.pptx")
        XCTAssertTrue(registry.canExtract(from: url), "Registry should support PPTX")
    }

    func testCanExtract_RTF() {
        let url = URL(fileURLWithPath: "/tmp/test.rtf")
        XCTAssertTrue(registry.canExtract(from: url), "Registry should support RTF")
    }

    // MARK: - Tier 1: Unsupported Formats

    func testCanExtract_UnsupportedFormats_ReturnFalse() {
        let unsupported = ["png", "mp4", "zip", "exe", "dmg", "mov"]
        for ext in unsupported {
            let url = URL(fileURLWithPath: "/tmp/file.\(ext)")
            XCTAssertFalse(registry.canExtract(from: url), "Registry should NOT support .\(ext)")
        }
    }

    // MARK: - Tier 1: Supported Extensions Set

    func testAllSupportedExtensions_ContainsExpected() {
        let extensions = registry.allSupportedExtensions
        let expected: Set<String> = ["pdf", "docx", "xlsx", "xls", "csv", "tsv", "pptx", "rtf", "rtfd"]
        for ext in expected {
            XCTAssertTrue(extensions.contains(ext), "allSupportedExtensions should include '\(ext)'")
        }
    }

    func testSupportedFormatDescriptions_NonEmpty() {
        XCTAssertFalse(registry.supportedFormatDescriptions.isEmpty,
                       "supportedFormatDescriptions should list human-readable format names")
        XCTAssertTrue(registry.supportedFormatDescriptions.count >= 6,
                      "Should describe at least 6 format categories")
    }

    // MARK: - Tier 2: Extract Errors

    func testExtract_UnsupportedFormat_ThrowsError() async {
        let url = URL(fileURLWithPath: "/tmp/photo.png")
        do {
            _ = try await registry.extract(from: url)
            XCTFail("Should throw for unsupported format")
        } catch let error as DocumentExtractionError {
            if case .unsupportedFormat = error {
                // Expected
            } else {
                XCTFail("Expected .unsupportedFormat, got \(error)")
            }
        } catch {
            XCTFail("Expected DocumentExtractionError, got \(error)")
        }
    }
}
