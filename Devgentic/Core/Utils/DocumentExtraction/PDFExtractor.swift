// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
//
//  PDFExtractor.swift
//  Devgentic
//
//  Created by Raj Singh on 29/03/26.
//

import Foundation
import PDFKit
import Vision
import UniformTypeIdentifiers
import os

struct PDFExtractor: DocumentExtractor {
    var supportedTypes: [UTType] { [.pdf] }
    var supportedExtensions: Set<String> { ["pdf"] }

    private let logger = Logger(subsystem: DGLogger.subsystem, category: "PDFExtractor")

    func extract(from url: URL, maxSize: Int) async throws -> ExtractionResult {
        logger.info("Starting PDF extraction: \(url.lastPathComponent)")

        guard let pdfDocument = PDFDocument(url: url) else {
            logger.error("Failed to initialize PDFDocument for: \(url.lastPathComponent)")
            throw DocumentExtractionError.corruptedFile(url.path)
        }

        let pageCount = pdfDocument.pageCount
        logger.info("PDF loaded: \(pageCount) pages — \(url.lastPathComponent)")

        var fullText = ""
        var method = "pdfkit"

        // Phase 1: Try PDFKit text extraction
        for i in 0..<pageCount {
            guard let page = pdfDocument.page(at: i) else { continue }
            if let pageText = page.string {
                fullText += pageText + "\n\n"
            }
            if fullText.count >= maxSize { break }
        }

        // Phase 2: If PDFKit returned little/no text, try OCR via Vision
        let trimmed = fullText.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.count < 50 && pageCount > 0 {
            logger.info("PDFKit extracted only \(trimmed.count) chars — falling back to Vision OCR for \(url.lastPathComponent)")
            fullText = try await extractViaOCR(document: pdfDocument, maxSize: maxSize)
            method = "vision-ocr"
        }

        let wasTruncated = fullText.count >= maxSize
        if wasTruncated {
            logger.warning("PDF content truncated at \(maxSize) chars for \(url.lastPathComponent)")
            fullText = String(fullText.prefix(maxSize))
        }

        guard !fullText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            logger.warning("PDF contains no extractable text: \(url.lastPathComponent)")
            throw DocumentExtractionError.emptyDocument(url.path)
        }

        let wordCount = fullText.split(separator: " ").count
        logger.info("PDF extraction complete: \(wordCount) words via \(method) — \(url.lastPathComponent)")

        return ExtractionResult(
            text: fullText,
            metadata: .init(
                format: "pdf",
                pageCount: pageCount,
                sheetNames: nil,
                wordCount: wordCount,
                wasTruncated: wasTruncated,
                extractionMethod: method
            )
        )
    }

    // MARK: - Vision OCR Fallback

    private func extractViaOCR(document: PDFDocument, maxSize: Int) async throws -> String {
        var ocrText = ""

        for i in 0..<document.pageCount {
            guard let page = document.page(at: i) else { continue }

            // Render page to CGImage
            let pageRect = page.bounds(for: .mediaBox)
            let scale: CGFloat = 2.0  // 2x for better OCR accuracy
            let width = Int(pageRect.width * scale)
            let height = Int(pageRect.height * scale)

            guard let context = CGContext(
                data: nil, width: width, height: height,
                bitsPerComponent: 8, bytesPerRow: 0,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ) else {
                logger.warning("Failed to create CGContext for OCR on page \(i + 1)")
                continue
            }

            context.setFillColor(CGColor.white)
            context.fill(CGRect(x: 0, y: 0, width: width, height: height))
            context.scaleBy(x: scale, y: scale)

            // PDFKit renders in a flipped coordinate system
            page.draw(with: .mediaBox, to: context)

            guard let cgImage = context.makeImage() else {
                logger.warning("Failed to render CGImage for OCR on page \(i + 1)")
                continue
            }

            // Run Vision text recognition
            do {
                let pageText = try await recognizeText(in: cgImage)
                logger.debug("OCR page \(i + 1): extracted \(pageText.count) chars")
                ocrText += pageText + "\n\n"
            } catch {
                logger.error("Vision OCR failed on page \(i + 1): \(error.localizedDescription)")
            }

            if ocrText.count >= maxSize { break }
        }

        logger.info("Vision OCR complete: \(ocrText.count) chars total across \(document.pageCount) pages")
        return ocrText
    }

    private func recognizeText(in image: CGImage) async throws -> String {
        try await withCheckedThrowingContinuation { continuation in
            let request = VNRecognizeTextRequest { request, error in
                if let error = error {
                    continuation.resume(throwing: error)
                    return
                }

                let observations = request.results as? [VNRecognizedTextObservation] ?? []
                let text = observations
                    .compactMap { $0.topCandidates(1).first?.string }
                    .joined(separator: "\n")
                continuation.resume(returning: text)
            }

            request.recognitionLevel = .accurate
            request.usesLanguageCorrection = true

            let handler = VNImageRequestHandler(cgImage: image, options: [:])
            do {
                try handler.perform([request])
            } catch {
                continuation.resume(throwing: error)
            }
        }
    }
}
