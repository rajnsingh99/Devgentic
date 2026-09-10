// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2026 Raj Singh
//
//  RTFExtractorTests.swift
//  devgenticTests
//
//  Tier 1 + 2: RTF extraction via NSAttributedString — real fixture + programmatic tests.
//

import XCTest
@testable import devgentic

final class RTFExtractorTests: XCTestCase {

    private let extractor = RTFExtractor()
    private var tempDir: URL!

    override func setUp() async throws {
        tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: tempDir)
    }

    private func fixtureURL(_ name: String, ext: String) -> URL {
        let bundle = Bundle(for: type(of: self))
        guard let url = bundle.url(forResource: name, withExtension: ext) else {
            fatalError("Missing test fixture: \(name).\(ext)")
        }
        return url
    }

    private func makeTempRTF(_ text: String, bold: Bool = false) -> URL {
        let attrString: NSAttributedString
        if bold {
            attrString = NSAttributedString(string: text, attributes: [.font: NSFont.boldSystemFont(ofSize: 14)])
        } else {
            attrString = NSAttributedString(string: text)
        }
        let rtfData = attrString.rtf(from: NSRange(location: 0, length: attrString.length))!
        let url = tempDir.appendingPathComponent("test.rtf")
        try! rtfData.write(to: url)
        return url
    }

    // MARK: - Tier 1: Real Fixture

    func testExtract_SampleRTF_ReturnsContent() async throws {
        let url = fixtureURL("sample", ext: "rtf")
        let result = try await extractor.extract(from: url, maxSize: 500_000)

        XCTAssertFalse(result.text.isEmpty, "Should extract text from sample.rtf")
        XCTAssertEqual(result.metadata.format, "rtf")
        XCTAssertEqual(result.metadata.extractionMethod, "nsattributedstring")
        XCTAssertGreaterThan(result.metadata.wordCount, 0, "Should have positive word count")
    }

    // MARK: - Tier 1: Programmatic Tests

    func testExtract_SimpleRTF_ReturnsText() async throws {
        let url = makeTempRTF("Hello RTF World")
        let result = try await extractor.extract(from: url, maxSize: 500_000)

        XCTAssertTrue(result.text.contains("Hello RTF World"), "Should extract plain text from RTF")
    }

    func testExtract_FormattedRTF_StripsFormatting() async throws {
        let url = makeTempRTF("Bold Text Here", bold: true)
        let result = try await extractor.extract(from: url, maxSize: 500_000)

        XCTAssertTrue(result.text.contains("Bold Text Here"),
                      "Should extract text regardless of formatting")
    }

    // MARK: - Tier 2: Edge Cases

    func testExtract_MaxSizeTruncation() async throws {
        let longText = String(repeating: "RTF content here. ", count: 100)
        let url = makeTempRTF(longText)
        let result = try await extractor.extract(from: url, maxSize: 50)

        XCTAssertLessThanOrEqual(result.text.count, 50, "Should truncate at maxSize")
        XCTAssertTrue(result.metadata.wasTruncated, "Truncation flag should be set")
    }

    func testExtract_InvalidRTFData_ThrowsError() async {
        let url = tempDir.appendingPathComponent("invalid.rtf")
        try! "not valid rtf data at all".data(using: .utf8)!.write(to: url)

        do {
            _ = try await extractor.extract(from: url, maxSize: 500_000)
            XCTFail("Should throw for invalid RTF data")
        } catch {
            // Expected — extractionFailed or emptyDocument
        }
    }

    func testMetadata_WordCount_IsPositive() async throws {
        let url = makeTempRTF("One two three four five")
        let result = try await extractor.extract(from: url, maxSize: 500_000)

        XCTAssertGreaterThanOrEqual(result.metadata.wordCount, 5, "Should count words accurately")
    }
}
