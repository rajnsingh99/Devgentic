// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
//
//  FullSizeImageDecodeTests.swift
//  DevgenticTests
//
//  [CF-23] Both image renderers decoded the full-size picture as
//  `Task.detached { NSImage(data: data) }`, under a comment claiming this kept a large artifact
//  from stalling the bubble. It did not: `NSImage(data:)` only reads headers — measured at
//  ~0.2 ms for a 4000×3000 JPEG whose real decode is ~60 ms — and materialises the pixels on
//  FIRST DRAW, inside `Image(nsImage:)`, on the main thread. The hop moved the cheap half.
//
//  `ImageDownsampler.fullSize` replaces it, going through the same ImageIO path
//  `ImageDownsampler.thumbnail` already used but unbounded, with
//  `kCGImageSourceShouldCacheImmediately` so the pixels are produced on the caller's thread.
//
//  ⚠️ Two of these tests are REGRESSION guards, not fixes. `NSImage(data:)` already honoured
//  EXIF orientation and already reported true pixel dimensions; the naive replacements
//  (`CGImageSourceCreateImageAtIndex`, and `NSImage(cgImage:size:)`) quietly break both. They
//  are pinned here because the change is where they would have been lost.
//

import XCTest
import AppKit
import ImageIO
import UniformTypeIdentifiers
@testable import devgentic

final class FullSizeImageDecodeTests: XCTestCase {

    // MARK: - Fixtures

