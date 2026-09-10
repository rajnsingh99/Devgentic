// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2026 Raj Singh
//
//  BotHistoryImageTests.swift
//  DevgenticTests
//
//  Covers prior-turn image support on the BOT path (ChatExecutor.buildHistoryImageBlocks).
//  Bots compact history into episodic XML with no per-turn structure, so prior-turn
//  images ride the CURRENT user turn — sourced directly from chatHistory, resolved
//  BYTE-TRUTHFULLY (real container sniffed from bytes, not the filename), bytes-first,
//  and bounded to a recent window. HEIC/TIFF/etc transcode to JPEG; the undecodable omit.
//

import XCTest
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
@testable import devgentic

final class BotHistoryImageTests: XCTestCase {

    private let convID = UUID()

    private func userMessage(_ text: String, at seconds: TimeInterval, images: [AttachedImageFile] = []) -> ChatMessage {
        let m = ChatMessage(id: UUID(), conversationId: convID,
                            timestamp: Date(timeIntervalSince1970: seconds), sender: .user,
                            content: .plainText(text))
        if !images.isEmpty { m.attachedImageFiles = images }
        return m
    }

    private func agentMessage(_ text: String, at seconds: TimeInterval) -> ChatMessage {
        ChatMessage(id: UUID(), conversationId: convID,
                    timestamp: Date(timeIntervalSince1970: seconds), sender: .agent,
                    content: .plainText(text))
    }

    /// A history image backed by REAL bytes of a container (default PNG). Resolution is
    /// byte-based, so tests must supply genuine images, not stubs; the name/ext is
    /// cosmetic on the bytes-present path (ext only matters for the no-bytes diskPath).
    private func image(_ name: String, uti: UTType = .png) -> AttachedImageFile {
        let bytes = Self.makeImageBytes(utType: uti)
        return AttachedImageFile(name: name, url: URL(fileURLWithPath: "/tmp/\(name)"),
                                 fileExtension: (name as NSString).pathExtension,
                                 binaryData: bytes, size: Int64(bytes.count))
    }

    /// Explicit-bytes variant for the undecodable-omit and disk-fallback cases.
    private func imageRaw(_ name: String, ext: String, bytes: Data) -> AttachedImageFile {
        AttachedImageFile(name: name, url: URL(fileURLWithPath: "/tmp/\(name)"),
                          fileExtension: ext, binaryData: bytes, size: Int64(bytes.count))
    }

    private func imageCount(_ r: (blocks: [MessageBlock], omitted: Int, transcoded: Int)) -> Int {
        r.blocks.filter { if case .image = $0 { return true }; return false }.count
    }

