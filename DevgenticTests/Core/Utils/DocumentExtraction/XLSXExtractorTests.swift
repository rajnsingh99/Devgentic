// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2026 Raj Singh
//
//  XLSXExtractorTests.swift
//  devgenticTests
//
//  Tier 1 + 2: XLSX extraction via CoreXLSX with real fixture file.
//

import XCTest
@testable import devgentic

final class XLSXExtractorTests: XCTestCase {

    private let extractor = XLSXExtractor()

    private func fixtureURL(_ name: String, ext: String) -> URL {
        let bundle = Bundle(for: type(of: self))
        guard let url = bundle.url(forResource: name, withExtension: ext) else {
            fatalError("Missing test fixture: \(name).\(ext)")
        }
        return url
    }

    // MARK: - Tier 1: Routing

    func testCanExtract_XLSXExtension() {
        let url = URL(fileURLWithPath: "/tmp/spreadsheet.xlsx")
        XCTAssertTrue(extractor.canExtract(from: url), "Should recognize .xlsx extension")
    }

    func testCanExtract_XLSExtension() {
        let url = URL(fileURLWithPath: "/tmp/legacy.xls")
        XCTAssertTrue(extractor.canExtract(from: url), "Should recognize .xls extension")
    }

    func testCanExtract_NonSpreadsheet_ReturnsFalse() {
        let url = URL(fileURLWithPath: "/tmp/document.pdf")
        XCTAssertFalse(extractor.canExtract(from: url), "Should not claim PDF files")
    }

    // MARK: - Tier 1: Real Fixture Extraction

    func testExtract_SampleXLSX_ReturnsContent() async throws {
        let url = fixtureURL("sample", ext: "xlsx")
        let result = try await extractor.extract(from: url, maxSize: 500_000)

        XCTAssertFalse(result.text.isEmpty, "Should extract text from sample.xlsx")
        XCTAssertEqual(result.metadata.format, "xlsx")
        XCTAssertEqual(result.metadata.extractionMethod, "corexlsx")
    }

    func testExtract_SampleXLSX_ProducesMarkdownTable() async throws {
        let url = fixtureURL("sample", ext: "xlsx")
        let result = try await extractor.extract(from: url, maxSize: 500_000)

        XCTAssertTrue(result.text.contains("|"), "Output should contain markdown table pipe characters")
        XCTAssertTrue(result.text.contains("---"), "Output should contain markdown table header separator")
    }

    func testExtract_SampleXLSX_ReportsSheetNames() async throws {
        let url = fixtureURL("sample", ext: "xlsx")
        let result = try await extractor.extract(from: url, maxSize: 500_000)

        XCTAssertNotNil(result.metadata.sheetNames, "Should report sheet names")
        XCTAssertFalse(result.metadata.sheetNames?.isEmpty ?? true, "Should have at least one sheet")
    }

    func testExtract_SampleXLSX_WordCountPositive() async throws {
        let url = fixtureURL("sample", ext: "xlsx")
        let result = try await extractor.extract(from: url, maxSize: 500_000)

        XCTAssertGreaterThan(result.metadata.wordCount, 0, "Should have positive word count")
    }

    // MARK: - Tier 2: Error Handling

    func testExtract_InvalidFile_ThrowsCorrupted() async {
        let tempURL = FileManager.default.temporaryDirectory.appendingPathComponent("fake_\(UUID()).xlsx")
        try! "not a real xlsx".data(using: .utf8)!.write(to: tempURL)
        defer { try? FileManager.default.removeItem(at: tempURL) }

        do {
            _ = try await extractor.extract(from: tempURL, maxSize: 500_000)
            XCTFail("Should throw for invalid XLSX content")
        } catch let error as DocumentExtractionError {
            if case .corruptedFile = error { /* Expected */ }
            else { XCTFail("Expected .corruptedFile, got \(error)") }
        } catch {
            // Other errors acceptable for invalid files
        }
    }

    func testExtract_MaxSizeTruncation() async throws {
        let url = fixtureURL("sample", ext: "xlsx")
        let result = try await extractor.extract(from: url, maxSize: 50)

        XCTAssertLessThanOrEqual(result.text.count, 50, "Should truncate at maxSize")
        XCTAssertTrue(result.metadata.wasTruncated, "Truncation flag should be set")
    }
}
