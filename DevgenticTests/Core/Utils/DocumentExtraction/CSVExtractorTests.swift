//
//  CSVExtractorTests.swift
//  devgenticTests
//
//  Tier 1 + 2: CSV/TSV parsing with real fixture + programmatic edge cases.
//

import XCTest
@testable import devgentic

final class CSVExtractorTests: XCTestCase {

    private let extractor = CSVExtractor()
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

    private func makeTempCSV(_ content: String, ext: String = "csv") -> URL {
        let url = tempDir.appendingPathComponent("test.\(ext)")
        try! content.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    // MARK: - Tier 1: Real Fixture

    func testExtract_SampleCSV_ReturnsMarkdownTable() async throws {
        let url = fixtureURL("sample", ext: "csv")
        let result = try await extractor.extract(from: url, maxSize: 500_000)

        XCTAssertFalse(result.text.isEmpty, "Should extract content from sample.csv")
        XCTAssertTrue(result.text.contains("|"), "Should produce markdown table with pipe characters")
        XCTAssertTrue(result.text.contains("---"), "Should include header separator")
        XCTAssertEqual(result.metadata.format, "csv")
        XCTAssertEqual(result.metadata.extractionMethod, "native-csv")
    }

    // MARK: - Tier 1: Programmatic Tests

    func testExtract_SimpleCSV_FormatsCorrectly() async throws {
        let csv = "Name,Age,City\nAlice,30,London\nBob,25,Paris"
        let url = makeTempCSV(csv)
        let result = try await extractor.extract(from: url, maxSize: 500_000)

        XCTAssertTrue(result.text.contains("| Name"), "Should have header row")
        XCTAssertTrue(result.text.contains("| ---"), "Should have separator row")
        XCTAssertTrue(result.text.contains("Alice"), "Should include data values")
        XCTAssertTrue(result.text.contains("Bob"), "Should include all rows")
    }

    func testExtract_TSVFile_UsesTabDelimiter() async throws {
        let tsv = "Name\tAge\nAlice\t30\nBob\t25"
        let url = makeTempCSV(tsv, ext: "tsv")
        let result = try await extractor.extract(from: url, maxSize: 500_000)

        XCTAssertTrue(result.text.contains("| Name"), "Should produce markdown table from TSV")
        XCTAssertTrue(result.text.contains("Alice"), "Should parse tab-delimited values")
        XCTAssertEqual(result.metadata.format, "tsv")
    }

    func testExtract_QuotedFields_HandlesCommasInValues() async throws {
        let csv = "Name,Description\n\"Smith, John\",\"Age: 30, City: NYC\""
        let url = makeTempCSV(csv)
        let result = try await extractor.extract(from: url, maxSize: 500_000)

        XCTAssertTrue(result.text.contains("Smith, John"), "Should preserve commas inside quoted fields")
    }

    // MARK: - Tier 2: Edge Cases

    func testExtract_QuotedFieldsWithEscapedQuotes() async throws {
        let csv = "Quote\n\"She said \"\"hello\"\"\""
        let url = makeTempCSV(csv)
        let result = try await extractor.extract(from: url, maxSize: 500_000)

        XCTAssertTrue(result.text.contains("hello"), "Should handle escaped quotes within quoted fields")
    }

    func testExtract_MixedLineEndings_CRLF() async throws {
        // Write raw bytes to preserve \r\n
        let csvBytes: [UInt8] = Array("A,B\r\n1,2\r\n3,4".utf8)
        let url = tempDir.appendingPathComponent("crlf_test.csv")
        try Data(csvBytes).write(to: url)

        let result = try await extractor.extract(from: url, maxSize: 500_000)

        XCTAssertTrue(result.text.contains("| A"), "Header row should be present")
        XCTAssertTrue(result.text.contains("1"), "First data row should be present")
        XCTAssertTrue(result.text.contains("3"), "Second data row should be present")
    }

    func testExtract_EmptyCSV_ThrowsEmptyDocument() async {
        let url = makeTempCSV("")
        do {
            _ = try await extractor.extract(from: url, maxSize: 500_000)
            XCTFail("Should throw for empty CSV")
        } catch let error as DocumentExtractionError {
            if case .emptyDocument = error { /* Expected */ }
            else { XCTFail("Expected .emptyDocument, got \(error)") }
        } catch {
            XCTFail("Expected DocumentExtractionError, got \(error)")
        }
    }

    func testExtract_MaxSizeTruncation() async throws {
        var csv = "Col1,Col2\n"
        for i in 0..<100 { csv += "value_\(i),data_\(i)\n" }
        let url = makeTempCSV(csv)
        let result = try await extractor.extract(from: url, maxSize: 200)

        XCTAssertLessThanOrEqual(result.text.count, 200, "Should truncate at maxSize")
        XCTAssertTrue(result.metadata.wasTruncated, "Truncation flag should be set")
    }

    func testExtract_PipeInCells_Escaped() async throws {
        let csv = "Expression,Result\na | b,true\nx || y,false"
        let url = makeTempCSV(csv)
        let result = try await extractor.extract(from: url, maxSize: 500_000)

        XCTAssertTrue(result.text.contains("\\|"),
                      "Pipe characters in cells should be escaped to avoid breaking markdown table")
    }

    func testExtract_SingleColumn_FormatsCorrectly() async throws {
        let csv = "Names\nAlice\nBob\nCharlie"
        let url = makeTempCSV(csv)
        let result = try await extractor.extract(from: url, maxSize: 500_000)

        XCTAssertTrue(result.text.contains("| Names |"), "Single column should produce valid markdown table")
        XCTAssertTrue(result.text.contains("| --- |"), "Should include separator for single column")
    }
}
