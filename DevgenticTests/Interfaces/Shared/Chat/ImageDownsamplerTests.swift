//
//  ImageDownsamplerTests.swift
//  DevgenticTests
//
//  ATT-2 (chat hardening round 3, 2026-07-19): attached images render as bounded
//  thumbnails in the user bubble (`AttachedImageCardView`). The decode must cost
//  what a thumbnail costs — `ImageDownsampler` goes through ImageIO's
//  `CGImageSourceCreateThumbnailAtIndex`, so memory scales with the OUTPUT, not
//  the 12 MB source photo. These tests pin the size bound, aspect preservation,
//  and the nil-on-garbage contract (paired with a valid-input control so a broken
//  harness can't read as a pass).
//

import XCTest
import AppKit
@testable import devgentic

final class ImageDownsamplerTests: XCTestCase {

    /// Real PNG bytes at an exact pixel size — goes through the same ImageIO path
    /// production data does.
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

    private func pixelSize(of image: NSImage) -> (width: Int, height: Int)? {
        guard let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }
        return (cg.width, cg.height)
    }

    // MARK: - Contract

    func testLargeImageDownsamplesWithinBoundPreservingAspect() throws {
        let data = try makePNG(width: 100, height: 60)

        let thumb = ImageDownsampler.thumbnail(from: data, maxDimension: 40)

        let size = try XCTUnwrap(thumb.flatMap(pixelSize(of:)), "Valid PNG must decode — this is the control proving the harness can produce a thumbnail at all")
        XCTAssertLessThanOrEqual(size.width, 40)
        XCTAssertLessThanOrEqual(size.height, 40)
        // 100:60 → longest side 40 → expect ~40×24. Allow ±1 for ImageIO rounding.
        XCTAssertEqual(size.width, 40)
        XCTAssertTrue((23...25).contains(size.height), "Aspect ratio must survive the downsample (got \(size.height))")
    }

    func testSmallImageStaysWithinBound() throws {
        let data = try makePNG(width: 10, height: 6)

        let thumb = ImageDownsampler.thumbnail(from: data, maxDimension: 64)

        let size = try XCTUnwrap(thumb.flatMap(pixelSize(of:)))
        XCTAssertLessThanOrEqual(size.width, 64)
        XCTAssertLessThanOrEqual(size.height, 64)
    }

    // MARK: - Failure paths (each paired against the passing control above)

    func testGarbageDataReturnsNil() {
        // 0x81/0xFF/0xC0 is no known image container.
        let garbage = Data([0x81, 0xFF, 0xC0, 0x00, 0x13, 0x37])

        XCTAssertNil(ImageDownsampler.thumbnail(from: garbage, maxDimension: 64),
                     "Undecodable bytes must yield nil so AttachedImageCardView shows its failure chip instead of a phantom image")
    }

    func testEmptyDataReturnsNil() {
        XCTAssertNil(ImageDownsampler.thumbnail(from: Data(), maxDimension: 64))
    }

    func testNonPositiveDimensionReturnsNil() throws {
        let data = try makePNG(width: 10, height: 10)

        XCTAssertNil(ImageDownsampler.thumbnail(from: data, maxDimension: 0))
        XCTAssertNil(ImageDownsampler.thumbnail(from: data, maxDimension: -5))
    }
}
