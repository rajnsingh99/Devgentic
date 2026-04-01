//
//  DocumentExtractionRegistry.swift
//  Devgentic
//
//  Created by Raj Singh on 29/03/26.
//

import Foundation
import os

/// Central registry that routes files to the appropriate extractor.
/// Single entry point for all document extraction in the app.
final class DocumentExtractionRegistry: Sendable {

    static let shared = DocumentExtractionRegistry()

    private let extractors: [any DocumentExtractor]
    private let logger = Logger(subsystem: "com.devgentic", category: "DocumentExtraction")

    private init() {
        self.extractors = [
            PDFExtractor(),
            DOCXExtractor(),
            XLSXExtractor(),
            CSVExtractor(),
            PPTXExtractor(),
            RTFExtractor()
        ]
    }

    /// Check if any extractor supports this file
    func canExtract(from url: URL) -> Bool {
        extractors.contains(where: { $0.canExtract(from: url) })
    }

    /// Extract text from a file using the first matching extractor
    func extract(from url: URL, maxSize: Int = 500_000) async throws -> ExtractionResult {
        guard let extractor = extractors.first(where: { $0.canExtract(from: url) }) else {
            throw DocumentExtractionError.unsupportedFormat(url.pathExtension)
        }

        let ext = url.pathExtension.lowercased()
        logger.info("Extracting \(ext) using \(type(of: extractor))")

        do {
            let result = try await extractor.extract(from: url, maxSize: maxSize)
            logger.info("Extracted \(result.metadata.wordCount) words from \(ext) via \(result.metadata.extractionMethod)")
            return result
        } catch {
            logger.error("Extraction failed for \(url.lastPathComponent): \(error.localizedDescription)")
            throw error
        }
    }

    /// Returns human-readable list of supported formats
    var supportedFormatDescriptions: [String] {
        ["PDF", "DOCX (Word)", "XLSX (Excel)", "CSV/TSV", "PPTX (PowerPoint)", "RTF"]
    }

    /// Returns all supported file extensions
    var allSupportedExtensions: Set<String> {
        var extensions = Set<String>()
        for extractor in extractors {
            extensions.formUnion(extractor.supportedExtensions)
        }
        return extensions
    }
}
