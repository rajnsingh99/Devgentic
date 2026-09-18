// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
//
//  DOCXExtractor.swift
//  Devgentic
//
//  Created by Raj Singh on 29/03/26.
//

import Foundation
import UniformTypeIdentifiers
import os

struct DOCXExtractor: DocumentExtractor {
    var supportedTypes: [UTType] {
        [UTType("org.openxmlformats.wordprocessingml.document") ?? .data]
    }
    var supportedExtensions: Set<String> { ["docx"] }

    private let logger = Logger(subsystem: DGLogger.subsystem, category: "DOCXExtractor")

    func extract(from url: URL, maxSize: Int) async throws -> ExtractionResult {
        logger.info("Starting DOCX extraction: \(url.lastPathComponent)")
        return try extractWithUnzipFallback(from: url, maxSize: maxSize)
    }

    // MARK: - DIY Fallback: DOCX = ZIP of XML

    private func extractWithUnzipFallback(from url: URL, maxSize: Int) throws -> ExtractionResult {
        // DOCX is a ZIP archive containing word/document.xml.
        //
        // Staged rather than handed to unzip directly: unzip glob-matches the ARCHIVE NAME, so a
        // file called `a*.docx` made it open other archives and return their text under this
        // path. See `ZipArchiveStaging`.
        let staged = try ZipArchiveStaging.expandZip(at: url, format: "docx")
        defer { try? FileManager.default.removeItem(at: staged.workDirectory) }

        // Parse word/document.xml
        let documentXML = staged.contentRoot.appendingPathComponent("word/document.xml")
        guard FileManager.default.fileExists(atPath: documentXML.path) else {
            logger.error("word/document.xml not found in DOCX archive: \(url.lastPathComponent)")
            throw DocumentExtractionError.corruptedFile(url.path)
        }

        let xmlData = try Data(contentsOf: documentXML)
        logger.debug("Parsing word/document.xml (\(xmlData.count) bytes) for: \(url.lastPathComponent)")

        let parser = DOCXXMLTextParser()
        let text = parser.extractText(from: xmlData, maxSize: maxSize)

        let wasTruncated = text.count >= maxSize
        if wasTruncated {
            logger.warning("DOCX content truncated at \(maxSize) chars for \(url.lastPathComponent)")
        }

        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            logger.warning("DOCX contains no extractable text: \(url.lastPathComponent)")
            throw DocumentExtractionError.emptyDocument(url.path)
        }

        let wordCount = text.split(separator: " ").count
        logger.info("DOCX extraction complete: \(wordCount) words via unzip-xml — \(url.lastPathComponent)")

        return ExtractionResult(
            text: text,
            metadata: .init(
                format: "docx",
                pageCount: nil,
                sheetNames: nil,
                wordCount: wordCount,
                wasTruncated: wasTruncated,
                extractionMethod: "unzip-xml"
            )
        )
    }
}

// MARK: - Minimal DOCX XML Text Extractor

/// Extracts text from word/document.xml by walking <w:t> elements
class DOCXXMLTextParser: NSObject, XMLParserDelegate {
    private var extractedText = ""
    private var isInsideTextElement = false
    private var currentText = ""
    private var maxSize = Int.max
    private var hitLimit = false

    func extractText(from data: Data, maxSize: Int) -> String {
        self.maxSize = maxSize
        self.extractedText = ""
        self.hitLimit = false

        let parser = XMLParser(data: data)
        parser.delegate = self
        parser.parse()

        return extractedText
    }

    func parser(_ parser: XMLParser, didStartElement elementName: String,
                namespaceURI: String?, qualifiedName: String?,
                attributes: [String: String] = [:]) {
        // <w:t> contains the actual text content
        if elementName == "w:t" || elementName.hasSuffix(":t") {
            isInsideTextElement = true
            currentText = ""
        }
        // <w:p> marks paragraph boundaries
        if elementName == "w:p" || elementName.hasSuffix(":p") {
            if !extractedText.isEmpty { extractedText += "\n" }
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        if isInsideTextElement && !hitLimit {
            currentText += string
        }
    }

    func parser(_ parser: XMLParser, didEndElement elementName: String,
                namespaceURI: String?, qualifiedName: String?) {
        if elementName == "w:t" || elementName.hasSuffix(":t") {
            isInsideTextElement = false
            extractedText += currentText
            if extractedText.count >= maxSize {
                hitLimit = true
                extractedText = String(extractedText.prefix(maxSize))
            }
        }
    }
}
