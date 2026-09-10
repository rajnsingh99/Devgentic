// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2026 Raj Singh
//
//  PPTXExtractorTests.swift
//  devgenticTests
//
//  Tier 1 + 2: PPTX extraction — XML parser unit tests + real fixture integration.
//

import XCTest
@testable import devgentic

final class PPTXExtractorTests: XCTestCase {

    private let extractor = PPTXExtractor()

    private func fixtureURL(_ name: String, ext: String) -> URL {
        let bundle = Bundle(for: type(of: self))
        guard let url = bundle.url(forResource: name, withExtension: ext) else {
            fatalError("Missing test fixture: \(name).\(ext)")
        }
        return url
    }

    // MARK: - Tier 1: XML Parser — Unit Tests

    func testXMLParser_SimpleSlideText() {
        let xml = """
        <?xml version="1.0" encoding="UTF-8"?>
        <p:sld xmlns:a="http://schemas.openxmlformats.org/drawingml/2006/main"
               xmlns:p="http://schemas.openxmlformats.org/presentationml/2006/main">
          <p:cSld><p:spTree><p:sp><p:txBody>
            <a:p><a:r><a:t>Slide Title</a:t></a:r></a:p>
          </p:txBody></p:sp></p:spTree></p:cSld>
        </p:sld>
        """
        let parser = PPTXSlideTextParser()
        let text = parser.extractText(from: xml.data(using: .utf8)!)

        XCTAssertTrue(text.contains("Slide Title"), "Should extract text from <a:t> elements")
    }

    func testXMLParser_MultipleTextRuns_Concatenated() {
        let xml = """
        <?xml version="1.0" encoding="UTF-8"?>
        <p:sld xmlns:a="http://schemas.openxmlformats.org/drawingml/2006/main"
               xmlns:p="http://schemas.openxmlformats.org/presentationml/2006/main">
          <p:cSld><p:spTree><p:sp><p:txBody>
            <a:p><a:r><a:t>Hello </a:t></a:r><a:r><a:t>World</a:t></a:r></a:p>
          </p:txBody></p:sp></p:spTree></p:cSld>
        </p:sld>
        """
        let parser = PPTXSlideTextParser()
        let text = parser.extractText(from: xml.data(using: .utf8)!)

        XCTAssertTrue(text.contains("Hello World"), "Multiple text runs should be concatenated")
    }

    func testXMLParser_ParagraphBoundaries_InsertNewlines() {
        let xml = """
        <?xml version="1.0" encoding="UTF-8"?>
        <p:sld xmlns:a="http://schemas.openxmlformats.org/drawingml/2006/main"
               xmlns:p="http://schemas.openxmlformats.org/presentationml/2006/main">
          <p:cSld><p:spTree><p:sp><p:txBody>
            <a:p><a:r><a:t>Line One</a:t></a:r></a:p>
            <a:p><a:r><a:t>Line Two</a:t></a:r></a:p>
          </p:txBody></p:sp></p:spTree></p:cSld>
        </p:sld>
        """
        let parser = PPTXSlideTextParser()
        let text = parser.extractText(from: xml.data(using: .utf8)!)

        XCTAssertTrue(text.contains("Line One"), "Should contain first paragraph")
        XCTAssertTrue(text.contains("Line Two"), "Should contain second paragraph")
        XCTAssertTrue(text.contains("\n"), "Paragraphs should be separated by newlines")
    }

    func testXMLParser_EmptySlide_ReturnsEmpty() {
        let xml = """
        <?xml version="1.0" encoding="UTF-8"?>
        <p:sld xmlns:a="http://schemas.openxmlformats.org/drawingml/2006/main"
               xmlns:p="http://schemas.openxmlformats.org/presentationml/2006/main">
          <p:cSld><p:spTree/></p:cSld>
        </p:sld>
        """
        let parser = PPTXSlideTextParser()
        let text = parser.extractText(from: xml.data(using: .utf8)!)

        XCTAssertTrue(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                      "Empty slide should produce empty text")
    }

    func testXMLParser_SpecialCharacters_Preserved() {
        let xml = """
        <?xml version="1.0" encoding="UTF-8"?>
        <p:sld xmlns:a="http://schemas.openxmlformats.org/drawingml/2006/main"
               xmlns:p="http://schemas.openxmlformats.org/presentationml/2006/main">
          <p:cSld><p:spTree><p:sp><p:txBody>
            <a:p><a:r><a:t>Price: $100 &amp; Tax: 10%</a:t></a:r></a:p>
          </p:txBody></p:sp></p:spTree></p:cSld>
        </p:sld>
        """
        let parser = PPTXSlideTextParser()
        let text = parser.extractText(from: xml.data(using: .utf8)!)

        XCTAssertTrue(text.contains("$100"), "Should preserve dollar signs")
        XCTAssertTrue(text.contains("&"), "Should decode XML entities")
        XCTAssertTrue(text.contains("10%"), "Should preserve percent signs")
    }

    // MARK: - Tier 1: Real Fixture — Full Pipeline

    func testExtract_SamplePPTX_ReturnsContent() async throws {
        let url = fixtureURL("sample", ext: "pptx")
        let result = try await extractor.extract(from: url, maxSize: 500_000)

        XCTAssertFalse(result.text.isEmpty, "Should extract text from sample.pptx")
        XCTAssertEqual(result.metadata.format, "pptx")
        XCTAssertEqual(result.metadata.extractionMethod, "unzip-xml")
    }

    func testExtract_SamplePPTX_ReportsSlideCount() async throws {
        let url = fixtureURL("sample", ext: "pptx")
        let result = try await extractor.extract(from: url, maxSize: 500_000)

        XCTAssertNotNil(result.metadata.pageCount, "Should report slide count")
        XCTAssertGreaterThan(result.metadata.pageCount ?? 0, 0,
                             "sample.pptx should have at least 1 slide")
    }

    func testExtract_SamplePPTX_ContainsSlideHeaders() async throws {
        let url = fixtureURL("sample", ext: "pptx")
        let result = try await extractor.extract(from: url, maxSize: 500_000)

        XCTAssertTrue(result.text.contains("## Slide"),
                      "Output should contain '## Slide' markdown headers for each slide")
    }

    // MARK: - Tier 2: Error Handling

    func testExtract_CorruptedFile_ThrowsError() async {
        let tempURL = FileManager.default.temporaryDirectory.appendingPathComponent("bad_\(UUID()).pptx")
        try! "not a real pptx".data(using: .utf8)!.write(to: tempURL)
        defer { try? FileManager.default.removeItem(at: tempURL) }

        do {
            _ = try await extractor.extract(from: tempURL, maxSize: 500_000)
            XCTFail("Should throw for corrupted file")
        } catch {
            // Expected — corruptedFile or Process error
        }
    }
}
