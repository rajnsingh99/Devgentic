// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
//
//  ImageAccessibilityTests.swift
//  DevgenticTests
//
//  Alt text is parsed by the markdown parser, modelled on MessageContent, and threaded all
//  the way to the render sites — then dropped at every one of them. AgentBubbleContentView
//  destructured `case .image(_, _, let imageData)` and stamped a hardcoded
//  "Generated image" label from OUTSIDE ImageView, which also clobbered ImageView's own
//  "Loading image" / "Image failed to load" labels. The AsyncImage sites showed altText as
//  a caption only WHILE loading, so the image that stays on screen had no description.
//
//  Result: every image announced identically to VoiceOver, and a screen-reader user could
//  not tell two pictures apart.
//

import XCTest
import SwiftUI
@testable import devgentic

@MainActor
final class ImageAccessibilityTests: XCTestCase {

    // MARK: - The model actually carries alt text

    /// If the parser ever stops carrying alt, the render-site fixes are pointless.
    func testMarkdownParserCarriesAltTextOntoTheImageBlock() {
        let blocks = parseMarkdown("![A red bar chart of Q4 revenue](https://example.com/chart.png)")
        guard let image = blocks.first(where: { if case .image = $0.type { return true }; return false }),
              case .image(let url, let altText) = image.type else {
            return XCTFail("No image block parsed")
        }
        XCTAssertEqual(url, "https://example.com/chart.png")
        XCTAssertEqual(altText, "A red bar chart of Q4 revenue")
    }

    /// RAG/export already relied on alt — proof it was reaching the UI layer intact, and
    /// that only the render sites were dropping it.
    func testAltTextIsWhatPlainTextFlatteningUses() {
        let blocks = parseMarkdown("![A red bar chart](https://example.com/chart.png)")
        XCTAssertEqual(blocks.first?.plainText, "A red bar chart")
    }

    // MARK: - MediaArtifactImageView (the single image renderer)

    /// The renderer holds only an artifact REFERENCE — construction must never resolve or
    /// decode. (Its predecessor once decoded in `init` via `State(initialValue:)`, which
    /// re-decoded the full payload on every parent re-render.)
    func testConstructingTheRendererIsCheap() {
        let artifact = MediaArtifact(
            kind: .image,
            reference: .ephemeralData(Self.makeRedPNG()),
            mimeType: "image/png",
            label: "chart"
        )
        let start = Date()
        for _ in 0..<200 { _ = MediaArtifactImageView(artifact: artifact) }
        XCTAssertLessThan(Date().timeIntervalSince(start), 0.5, "init is resolving/decoding again")
    }

    // MARK: - Shared sizing

    /// The same image rendered a different size depending on which path produced it:
    /// 500 in four renderers, 512 in MediaArtifactImageView.
    func testEveryRendererSharesOneImageCap() {
        XCTAssertEqual(ChatUIConstants.imageMaxWidth, 500)
        XCTAssertGreaterThan(ChatUIConstants.imagePlaceholderMinHeight, 0)
    }

    private static func makeRedPNG() -> Data {
        let image = NSImage(size: NSSize(width: 600, height: 600))
        image.lockFocus()
        NSColor.red.drawSwatch(in: NSRect(x: 0, y: 0, width: 600, height: 600))
        image.unlockFocus()
        guard let tiff = image.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiff),
              let png = bitmap.representation(using: .png, properties: [:]) else { return Data() }
        return png
    }
}
