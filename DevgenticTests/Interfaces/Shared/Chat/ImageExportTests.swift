// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2026 Raj Singh
//
//  ImageExportTests.swift
//  DevgenticTests
//
//  Pins the save path both renderers now share.
//
//  Before, each had its own copy and each was wrong differently: ImageView wrote the raw
//  payload under a hardcoded ".png" name, so a JPEG became a .png that wasn't a PNG;
//  MediaArtifactImageView always re-encoded to PNG ignoring mimeType, recompressing the
//  image on its way to disk. Both dropped failures with `try?`, and MediaArtifactImageView
//  force-unwrapped the Downloads directory — a crash, to save a picture.
//

import XCTest
import AppKit
@testable import devgentic

final class ImageExportTests: XCTestCase {

    // MARK: - Extension follows the bytes

    /// A declared mimeType is a claim; the bytes are the fact. Providers mislabel.
    func testExtensionIsSniffedFromTheBytesNotTheClaim() {
        let jpeg = Self.makeJPEG()
        XCTAssertEqual(ImageExport.fileExtension(for: jpeg, declaredMimeType: "image/png"), "jpg",
                       "JPEG bytes declared as PNG must still be saved as .jpg")
    }

    func testRecognisesTheFormatsBackendsActuallyReturn() {
        XCTAssertEqual(ImageExport.fileExtension(for: Self.makePNG()), "png")
        XCTAssertEqual(ImageExport.fileExtension(for: Self.makeJPEG()), "jpg")
        XCTAssertEqual(ImageExport.fileExtension(for: Data([0x47, 0x49, 0x46, 0x38, 0x39, 0x61])), "gif")
        XCTAssertEqual(ImageExport.fileExtension(for: Data([0x42, 0x4D, 0x00, 0x00])), "bmp")
    }

    /// WEBP needs bytes 8..12, not just the RIFF prefix — a plain RIFF container isn't one.
    func testWebPNeedsTheFullSignature() {
        var webp = Data([0x52, 0x49, 0x46, 0x46, 0, 0, 0, 0])
        webp.append(contentsOf: [0x57, 0x45, 0x42, 0x50])
        XCTAssertEqual(ImageExport.fileExtension(for: webp), "webp")

        var riffOnly = Data([0x52, 0x49, 0x46, 0x46, 0, 0, 0, 0])
        riffOnly.append(contentsOf: [0x41, 0x56, 0x49, 0x20])   // AVI, not WEBP
        XCTAssertNotEqual(ImageExport.fileExtension(for: riffOnly), "webp")
    }

    /// Unrecognisable bytes fall back to the declared type before defaulting to png.
    func testFallsBackToTheDeclaredMimeTypeThenPng() {
        let junk = Data([0x00, 0x01, 0x02, 0x03, 0x04])
        XCTAssertEqual(ImageExport.fileExtension(for: junk, declaredMimeType: "image/gif"), "gif")
        XCTAssertEqual(ImageExport.fileExtension(for: junk), "png")
        XCTAssertEqual(ImageExport.fileExtension(for: Data()), "png", "Empty data must not crash")
    }

    // MARK: - Writing

    /// The bytes must land byte-identical — no re-encode, no recompression.
    func testSavesTheOriginalBytesVerbatim() throws {
        let original = Self.makeJPEG()
        let url = try ImageExport.saveToDownloads(data: original, baseName: Self.uniqueName())
        defer { try? FileManager.default.removeItem(at: url) }

        XCTAssertEqual(url.pathExtension, "jpg")
        XCTAssertEqual(try Data(contentsOf: url), original, "Payload was altered on the way to disk")
    }

    /// Saving twice must not silently overwrite what the user already has.
    func testSecondSaveDoesNotClobberTheFirst() throws {
        let name = Self.uniqueName()
        let first = try ImageExport.saveToDownloads(data: Self.makePNG(), baseName: name)
        let second = try ImageExport.saveToDownloads(data: Self.makePNG(), baseName: name)
        defer {
            try? FileManager.default.removeItem(at: first)
            try? FileManager.default.removeItem(at: second)
        }
        XCTAssertNotEqual(first, second, "Second save overwrote the first")
        XCTAssertTrue(FileManager.default.fileExists(atPath: first.path))
    }

    /// A write failure must surface as an error, not vanish into `try?`.
    func testWriteFailureThrowsRatherThanFailingSilently() {
        // A name that cannot exist as a file: path separators can't appear in a component.
        XCTAssertThrowsError(
            try ImageExport.saveToDownloads(data: Self.makePNG(), baseName: "\(Self.uniqueName())/nope/deeper")
        ) { error in
            XCTAssertNotNil((error as? LocalizedError)?.errorDescription,
                            "The user needs something readable, not an opaque failure")
        }
    }

    // MARK: - Helpers

    private static func uniqueName() -> String { "devgentic-test-\(UUID().uuidString.prefix(8))" }

    private static func makeImage(_ type: NSBitmapImageRep.FileType) -> Data {
        let image = NSImage(size: NSSize(width: 8, height: 8))
        image.lockFocus()
        NSColor.red.drawSwatch(in: NSRect(x: 0, y: 0, width: 8, height: 8))
        image.unlockFocus()
        guard let tiff = image.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiff),
              let data = bitmap.representation(using: type, properties: [:]) else { return Data() }
        return data
    }

    private static func makePNG() -> Data { makeImage(.png) }
    private static func makeJPEG() -> Data { makeImage(.jpeg) }
}
