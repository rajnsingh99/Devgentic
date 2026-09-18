// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
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

    private let logger = Logger(subsystem: DGLogger.subsystem, category: "CSVExtractor")

    func extract(from url: URL, maxSize: Int) async throws -> ExtractionResult {
        let ext = url.pathExtension.lowercased()
        let delimiter: Character = ext == "tsv" ? "\t" : ","

        logger.info("Starting \(ext.uppercased()) extraction: \(url.lastPathComponent)")

        let rawContent: String
        do {
            rawContent = try String(contentsOf: url, encoding: .utf8)
        } catch {
            // Try other encodings.
            //
            // The sniff is not optional here. ISO Latin-1 maps every byte value and therefore
            // cannot fail, so without it any binary file named `.csv` "decoded" and came back
            // rendered as a markdown TABLE — mojibake with column headers, which reads as
            // structured data and is more convincing than plain garbage would be. See
            // `BinaryContentSniffer`.
            logger.debug("UTF-8 decoding failed for \(url.lastPathComponent), trying detection then ISO Latin-1")

            // Detection BEFORE Latin-1, mirroring `ReadFileTool`'s plain-text chain. Skipping this
            // step is what made a BOM-marked UTF-16 CSV — what Excel writes on "Save As UTF-16" —
            // come back as `| ÿþn` and onwards: the BOM read as two Latin-1 characters, every
            // real character interleaved with a NUL, rendered as a markdown TABLE. The identical
            // bytes named `.txt` decoded correctly, so one file was readable under one extension
            // and garbage under the other.
            var detectedEncoding: String.Encoding = .utf8
            if let detected = try? String(contentsOf: url, usedEncoding: &detectedEncoding) {
                logger.info("Decoded \(url.lastPathComponent) as \(detectedEncoding.description) via detection")
                rawContent = detected
            } else if let data = try? Data(contentsOf: url),
                      !BinaryContentSniffer.looksBinary(data),
                      let latin1 = String(data: data, encoding: .isoLatin1) {
                logger.info("ISO Latin-1 fallback succeeded for \(url.lastPathComponent)")
                rawContent = latin1
            } else {
                logger.error("All encoding attempts failed for: \(url.lastPathComponent)")
                throw DocumentExtractionError.extractionFailed("csv", underlying: error)
            }
        }

        // Parse CSV with quoted field support
        let rows = parseCSV(rawContent, delimiter: delimiter)

        guard !rows.isEmpty else {
            logger.warning("CSV contains no data rows: \(url.lastPathComponent)")
            throw DocumentExtractionError.emptyDocument(url.path)
        }

        logger.debug("Parsed \(rows.count) rows from \(url.lastPathComponent)")

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
            logger.warning("\(ext.uppercased()) content truncated at \(maxSize) chars for \(url.lastPathComponent)")
            fullText = String(fullText.prefix(maxSize))
        }

        let cellCount = rows.reduce(0) { $0 + $1.count }
        logger.info("\(ext.uppercased()) extraction complete: \(rows.count) rows, \(cellCount) cells — \(url.lastPathComponent)")

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
                } else if char == "\n" || char == "\r" || char == "\r\n" {
                    // `"\r\n"` is listed explicitly because this loop walks CHARACTERS, and in
                    // Swift a CR immediately followed by an LF is ONE grapheme cluster equal to
                    // neither "\r" nor "\n". Without that third comparison the branch never fired
                    // on a Windows-authored file: every row ran together into a single cell, and
                    // the whole spreadsheet was returned as one table row, reported as success.
                    //
                    // The old lookahead that skipped an LF after a CR was dead code for the same
                    // reason — the two can never arrive as separate Characters — so it is gone.
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
