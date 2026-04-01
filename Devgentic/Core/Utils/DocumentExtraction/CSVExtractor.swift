//
//  CSVExtractor.swift
//  Devgentic
//
//  Created by Raj Singh on 29/03/26.
//

import Foundation
import UniformTypeIdentifiers
import os

struct CSVExtractor: DocumentExtractor {
    var supportedTypes: [UTType] { [.commaSeparatedText, .tabSeparatedText] }
    var supportedExtensions: Set<String> { ["csv", "tsv"] }

    private let logger = Logger(subsystem: "com.devgentic", category: "CSVExtractor")

    func extract(from url: URL, maxSize: Int) async throws -> ExtractionResult {
        let ext = url.pathExtension.lowercased()
        let delimiter: Character = ext == "tsv" ? "\t" : ","

        logger.info("Starting \(ext.uppercased(), privacy: .public) extraction: \(url.lastPathComponent, privacy: .public)")

        let rawContent: String
        do {
            rawContent = try String(contentsOf: url, encoding: .utf8)
        } catch {
            // Try other encodings
            logger.debug("UTF-8 decoding failed for \(url.lastPathComponent, privacy: .public), trying ISO Latin-1")
            if let data = try? Data(contentsOf: url),
               let latin1 = String(data: data, encoding: .isoLatin1) {
                logger.info("ISO Latin-1 fallback succeeded for \(url.lastPathComponent, privacy: .public)")
                rawContent = latin1
            } else {
                logger.error("All encoding attempts failed for: \(url.lastPathComponent, privacy: .public)")
                throw DocumentExtractionError.extractionFailed("csv", underlying: error)
            }
        }

        // Parse CSV with quoted field support
        let rows = parseCSV(rawContent, delimiter: delimiter)

        guard !rows.isEmpty else {
            logger.warning("CSV contains no data rows: \(url.lastPathComponent, privacy: .public)")
            throw DocumentExtractionError.emptyDocument(url.path)
        }

        logger.debug("Parsed \(rows.count) rows from \(url.lastPathComponent, privacy: .public)")

        // Convert to markdown table
        var fullText = ""

        for (index, row) in rows.enumerated() {
            let escapedCells = row.map { cell in
                cell.replacingOccurrences(of: "|", with: "\\|")
            }

            fullText += "| " + escapedCells.joined(separator: " | ") + " |\n"

            if index == 0 {
                let separator = "| " + row.map { _ in "---" }.joined(separator: " | ") + " |"
                fullText += separator + "\n"
            }

            if fullText.count >= maxSize { break }
        }

        let wasTruncated = fullText.count >= maxSize
        if wasTruncated {
            logger.warning("\(ext.uppercased(), privacy: .public) content truncated at \(maxSize) chars for \(url.lastPathComponent, privacy: .public)")
            fullText = String(fullText.prefix(maxSize))
        }

        let cellCount = rows.reduce(0) { $0 + $1.count }
        logger.info("\(ext.uppercased(), privacy: .public) extraction complete: \(rows.count) rows, \(cellCount) cells — \(url.lastPathComponent, privacy: .public)")

        return ExtractionResult(
            text: fullText,
            metadata: .init(
                format: ext,
                pageCount: nil,
                sheetNames: nil,
                wordCount: cellCount,
                wasTruncated: wasTruncated,
                extractionMethod: "native-csv"
            )
        )
    }

    // MARK: - CSV Parser (handles quoted fields with commas/newlines inside)

    private func parseCSV(_ content: String, delimiter: Character) -> [[String]] {
        var rows: [[String]] = []
        var currentRow: [String] = []
        var currentField = ""
        var inQuotes = false
        var i = content.startIndex

        while i < content.endIndex {
            let char = content[i]

            if inQuotes {
                if char == "\"" {
                    let next = content.index(after: i)
                    if next < content.endIndex && content[next] == "\"" {
                        // Escaped quote ""
                        currentField.append("\"")
                        i = content.index(after: next)
                        continue
                    } else {
                        inQuotes = false
                    }
                } else {
                    currentField.append(char)
                }
            } else {
                if char == "\"" {
                    inQuotes = true
                } else if char == delimiter {
                    currentRow.append(currentField.trimmingCharacters(in: .whitespaces))
                    currentField = ""
                } else if char == "\n" || char == "\r" {
                    if char == "\r" {
                        let next = content.index(after: i)
                        if next < content.endIndex && content[next] == "\n" {
                            i = next // Skip \r\n
                        }
                    }
                    currentRow.append(currentField.trimmingCharacters(in: .whitespaces))
                    if !currentRow.allSatisfy({ $0.isEmpty }) {
                        rows.append(currentRow)
                    }
                    currentRow = []
                    currentField = ""
                } else {
                    currentField.append(char)
                }
            }

            i = content.index(after: i)
        }

        // Final row
        if !currentField.isEmpty || !currentRow.isEmpty {
            currentRow.append(currentField.trimmingCharacters(in: .whitespaces))
            if !currentRow.allSatisfy({ $0.isEmpty }) {
                rows.append(currentRow)
            }
        }

        return rows
    }
}
