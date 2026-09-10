// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2026 Raj Singh
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

    /// The `.image` case was REMOVED (2026-07-17) — MediaArtifact is the single image
    /// representation. This pins the decode shim: a message persisted under the legacy
    /// shape must decode as an artifact, carrying its bytes and its alt text (as label).
    func testLegacyPersistedImageDecodesAsMediaArtifact() throws {
        let payload = Self.makeRedPNG().base64EncodedString()
        let legacyJSON = Data(#"{"type":"image","imageAlt":"A red bar chart of Q4 revenue","imageData":"\#(payload)"}"#.utf8)

        let decoded = try JSONDecoder().decode(MessageContent.self, from: legacyJSON)
        guard case .mediaArtifact(let artifact) = decoded else {
            return XCTFail("Legacy image must decode as .mediaArtifact, got \(decoded)")
        }
        XCTAssertEqual(artifact.kind, .image)
        XCTAssertEqual(artifact.label, "A red bar chart of Q4 revenue", "alt becomes the label")
        guard case .ephemeralData(let data) = artifact.reference else {
            return XCTFail("Inline legacy bytes must become an ephemeralData reference")
        }
        XCTAssertEqual(data, Self.makeRedPNG(), "Bytes must survive the conversion verbatim")
    }

    /// URL-only legacy images (no inline data) become remote-reference artifacts, whose
    /// unresolvable reference lands in the live renderer's error card — the same outcome
    /// the legacy path showed, through one renderer instead of two.
    func testLegacyUrlOnlyImageDecodesAsRemoteArtifact() throws {
        let legacyJSON = Data(#"{"type":"image","imageUrl":"https://example.com/x.png","imageAlt":"chart"}"#.utf8)
        let decoded = try JSONDecoder().decode(MessageContent.self, from: legacyJSON)
        guard case .mediaArtifact(let artifact) = decoded,
              case .remoteURL(let url) = artifact.reference else {
            return XCTFail("URL-only legacy image must become a remoteURL artifact")
        }
        XCTAssertEqual(url.absoluteString, "https://example.com/x.png")
        XCTAssertEqual(artifact.label, "chart")
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
