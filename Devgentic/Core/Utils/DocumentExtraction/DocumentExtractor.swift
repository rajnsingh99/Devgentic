// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2026 Raj Singh
//
//  DocumentExtractor.swift
//  Devgentic
//
//  Created by Raj Singh on 29/03/26.
//

import Foundation
import UniformTypeIdentifiers

// MARK: - Extraction Result

struct ExtractionResult: Sendable {
    let text: String
    let metadata: ExtractionMetadata

    struct ExtractionMetadata: Sendable {
        let format: String           // "pdf", "docx", "xlsx", "csv", "pptx", "rtf"
        let pageCount: Int?          // PDF, DOCX, PPTX
        let sheetNames: [String]?    // XLSX
        let wordCount: Int           // Approximate
        let wasTruncated: Bool       // Hit maxSize limit
        let extractionMethod: String // "pdfkit", "swiftdocx", "corexlsx", "vision-ocr", etc.
    }
}

// MARK: - Extractor Protocol

protocol DocumentExtractor: Sendable {
    /// UTTypes this extractor handles
    var supportedTypes: [UTType] { get }

    /// File extensions this extractor handles (fallback when UTType detection fails)
    var supportedExtensions: Set<String> { get }

    /// Returns true if this extractor can handle the given URL
    func canExtract(from url: URL) -> Bool

    /// Extract text content from the file, respecting maxSize character limit
    func extract(from url: URL, maxSize: Int) async throws -> ExtractionResult
}

// MARK: - Default canExtract implementation

extension DocumentExtractor {
    func canExtract(from url: URL) -> Bool {
        let ext = url.pathExtension.lowercased()
        if supportedExtensions.contains(ext) { return true }

        if let uttype = UTType(filenameExtension: ext) {
            return supportedTypes.contains(where: { uttype.conforms(to: $0) })
        }
        return false
    }
}

// MARK: - Extraction Errors

enum DocumentExtractionError: LocalizedError {
    case unsupportedFormat(String)
    case fileNotFound(String)
    case extractionFailed(String, underlying: Error?)
    case passwordProtected(String)
    case corruptedFile(String)
    case emptyDocument(String)

    var errorDescription: String? {
        switch self {
        case .unsupportedFormat(let fmt): return "Unsupported document format: \(fmt)"
        case .fileNotFound(let path): return "File not found: \(path)"
        case .extractionFailed(let fmt, let err): return "Failed to extract \(fmt): \(err?.localizedDescription ?? "unknown error")"
        case .passwordProtected(let path): return "Document is password-protected: \(path)"
        case .corruptedFile(let path): return "Document appears corrupted: \(path)"
        case .emptyDocument(let path): return "Document contains no extractable text: \(path)"
        }
    }
}
