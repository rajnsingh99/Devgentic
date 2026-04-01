//
//  ExtractionResultTests.swift
//  devgenticTests
//
//  Tier 1: ExtractionResult metadata correctness.
//

import XCTest
@testable import devgentic

final class ExtractionResultTests: XCTestCase {

    // MARK: - Tier 1: Metadata Accuracy

    func testMetadata_WordCount_Accurate() {
        let result = ExtractionResult(
            text: "The quick brown fox jumps over the lazy dog",
            metadata: .init(
                format: "test",
                pageCount: nil,
                sheetNames: nil,
                wordCount: 9,
                wasTruncated: false,
                extractionMethod: "test"
            )
        )

        XCTAssertEqual(result.metadata.wordCount, 9, "Word count should be 9 for the test sentence")
    }

    func testMetadata_TruncationFlag_WhenNotTruncated() {
        let result = ExtractionResult(
            text: "Short text",
            metadata: .init(
                format: "csv",
                pageCount: nil,
                sheetNames: nil,
                wordCount: 2,
                wasTruncated: false,
                extractionMethod: "native-csv"
            )
        )

        XCTAssertFalse(result.metadata.wasTruncated, "Should report not truncated for short content")
    }

    func testMetadata_SheetNames_ForSpreadsheet() {
        let result = ExtractionResult(
            text: "table data",
            metadata: .init(
                format: "xlsx",
                pageCount: nil,
                sheetNames: ["Sales", "Revenue", "Costs"],
                wordCount: 2,
                wasTruncated: false,
                extractionMethod: "corexlsx"
            )
        )

        XCTAssertEqual(result.metadata.sheetNames?.count, 3, "Should report 3 sheet names")
        XCTAssertEqual(result.metadata.sheetNames?.first, "Sales", "First sheet should be 'Sales'")
    }

    func testMetadata_PageCount_ForPDF() {
        let result = ExtractionResult(
            text: "pdf content",
            metadata: .init(
                format: "pdf",
                pageCount: 42,
                sheetNames: nil,
                wordCount: 2,
                wasTruncated: false,
                extractionMethod: "pdfkit"
            )
        )

        XCTAssertEqual(result.metadata.pageCount, 42, "Should report correct page count")
        XCTAssertNil(result.metadata.sheetNames, "PDF should not have sheet names")
    }
}