    /// Synthesizes real image bytes in a given container via ImageIO. TIFF stands in for
    /// HEIC in the transcode tests: both are unsupported-on-the-wire yet ImageIO-decodable,
    /// and TIFF needs no HEIF encoder to synthesize. Includes an alpha channel so the
    /// transcode path exercises the opaque-flatten step.
    static func makeImageBytes(utType: UTType, width: Int = 8, height: Int = 8) -> Data {
        let space = CGColorSpaceCreateDeviceRGB()
        guard let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                                  bytesPerRow: 0, space: space,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return Data() }
        ctx.setFillColor(CGColor(red: 0.2, green: 0.6, blue: 0.9, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        guard let cg = ctx.makeImage() else { return Data() }
        let out = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(out, utType.identifier as CFString, 1, nil) else { return Data() }
        CGImageDestinationAddImage(dest, cg, nil)
        guard CGImageDestinationFinalize(dest) else { return Data() }
        return out as Data
    }

    // MARK: - Collection

    func testCollectsPriorTurnImagesFromUserMessages() {
        let history = [
            userMessage("look at this", at: 1, images: [image("a.png")]),
            agentMessage("a screenshot", at: 2),
            userMessage("and this", at: 3, images: [image("b.png")])
        ]
        let r = ChatExecutor.buildHistoryImageBlocks(from: history)
        XCTAssertEqual(imageCount(r), 2)
        XCTAssertEqual(r.omitted, 0)
    }

    func testAssistantImagesAreNeverCollected() {
        // Media only ever attaches to user turns. An agent message with images (shouldn't
        // happen, but defensively) must not be scanned.
        let agent = agentMessage("reply", at: 2)
        agent.attachedImageFiles = [image("x.png")]
        let history = [userMessage("q", at: 1), agent]
        XCTAssertEqual(imageCount(ChatExecutor.buildHistoryImageBlocks(from: history)), 0)
    }

    // MARK: - Byte-truthful format handling (must not poison the conversation)

    func testUndecodableBytesAreOmitted() {
        // Bytes that aren't a decodable image → nothing to transcode → omitted, never
        // shipped raw (a raw undecodable blob would 400 the whole atomic request).
        let junk = Data([0x00, 0x01, 0x02, 0x03, 0x04])
        let history = [
            userMessage("bad1", at: 1, images: [imageRaw("p.heic", ext: "heic", bytes: junk)]),
            userMessage("bad2", at: 2, images: [imageRaw("g.gif", ext: "gif", bytes: junk)]),
            userMessage("ok", at: 3, images: [image("ok.png")])
        ]
        let r = ChatExecutor.buildHistoryImageBlocks(from: history)
        XCTAssertEqual(imageCount(r), 1, "Only the real png ships")
        XCTAssertEqual(r.omitted, 2, "undecodable blobs can't be transcoded → omitted")
        XCTAssertEqual(r.transcoded, 0)
    }

    func testDecodableUnsupportedFormatIsTranscodedToJPEG() {
        // A REAL TIFF (unsupported wire format, but ImageIO-decodable — HEIC behaves
        // identically on-device) is transcoded to JPEG and ships, instead of being
        // omitted. Core of the "HEIC just works" fix on the history path.
        let tiff = Self.makeImageBytes(utType: .tiff)
        XCTAssertFalse(tiff.isEmpty, "precondition: synthesized real TIFF bytes")
        let history = [userMessage("shot", at: 1, images: [imageRaw("shot.tiff", ext: "tiff", bytes: tiff)])]
        let r = ChatExecutor.buildHistoryImageBlocks(from: history)
        XCTAssertEqual(imageCount(r), 1, "the decodable TIFF is transcoded and ships")
        XCTAssertEqual(r.transcoded, 1)
        XCTAssertEqual(r.omitted, 0)
        guard case .image(let payload)? = r.blocks.first,
              case .ephemeralData(let data) = payload.reference else {
            return XCTFail("expected a transcoded ephemeral image")
        }
        XCTAssertEqual(payload.mimeType, "image/jpeg", "transcoded blocks carry the JPEG mime")
        XCTAssertEqual(Array(data.prefix(2)), [0xFF, 0xD8], "output carries the JPEG SOI marker")
    }

    func testMimeComesFromBytesNotExtension() {
        // The whole point of the byte-truthful fix: a file NAMED .png but holding real
        // JPEG bytes ships as image/jpeg (from the bytes), NOT image/png (from the name).
        // The reverse — a .jpg holding HEIC — is what used to 400 the conversation.
        let jpeg = Self.makeImageBytes(utType: .jpeg)
        let file = imageRaw("mislabeled.png", ext: "png", bytes: jpeg)
        let r = ChatExecutor.buildHistoryImageBlocks(from: [userMessage("q", at: 1, images: [file])])
        guard case .image(let payload)? = r.blocks.first else { return XCTFail("expected an image block") }
        XCTAssertEqual(payload.mimeType, "image/jpeg", "mime derives from the real container, not the .png extension")
        XCTAssertEqual(r.transcoded, 0, "already-JPEG bytes pass through, not re-encoded")
    }

    // MARK: - Bytes-first resolution

    func testPrefersPersistedBytesOverStaleDiskPath() {
        let bytes = Self.makeImageBytes(utType: .png)
        let file = AttachedImageFile(name: "gone.png",
                                     url: URL(fileURLWithPath: "/nonexistent/gone.png"),
                                     fileExtension: "png", binaryData: bytes, size: Int64(bytes.count))
        let r = ChatExecutor.buildHistoryImageBlocks(from: [userMessage("q", at: 1, images: [file])])
        guard case .image(let payload)? = r.blocks.first,
              case .ephemeralData(let data) = payload.reference else {
            return XCTFail("expected an ephemeralData reference")
        }
        XCTAssertEqual(data, bytes, "Persisted bytes (passed through) win over a stale disk path")
    }

    func testFallsBackToDiskPathWhenNoBytes() {
        // No persisted bytes → can't sniff/transcode → extension decides passthrough.
        let file = AttachedImageFile(name: "empty.png", url: URL(fileURLWithPath: "/tmp/empty.png"),
                                     fileExtension: "png", binaryData: Data(), size: 0)
        let r = ChatExecutor.buildHistoryImageBlocks(from: [userMessage("q", at: 1, images: [file])])
        guard case .image(let payload)? = r.blocks.first,
              case .diskPath(let url) = payload.reference else {
            return XCTFail("expected a diskPath fallback")
        }
        XCTAssertEqual(url.lastPathComponent, "empty.png")
    }

    func testNoBytesUnsupportedExtensionIsOmitted() {
        // No persisted bytes AND an unsupported extension → nothing to ship, omitted.
        let file = AttachedImageFile(name: "gone.heic", url: URL(fileURLWithPath: "/tmp/gone.heic"),
                                     fileExtension: "heic", binaryData: Data(), size: 0)
        let r = ChatExecutor.buildHistoryImageBlocks(from: [userMessage("q", at: 1, images: [file])])
        XCTAssertEqual(imageCount(r), 0)
        XCTAssertEqual(r.omitted, 1)
    }

    // MARK: - Recency window

    func testBoundedToRecentWindow() {
        var history: [ChatMessage] = []
        for i in 0..<30 { history.append(userMessage("m\(i)", at: TimeInterval(i), images: [image("i\(i).png")])) }
        let r = ChatExecutor.buildHistoryImageBlocks(from: history, window: 5)
        XCTAssertEqual(imageCount(r), 5, "Only the most recent 5 messages contribute images")
    }

    func testTextOnlyHistoryYieldsNoImages() {
        let history = [userMessage("hi", at: 1), agentMessage("hello", at: 2)]
        let r = ChatExecutor.buildHistoryImageBlocks(from: history)
        XCTAssertEqual(imageCount(r), 0)
        XCTAssertEqual(r.omitted, 0)
    }

    // MARK: - Fit gauge: vision bots now count history images (incl. transcodable)

    func testVisionBotCarriesHistoryImages_gaugeCounts() {
        let history = [userMessage("q", at: 1, images: [image("a.png")])]
        let tokens = PromptFitCheck.estimatedHistoryImageTokens(in: history, provider: .ollama)
        XCTAssertGreaterThan(tokens, 0, "A vision bot's prior-turn image consumes context and must be counted")
    }

    func testGaugeCountsTranscodableFormats() {
        // HEIC ships (as JPEG) now, so the gauge must count it too — the fit estimate uses
        // the cheap extension proxy `isVisionEligible`, no bytes needed.
        let history = [userMessage("q", at: 1, images: [imageRaw("shot.heic", ext: "heic", bytes: Data([0x00]))])]
        let tokens = PromptFitCheck.estimatedHistoryImageTokens(in: history, provider: .ollama)
        XCTAssertGreaterThan(tokens, 0, "HEIC ships as JPEG and must be counted by the gauge")
    }
}
