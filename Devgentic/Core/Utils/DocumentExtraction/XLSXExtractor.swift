//
//  XLSXExtractor.swift
//  Devgentic
//
//  Created by Raj Singh on 29/03/26.
//

import Foundation
import UniformTypeIdentifiers
import CoreXLSX
import os

struct XLSXExtractor: DocumentExtractor {
    var supportedTypes: [UTType] {
        [UTType("org.openxmlformats.spreadsheetml.sheet") ?? .data]
    }
    var supportedExtensions: Set<String> { ["xlsx", "xls"] }

    private let logger = Logger(subsystem: "com.devgentic", category: "XLSXExtractor")

    func extract(from url: URL, maxSize: Int) async throws -> ExtractionResult {
        logger.info("Starting XLSX extraction: \(url.lastPathComponent)")

        guard let xlsxFile = XLSXFile(filepath: url.path) else {
            logger.error("Failed to initialize XLSXFile for: \(url.lastPathComponent)")
            throw DocumentExtractionError.corruptedFile(url.path)
        }

        var fullText = ""
        var sheetNames: [String] = []

        // Parse shared strings (CoreXLSX stores cell text in a shared string table)
        let sharedStrings = try? xlsxFile.parseSharedStrings()
        if sharedStrings == nil {
            logger.debug("No shared strings table found in: \(url.lastPathComponent) — cell values may be inline")
        }

        for workbookPath in try xlsxFile.parseWorkbooks() {
            for (sheetName, sheetPath) in try xlsxFile.parseWorksheetPathsAndNames(workbook: workbookPath) {
                sheetNames.append(sheetName ?? "Sheet")

                let worksheet = try xlsxFile.parseWorksheet(at: sheetPath)

                fullText += "## Sheet: \(sheetName ?? "Unnamed")\n\n"

                // Convert rows to markdown table format for LLM readability
                guard let rows = worksheet.data?.rows, !rows.isEmpty else {
                    logger.debug("Sheet '\(sheetName ?? "Unnamed")' is empty, skipping")
                    continue
                }

                logger.debug("Processing sheet '\(sheetName ?? "Unnamed")': \(rows.count) rows")

                for (rowIndex, row) in rows.enumerated() {
                    let cells = row.cells.map { cell -> String in
                        if let ss = sharedStrings, let value = cell.stringValue(ss) {
                            return value
                        } else if let value = cell.value {
                            return value
                        }
                        return ""
                    }

                    let rowText = "| " + cells.joined(separator: " | ") + " |"
                    fullText += rowText + "\n"

                    // Add markdown table header separator after first row
                    if rowIndex == 0 {
                        let separator = "| " + cells.map { _ in "---" }.joined(separator: " | ") + " |"
                        fullText += separator + "\n"
                    }

                    if fullText.count >= maxSize { break }
                }

                fullText += "\n"
                if fullText.count >= maxSize { break }
            }
            if fullText.count >= maxSize { break }
        }

        let wasTruncated = fullText.count >= maxSize
        if wasTruncated {
            logger.warning("XLSX content truncated at \(maxSize) chars for \(url.lastPathComponent)")
            fullText = String(fullText.prefix(maxSize))
        }

        guard !fullText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            logger.warning("XLSX contains no extractable text: \(url.lastPathComponent)")
            throw DocumentExtractionError.emptyDocument(url.path)
        }

        let wordCount = fullText.split(separator: " ").count
        logger.info("XLSX extraction complete: \(sheetNames.count) sheets, \(wordCount) words — \(url.lastPathComponent)")

        return ExtractionResult(
            text: fullText,
            metadata: .init(
                format: "xlsx",
                pageCount: nil,
                sheetNames: sheetNames,
                wordCount: wordCount,
                wasTruncated: wasTruncated,
                extractionMethod: "corexlsx"
            )
        )
    }
}
