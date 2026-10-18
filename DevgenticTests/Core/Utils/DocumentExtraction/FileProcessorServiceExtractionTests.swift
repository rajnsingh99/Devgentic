// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
//
//  FileProcessorServiceExtractionTests.swift
//  DevgenticTests
//
//  Created by Raj Singh.
//

import XCTest
@testable import devgentic

final class FileProcessorServiceExtractionTests: XCTestCase {

    private let service = FileProcessorService()

    // MARK: - Tier 2: isTextFile — New Document Formats

    func testIsTextFile_DOCX_ReturnsTrue() {
        let url = URL(fileURLWithPath: "/tmp/report.docx")
        let mime = service.getFileMimeType(for: url)
        XCTAssertTrue(service.isTextFile(mimeType: mime, url: url),
                      "DOCX files should be recognized as text-extractable")
    }

    func testIsTextFile_XLSX_ReturnsTrue() {
        let url = URL(fileURLWithPath: "/tmp/data.xlsx")
        let mime = service.getFileMimeType(for: url)
        XCTAssertTrue(service.isTextFile(mimeType: mime, url: url),
                      "XLSX files should be recognized as text-extractable")
    }

    func testIsTextFile_CSV_ReturnsTrue() {
        let url = URL(fileURLWithPath: "/tmp/data.csv")
        let mime = service.getFileMimeType(for: url)
        XCTAssertTrue(service.isTextFile(mimeType: mime, url: url),
                      "CSV files should be recognized as text-extractable")
    }

    func testIsTextFile_PPTX_ReturnsTrue() {
        let url = URL(fileURLWithPath: "/tmp/slides.pptx")
        let mime = service.getFileMimeType(for: url)
        XCTAssertTrue(service.isTextFile(mimeType: mime, url: url),
                      "PPTX files should be recognized as text-extractable")
    }

    func testIsTextFile_RTF_ReturnsTrue() {
        let url = URL(fileURLWithPath: "/tmp/note.rtf")
        let mime = service.getFileMimeType(for: url)
        XCTAssertTrue(service.isTextFile(mimeType: mime, url: url),
                      "RTF files should be recognized as text-extractable")
    }

    // MARK: - Tier 2: extractionInfo

    func testExtractionInfo_PDF_ReportsFormat() {
        let url = URL(fileURLWithPath: "/tmp/report.pdf")
        let info = service.extractionInfo(for: url)
        XCTAssertTrue(info.canExtract, "PDF should be extractable")
        XCTAssertEqual(info.format, "PDF", "Format should be reported as 'PDF'")
    }

    func testExtractionInfo_DOCX_ReportsFormat() {
        let url = URL(fileURLWithPath: "/tmp/report.docx")
        let info = service.extractionInfo(for: url)
        XCTAssertTrue(info.canExtract, "DOCX should be extractable")
        XCTAssertEqual(info.format, "DOCX", "Format should be reported as 'DOCX'")
    }

    func testExtractionInfo_Unknown_ReturnsCannotExtract() {
        let url = URL(fileURLWithPath: "/tmp/video.mp4")
        let info = service.extractionInfo(for: url)
        XCTAssertFalse(info.canExtract, "MP4 should not be extractable")
        XCTAssertNil(info.format, "Format should be nil for non-extractable files")
    }

    func testExtractionInfo_PlainText_ReportsText() {
        let url = URL(fileURLWithPath: "/tmp/readme.md")
        let info = service.extractionInfo(for: url)
        XCTAssertTrue(info.canExtract, "Markdown should be extractable as text")
        XCTAssertEqual(info.format, "Text", "Format should be 'Text' for plain text files")
    }
}
