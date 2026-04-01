//
//  DocumentExtractorProtocolTests.swift
//  devgenticTests
//
//  Tier 1: Protocol conformance, canExtract routing, error types.
//

import XCTest
import UniformTypeIdentifiers
@testable import devgentic

final class DocumentExtractorProtocolTests: XCTestCase {

    // MARK: - Tier 1: canExtract Routing

    func testCanExtract_ByExtension_PDF() {
        let extractor = PDFExtractor()
        let url = URL(fileURLWithPath: "/tmp/report.pdf")
        XCTAssertTrue(extractor.canExtract(from: url), "PDFExtractor should recognize .pdf extension")
    }

    func testCanExtract_ByExtension_CaseInsensitive() {
        let extractor = CSVExtractor()
        let url = URL(fileURLWithPath: "/tmp/data.CSV")
        // pathExtension returns "CSV", lowercased in canExtract → "csv"
        XCTAssertTrue(extractor.canExtract(from: url), "CSVExtractor should handle uppercase .CSV extension")
    }

    func testCanExtract_UnknownExtension_ReturnsFalse() {
        let extractor = PDFExtractor()
        let url = URL(fileURLWithPath: "/tmp/photo.png")
        XCTAssertFalse(extractor.canExtract(from: url), "PDFExtractor should not claim .png files")
    }

    func testSupportedExtensions_AllExtractorsNonEmpty() {
        let extractors: [any DocumentExtractor] = [
            PDFExtractor(), DOCXExtractor(), XLSXExtractor(),
            CSVExtractor(), PPTXExtractor(), RTFExtractor()
        ]
        for extractor in extractors {
            XCTAssertFalse(extractor.supportedExtensions.isEmpty,
                           "\(type(of: extractor)) should declare at least one supported extension")
        }
    }

    // MARK: - Tier 1: Error Descriptions

    func testExtractionError_AllCases_HaveDescriptions() {
        let errors: [DocumentExtractionError] = [
            .unsupportedFormat("xyz"),
            .fileNotFound("/tmp/missing.pdf"),
            .extractionFailed("pdf", underlying: nil),
            .passwordProtected("/tmp/locked.pdf"),
            .corruptedFile("/tmp/broken.docx"),
            .emptyDocument("/tmp/blank.pdf")
        ]

        for error in errors {
            XCTAssertNotNil(error.errorDescription, "\(error) should have a non-nil errorDescription")
            XCTAssertFalse(error.errorDescription!.isEmpty, "\(error) should have a non-empty errorDescription")
        }
    }
}
