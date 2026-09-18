// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
//
//  PPTXExtractor.swift
//  Devgentic
//
//  Created by Raj Singh on 29/03/26.
//

import Foundation
import UniformTypeIdentifiers
import os

struct PPTXExtractor: DocumentExtractor {
    var supportedTypes: [UTType] {
        [UTType("org.openxmlformats.presentationml.presentation") ?? .data]
    }
    var supportedExtensions: Set<String> { ["pptx"] }

    private let logger = Logger(subsystem: DGLogger.subsystem, category: "PPTXExtractor")

    func extract(from url: URL, maxSize: Int) async throws -> ExtractionResult {
        logger.info("Starting PPTX extraction: \(url.lastPathComponent)")

        // Staged rather than handed to unzip directly: unzip glob-matches the ARCHIVE NAME, so a
        // deck called `a*.pptx` made it open other archives and return their slides under this
        // path. See `ZipArchiveStaging`.
        let staged = try ZipArchiveStaging.expandZip(at: url, format: "pptx")
        defer { try? FileManager.default.removeItem(at: staged.workDirectory) }

        // Find slide XML files: ppt/slides/slide1.xml, slide2.xml, ...
        let slidesDir = staged.contentRoot.appendingPathComponent("ppt/slides")
        guard let slideFiles = try? FileManager.default.contentsOfDirectory(
            at: slidesDir, includingPropertiesForKeys: nil
        ).filter({ $0.pathExtension == "xml" && $0.lastPathComponent.hasPrefix("slide") })
        .sorted(by: { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending })
        else {
            logger.error("No slide XML files found in ppt/slides/ for: \(url.lastPathComponent)")
            throw DocumentExtractionError.corruptedFile(url.path)
        }

        logger.info("Found \(slideFiles.count) slides in: \(url.lastPathComponent)")

        var fullText = ""
        var slideCount = 0

        for slideFile in slideFiles {
            slideCount += 1
            let xmlData = try Data(contentsOf: slideFile)
            let parser = PPTXSlideTextParser()
            let slideText = parser.extractText(from: xmlData)

            if !slideText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                fullText += "## Slide \(slideCount)\n\n\(slideText)\n\n"
                logger.debug("Slide \(slideCount): extracted \(slideText.count) chars")
            } else {
                logger.debug("Slide \(slideCount): no text content")
            }

            if fullText.count >= maxSize { break }
        }

        let wasTruncated = fullText.count >= maxSize
        if wasTruncated {
            logger.warning("PPTX content truncated at \(maxSize) chars for \(url.lastPathComponent)")
            fullText = String(fullText.prefix(maxSize))
        }

        guard !fullText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            logger.warning("PPTX contains no extractable text: \(url.lastPathComponent)")
            throw DocumentExtractionError.emptyDocument(url.path)
        }

        let wordCount = fullText.split(separator: " ").count
        logger.info("PPTX extraction complete: \(slideCount) slides, \(wordCount) words — \(url.lastPathComponent)")

        return ExtractionResult(
            text: fullText,
            metadata: .init(
                format: "pptx",
                pageCount: slideCount,
                sheetNames: nil,
                wordCount: wordCount,
                wasTruncated: wasTruncated,
                extractionMethod: "unzip-xml"
            )
        )
    }
}

// MARK: - PPTX Slide XML Text Parser

/// Extracts text from ppt/slides/slideN.xml by walking <a:t> elements
class PPTXSlideTextParser: NSObject, XMLParserDelegate {
    private var extractedText = ""
    private var isInsideTextElement = false
    private var currentText = ""

    func extractText(from data: Data) -> String {
        extractedText = ""
        let parser = XMLParser(data: data)
        parser.delegate = self
        parser.parse()
        return extractedText
    }

    func parser(_ parser: XMLParser, didStartElement elementName: String,
                namespaceURI: String?, qualifiedName: String?,
                attributes: [String: String] = [:]) {
        // <a:t> contains text in OOXML slides
        if elementName == "a:t" || elementName.hasSuffix(":t") {
            isInsideTextElement = true
            currentText = ""
        }
        // <a:p> marks paragraph boundaries
        if elementName == "a:p" || elementName.hasSuffix(":p") {
            if !extractedText.isEmpty && !extractedText.hasSuffix("\n") {
                extractedText += "\n"
            }
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        if isInsideTextElement {
            currentText += string
        }
    }

    func parser(_ parser: XMLParser, didEndElement elementName: String,
                namespaceURI: String?, qualifiedName: String?) {
        if elementName == "a:t" || elementName.hasSuffix(":t") {
            isInsideTextElement = false
            extractedText += currentText
        }
    }
}
