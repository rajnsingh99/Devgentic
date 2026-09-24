// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
//
//  DOCXExtractorTests.swift
//  devgenticTests
//
//  Tier 1 + 2: DOCX extraction — XML parser unit tests + real fixture integration.
//

import XCTest
@testable import devgentic

final class DOCXExtractorTests: XCTestCase {

    private let extractor = DOCXExtractor()

    /// ⚠️ Shared loader — see `TestFixtures`. This was a local `fatalError`, which kills the
    /// TEST HOST and so ended the whole run on one absent resource. It now skips this test
    /// alone; `FixtureAvailabilityTests` is what fails when a fixture is genuinely missing.
    private func fixtureURL(_ name: String, ext: String) throws -> URL {
        try TestFixtures.url(name, ext: ext, in: self)
    }

    // MARK: - Tier 1: XML Parser — Unit Tests (No File I/O)

    func testXMLParser_SimpleText_ExtractsCorrectly() {
        let xml = """
        <?xml version="1.0" encoding="UTF-8"?>
        <w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">
          <w:body>
            <w:p><w:r><w:t>Hello World</w:t></w:r></w:p>
          </w:body>
        </w:document>
        """
        let parser = DOCXXMLTextParser()
        let text = parser.extractText(from: xml.data(using: .utf8)!, maxSize: 10000)

        XCTAssertEqual(text.trimmingCharacters(in: .whitespacesAndNewlines), "Hello World",
                       "Should extract text from <w:t> elements")
    }

    func testXMLParser_MultipleParagraphs_InsertsNewlines() {
        let xml = """
        <?xml version="1.0" encoding="UTF-8"?>
        <w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">
          <w:body>
            <w:p><w:r><w:t>First paragraph</w:t></w:r></w:p>
            <w:p><w:r><w:t>Second paragraph</w:t></w:r></w:p>
          </w:body>
        </w:document>
        """
        let parser = DOCXXMLTextParser()
        let text = parser.extractText(from: xml.data(using: .utf8)!, maxSize: 10000)

        XCTAssertTrue(text.contains("First paragraph"), "Should contain first paragraph")
        XCTAssertTrue(text.contains("Second paragraph"), "Should contain second paragraph")
        XCTAssertTrue(text.contains("\n"), "Paragraphs should be separated by newlines")
    }

    func testXMLParser_MultipleRuns_Concatenated() {
        let xml = """
        <?xml version="1.0" encoding="UTF-8"?>
        <w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">
          <w:body>
            <w:p>
              <w:r><w:t>Hello </w:t></w:r>
              <w:r><w:rPr><w:b/></w:rPr><w:t>Bold</w:t></w:r>
              <w:r><w:t> World</w:t></w:r>
            </w:p>
          </w:body>
        </w:document>
        """
        let parser = DOCXXMLTextParser()
        let text = parser.extractText(from: xml.data(using: .utf8)!, maxSize: 10000)

        XCTAssertTrue(text.contains("Hello "), "Should contain first run")
        XCTAssertTrue(text.contains("Bold"), "Should contain bold run")
        XCTAssertTrue(text.contains(" World"), "Should contain last run")
    }

    func testXMLParser_MaxSizeTruncation() {
        let longContent = String(repeating: "word ", count: 500)
        let xml = """
        <?xml version="1.0" encoding="UTF-8"?>
        <w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">
          <w:body><w:p><w:r><w:t>\(longContent)</w:t></w:r></w:p></w:body>
        </w:document>
        """
        let parser = DOCXXMLTextParser()
        let text = parser.extractText(from: xml.data(using: .utf8)!, maxSize: 100)

        XCTAssertLessThanOrEqual(text.count, 100, "Should truncate at maxSize")
    }

    func testXMLParser_EmptyBody_ReturnsEmpty() {
        let xml = """
        <?xml version="1.0" encoding="UTF-8"?>
        <w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">
          <w:body/>
        </w:document>
        """
        let parser = DOCXXMLTextParser()
        let text = parser.extractText(from: xml.data(using: .utf8)!, maxSize: 10000)

        XCTAssertTrue(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                      "Empty document body should produce empty text")
    }

    func testXMLParser_Unicode_PreservedCorrectly() {
        let xml = """
        <?xml version="1.0" encoding="UTF-8"?>
        <w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">
          <w:body><w:p><w:r><w:t>Caf\u{00E9} R\u{00E9}sum\u{00E9}</w:t></w:r></w:p></w:body>
        </w:document>
        """
        let parser = DOCXXMLTextParser()
        let text = parser.extractText(from: xml.data(using: .utf8)!, maxSize: 10000)

        XCTAssertTrue(text.contains("Caf\u{00E9}"), "Should preserve Unicode characters")
    }

    // MARK: - Tier 1: Real Fixture — Full Pipeline

    func testExtract_SampleDOCX_ReturnsContent() async throws {
        let url = try fixtureURL("sample", ext: "docx")
        let result = try await extractor.extract(from: url, maxSize: 500_000)

        XCTAssertFalse(result.text.isEmpty, "Should extract text from sample.docx")
        XCTAssertEqual(result.metadata.format, "docx")
        XCTAssertEqual(result.metadata.extractionMethod, "unzip-xml")
        XCTAssertGreaterThan(result.metadata.wordCount, 0, "Should contain words")
    }

    // MARK: - Tier 2: Error Handling

    func testExtract_CorruptedFile_ThrowsError() async {
        let tempURL = FileManager.default.temporaryDirectory.appendingPathComponent("bad_\(UUID()).docx")
        try! "not a real docx".data(using: .utf8)!.write(to: tempURL)
        defer { try? FileManager.default.removeItem(at: tempURL) }

        do {
            _ = try await extractor.extract(from: tempURL, maxSize: 500_000)
            XCTFail("Should throw for corrupted file")
        } catch let error as DocumentExtractionError {
            if case .corruptedFile = error { /* Expected */ }
            else { XCTFail("Expected .corruptedFile, got \(error)") }
        } catch {
            // Process launch errors also acceptable for invalid zips
        }
    }
}
