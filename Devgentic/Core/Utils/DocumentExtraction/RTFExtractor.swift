//
//  RTFExtractor.swift
//  Devgentic
//
//  Created by Raj Singh on 29/03/26.
//

import Foundation
import UniformTypeIdentifiers
import os
#if canImport(AppKit)
import AppKit
#endif

struct RTFExtractor: DocumentExtractor {
    var supportedTypes: [UTType] { [.rtf, .rtfd] }
    var supportedExtensions: Set<String> { ["rtf", "rtfd"] }

    private let logger = Logger(subsystem: DGLogger.subsystem, category: "RTFExtractor")

    func extract(from url: URL, maxSize: Int) async throws -> ExtractionResult {
        logger.info("Starting RTF extraction: \(url.lastPathComponent)")

        let data = try Data(contentsOf: url)
        logger.debug("Read \(data.count) bytes from: \(url.lastPathComponent)")

        guard let attributedString = NSAttributedString(
            rtf: data,
            documentAttributes: nil
        ) else {
            logger.error("NSAttributedString RTF conversion failed for: \(url.lastPathComponent)")
            throw DocumentExtractionError.extractionFailed("rtf", underlying: nil)
        }

        var text = attributedString.string

        let wasTruncated = text.count >= maxSize
        if wasTruncated {
            logger.warning("RTF content truncated at \(maxSize) chars for \(url.lastPathComponent)")
            text = String(text.prefix(maxSize))
        }

        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            logger.warning("RTF contains no extractable text: \(url.lastPathComponent)")
            throw DocumentExtractionError.emptyDocument(url.path)
        }

        let wordCount = text.split(separator: " ").count
        logger.info("RTF extraction complete: \(wordCount) words — \(url.lastPathComponent)")

        return ExtractionResult(
            text: text,
            metadata: .init(
                format: "rtf",
                pageCount: nil,
                sheetNames: nil,
                wordCount: wordCount,
                wasTruncated: wasTruncated,
                extractionMethod: "nsattributedstring"
            )
        )
    }
}
