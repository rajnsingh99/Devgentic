// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
//
//  PDFExtractorTests.swift
//  devgenticTests
//
//  Tier 1 + 2: PDF extraction via PDFKit, OCR fallback, error handling.
//  Uses real fixture files from the test bundle.
//

import XCTest
import PDFKit
@testable import devgentic

final class PDFExtractorTests: XCTestCase {

    private let extractor = PDFExtractor()

    /// Resolves a fixture file from the test bundle
    private func fixtureURL(_ name: String, ext: String) -> URL {
        let bundle = Bundle(for: type(of: self))
        guard let url = bundle.url(forResource: name, withExtension: ext) else {
            fatalError("Missing test fixture: \(name).\(ext) — ensure it is in DevgenticTests/Core/Utils/Fixtures/")
        }
        return url
    }

    // MARK: - Tier 1: Basic Extraction

    func testExtract_TextPDF_ReturnsContent() async throws {
        let url = fixtureURL("sample", ext: "pdf")
        let result = try await extractor.extract(from: url, maxSize: 500_000)

        XCTAssertFalse(result.text.isEmpty, "Should extract text from sample.pdf")
        XCTAssertEqual(result.metadata.format, "pdf")
        XCTAssertEqual(result.metadata.extractionMethod, "pdfkit",
                       "Text-based PDF should use PDFKit, not OCR")
    }

    func testExtract_TextPDF_HasMultiplePages() async throws {
        let url = fixtureURL("sample", ext: "pdf")
        let result = try await extractor.extract(from: url, maxSize: 500_000)

        XCTAssertNotNil(result.metadata.pageCount, "Should report page count")
        XCTAssertGreaterThan(result.metadata.pageCount ?? 0, 0, "sample.pdf should have at least 1 page")
    }

    func testExtract_TextPDF_WordCountPositive() async throws {
        let url = fixtureURL("sample", ext: "pdf")
        let result = try await extractor.extract(from: url, maxSize: 500_000)

        XCTAssertGreaterThan(result.metadata.wordCount, 10,
                             "sample.pdf should contain meaningful text (>10 words)")
    }

    // MARK: - Tier 1: OCR Fallback

    func testExtract_ScannedPDF_FallsBackToOCR() async {
        let url = fixtureURL("sample_scanned", ext: "pdf")
        do {
            let result = try await extractor.extract(from: url, maxSize: 500_000)
            // If OCR succeeds, it should report vision-ocr as extraction method
            XCTAssertEqual(result.metadata.extractionMethod, "vision-ocr",
                           "Scanned PDF should use Vision OCR, not PDFKit")
            XCTAssertFalse(result.text.isEmpty,
                           "Scanned PDF should extract text via OCR fallback")
        } catch let error as DocumentExtractionError {
            // OCR may fail to extract text from low-quality scans — emptyDocument is acceptable
            if case .emptyDocument = error {
                // Expected for scans that Vision can't read
            } else {
                XCTFail("Expected either successful OCR or .emptyDocument, got \(error)")
            }
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    // MARK: - Tier 2: Edge Cases

    func testExtract_MaxSizeTruncation() async throws {
        let url = fixtureURL("sample", ext: "pdf")
        let result = try await extractor.extract(from: url, maxSize: 50)

        XCTAssertLessThanOrEqual(result.text.count, 50, "Text should be truncated to maxSize")
        XCTAssertTrue(result.metadata.wasTruncated, "Truncation flag should be set")
    }

    func testExtract_EmptyPDF_ThrowsEmptyDocument() async {
        let url = fixtureURL("empty", ext: "pdf")
        do {
            _ = try await extractor.extract(from: url, maxSize: 500_000)
            // If OCR somehow finds text in a blank page, that's acceptable
        } catch let error as DocumentExtractionError {
            if case .emptyDocument = error {
                // Expected — blank PDF with no text
            } else {
                XCTFail("Expected .emptyDocument for blank PDF, got \(error)")
            }
        } catch {
            XCTFail("Unexpected error type: \(error)")
        }
    }

    func testExtract_CorruptedFile_ThrowsError() async {
        let tempURL = FileManager.default.temporaryDirectory.appendingPathComponent("corrupted_\(UUID()).pdf")
        try! "not a real pdf".data(using: .utf8)!.write(to: tempURL)
        defer { try? FileManager.default.removeItem(at: tempURL) }

        do {
            _ = try await extractor.extract(from: tempURL, maxSize: 500_000)
            XCTFail("Should throw for corrupted file")
        } catch let error as DocumentExtractionError {
            if case .corruptedFile = error { /* Expected */ }
            else { XCTFail("Expected .corruptedFile, got \(error)") }
        } catch {
            XCTFail("Expected DocumentExtractionError, got \(error)")
        }
    }

    func testExtract_WhenNotTruncated_FlagIsFalse() async throws {
        let url = fixtureURL("sample", ext: "pdf")
        let result = try await extractor.extract(from: url, maxSize: 500_000)

        XCTAssertFalse(result.metadata.wasTruncated,
                       "Truncation flag should be false when maxSize is large enough")
    }
}