    private func makePNG(width: Int, height: Int) throws -> Data {
        guard let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
        ) else { throw XCTSkip("Could not create bitmap rep") }
        guard let png = rep.representation(using: .png, properties: [:]) else {
            throw XCTSkip("Could not encode PNG")
        }
        return png
    }

    /// A JPEG carrying an explicit EXIF orientation tag. 6 means "rotate 90° clockwise for
    /// display", so a 100×60 source is a 60×100 picture.
    private func makeJPEG(width: Int, height: Int, orientation: Int) throws -> Data {
        guard let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height,
            bitsPerSample: 8, samplesPerPixel: 3, hasAlpha: false, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
        ), let cgImage = rep.cgImage else { throw XCTSkip("Could not create bitmap rep") }

        let out = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            out, UTType.jpeg.identifier as CFString, 1, nil
        ) else { throw XCTSkip("Could not create JPEG destination") }
        CGImageDestinationAddImage(destination, cgImage,
                                   [kCGImagePropertyOrientation: orientation] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { throw XCTSkip("Could not encode JPEG") }
        return out as Data
    }

    private func pixelSize(of image: NSImage) -> (width: Int, height: Int)? {
        guard let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }
        return (cgImage.width, cgImage.height)
    }

    // MARK: - Full resolution

    /// The point of `fullSize` versus `thumbnail`: nothing is downsampled. The bound handed to
    /// ImageIO is the source's OWN longest side, so a 3000×1800 photo comes back 3000×1800.
    func testFullSizeDecodeKeepsEveryPixel() throws {
        let data = try makePNG(width: 3000, height: 1800)

        let image = try XCTUnwrap(ImageDownsampler.fullSize(from: data),
                                  "Valid PNG must decode — the control proving the harness works at all")

        let size = try XCTUnwrap(pixelSize(of: image))
        XCTAssertEqual(size.width, 3000)
        XCTAssertEqual(size.height, 1800)
    }

    /// Undecodable bytes return nil rather than an empty image, so the callers' "decode failed"
    /// alerts and logs still fire. Paired with the control above, so a broken harness cannot
    /// read as a pass.
    func testGarbageBytesReturnNil() {
        XCTAssertNil(ImageDownsampler.fullSize(from: Data([0x00, 0x01, 0x02, 0x03, 0x04])))
        XCTAssertNil(ImageDownsampler.fullSize(from: Data()))
    }

    // MARK: - Regression guard: EXIF orientation

    /// ⚠️ NOT a fix — a guard. `NSImage(data:)` already applied the orientation tag, so the
    /// register's suggested `CGImageSourceCreateImageAtIndex` (which does NOT) would have
    /// started serving rotated photos to the lightbox and the clipboard while "fixing" the
    /// decode. A 100×60 source tagged orientation 6 is a 60×100 picture, and both routes must
    /// agree on that.
    func testOrientationTagIsAppliedJustAsNSImageDataDid() throws {
        let data = try makeJPEG(width: 100, height: 60, orientation: 6)

        let viaImageIO = try XCTUnwrap(ImageDownsampler.fullSize(from: data))
        let viaNSImage = try XCTUnwrap(NSImage(data: data))

        let decoded = try XCTUnwrap(pixelSize(of: viaImageIO))
        let reference = try XCTUnwrap(pixelSize(of: viaNSImage))

        XCTAssertEqual(decoded.width, 60, "Orientation 6 turns a 100×60 source into a 60×100 picture")
        XCTAssertEqual(decoded.height, 100)
        XCTAssertEqual(decoded.width, reference.width, "The new decode must not rotate what the old one did not")
        XCTAssertEqual(decoded.height, reference.height)
    }

    /// The untagged control: an orientation-1 image must come back exactly as authored, so the
    /// transform flag cannot be rotating things on its own.
    func testUntaggedImageIsNotRotated() throws {
        let data = try makeJPEG(width: 100, height: 60, orientation: 1)

        let image = try XCTUnwrap(ImageDownsampler.fullSize(from: data))

        let size = try XCTUnwrap(pixelSize(of: image))
        XCTAssertEqual(size.width, 100)
        XCTAssertEqual(size.height, 60)
    }

    // MARK: - Regression guard: the dimensions the lightbox captions

    /// ⚠️ NOT a fix — a guard, and the reason `fullSize` wraps its CGImage in an
    /// `NSBitmapImageRep` instead of the one-liner `NSImage(cgImage:size:)`.
    ///
    /// `ImageLightbox.pixelSize` captions the photo from `representations.first.pixelsWide/High`.
    /// `NSImage(cgImage:size:)` produces an `NSCGImageSnapshotRep` that reports those multiplied
    /// by the display's backing scale — 120×200 for this 60×100 image on a 2× screen — so the
    /// caption would have started lying on every Retina Mac.
    ///
    /// On a 1× display this passes either way; it discriminates on the Retina hardware the app
    /// actually ships to.
    func testRepresentationReportsTruePixelsForTheLightboxCaption() throws {
        let data = try makeJPEG(width: 100, height: 60, orientation: 6)

        let image = try XCTUnwrap(ImageDownsampler.fullSize(from: data))
        let rep = try XCTUnwrap(image.representations.first)

        XCTAssertEqual(rep.pixelsWide, 60, "The lightbox reads this to caption the photo")
        XCTAssertEqual(rep.pixelsHigh, 100)
        XCTAssertEqual(image.size, NSSize(width: 60, height: 100), "Points must match pixels so the sheet lays out at 1:1")
    }

    // MARK: - Eagerness

    /// The row itself: the decode must HAPPEN here, not at first draw. `NSImage(data:)` returns
    /// in a fraction of a millisecond because it defers the work; `fullSize` pays for the pixels
    /// up front, on this thread — which is why the callers keep it inside `Task.detached`.
    ///
    /// Measured ratio on a 4000×3000 JPEG is roughly 300× (0.2 ms vs 60 ms). The assertion
    /// demands only 4×, and takes the best of five samples for the lazy baseline, so ordinary
    /// machine load cannot close the gap. A `fullSize` that had gone back to deferring its
    /// decode would land at ~1×.
    func testFullSizeActuallyDecodesInsteadOfDeferring() throws {
        let data = try makeJPEG(width: 4000, height: 3000, orientation: 1)

        var lazyBest = Double.greatestFiniteMagnitude
        for _ in 0..<5 {
            let start = CFAbsoluteTimeGetCurrent()
            _ = NSImage(data: data)
            lazyBest = min(lazyBest, CFAbsoluteTimeGetCurrent() - start)
        }

        let start = CFAbsoluteTimeGetCurrent()
        let eager = ImageDownsampler.fullSize(from: data)
        let eagerElapsed = CFAbsoluteTimeGetCurrent() - start

        XCTAssertNotNil(eager)
        XCTAssertGreaterThan(eagerElapsed, lazyBest * 4,
                             "fullSize took \(eagerElapsed * 1000) ms against a deferred \(lazyBest * 1000) ms — it is not decoding here, so the cost has moved back to the main thread's first draw")
    }
}
