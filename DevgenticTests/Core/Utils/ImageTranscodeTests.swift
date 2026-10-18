// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
//
//  ImageTranscodeTests.swift
//  DevgenticTests
//
//  Created by Raj Singh.
//

import XCTest
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
@testable import devgentic

final class ImageTranscodeTests: XCTestCase {

    /// Real, decodable image bytes in a given container (with an alpha channel, so the
    /// transcode path exercises the opaque-flatten step).
    private func makeImageBytes(utType: UTType, width: Int = 8, height: Int = 8) -> Data {
        let space = CGColorSpaceCreateDeviceRGB()
        guard let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                                  bytesPerRow: 0, space: space,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return Data() }
        ctx.setFillColor(CGColor(red: 0.9, green: 0.3, blue: 0.2, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        guard let cg = ctx.makeImage() else { return Data() }
        let out = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(out, utType.identifier as CFString, 1, nil) else { return Data() }
        CGImageDestinationAddImage(dest, cg, nil)
        guard CGImageDestinationFinalize(dest) else { return Data() }
        return out as Data
    }

    private func isJPEG(_ data: Data) -> Bool { Array(data.prefix(2)) == [0xFF, 0xD8] }

    // MARK: - ImageConstraints.supportedWebMimeType (byte-based container detection)

    func testSupportedWebMimeType_detectsRealContainer() {
        XCTAssertEqual(ImageConstraints.supportedWebMimeType(for: makeImageBytes(utType: .png)), "image/png")
        XCTAssertEqual(ImageConstraints.supportedWebMimeType(for: makeImageBytes(utType: .jpeg)), "image/jpeg")
        // TIFF is a real image but NOT in the always-loadable set → nil (must transcode).
        XCTAssertNil(ImageConstraints.supportedWebMimeType(for: makeImageBytes(utType: .tiff)))
        // Undecodable bytes → nil.
        XCTAssertNil(ImageConstraints.supportedWebMimeType(for: Data([0x00, 0x01, 0x02])))
    }

    // MARK: - ImageConstraints.transcodeToJPEG

    func testTranscodeToJPEG_realTIFF_producesJPEG() {
        let tiff = makeImageBytes(utType: .tiff)
        XCTAssertFalse(tiff.isEmpty, "precondition: real TIFF bytes")
        XCTAssertFalse(isJPEG(tiff), "precondition: source is NOT already JPEG")
        let out = ImageConstraints.transcodeToJPEG(tiff)
        XCTAssertNotNil(out)
        XCTAssertTrue(isJPEG(out ?? Data()), "TIFF re-encodes to a real JPEG (SOI marker)")
    }

    func testTranscodeToJPEG_undecodableBytes_returnsNil() {
        XCTAssertNil(ImageConstraints.transcodeToJPEG(Data([0xFF, 0xD8])), "2-byte junk isn't decodable")
        XCTAssertNil(ImageConstraints.transcodeToJPEG(Data("not an image".utf8)))
        XCTAssertNil(ImageConstraints.transcodeToJPEG(Data()))
    }

    func testTranscodeBoundsLongEdge() {
        let big = makeImageBytes(utType: .tiff, width: 4000, height: 3000)
        XCTAssertFalse(big.isEmpty)
        guard let jpeg = ImageConstraints.transcodeToJPEG(big),
              let src = CGImageSourceCreateWithData(jpeg as CFData, nil),
              let cg = CGImageSourceCreateImageAtIndex(src, 0, nil) else {
            return XCTFail("expected a decodable transcoded JPEG")
        }
        XCTAssertLessThanOrEqual(max(cg.width, cg.height), ImageConstraints.transcodeMaxDimension,
                                 "long edge is bounded by transcodeMaxDimension")
    }

    // MARK: - ImageConstraints.ensureJPEG

    func testEnsureJPEG_alreadyJPEG_passesThroughUnchanged() {
        let jpeg = makeImageBytes(utType: .jpeg)
        let out = ImageConstraints.ensureJPEG(jpeg)
        XCTAssertEqual(out, jpeg, "an already-JPEG source is not re-encoded")
    }

    func testEnsureJPEG_nonJPEG_transcodes() {
        let png = makeImageBytes(utType: .png)
        guard let out = ImageConstraints.ensureJPEG(png) else { return XCTFail("expected a transcoded JPEG") }
        XCTAssertTrue(isJPEG(out), "a PNG source is normalized to JPEG")
    }

    func testEnsureJPEG_undecodable_returnsNil() {
        XCTAssertNil(ImageConstraints.ensureJPEG(Data([0x01, 0x02, 0x03])))
    }

    // MARK: - VisionImageFormat.resolveSendable (byte-truthful)

    func testResolveSendable_realPNG_passesThroughUntouched() {
        let png = makeImageBytes(utType: .png)
        let r = VisionImageFormat.resolveSendable(data: png)
        XCTAssertEqual(r?.mimeType, "image/png")
        XCTAssertEqual(r?.wasTranscoded, false)
        XCTAssertEqual(r?.data, png, "supported formats are returned verbatim")
    }

    func testResolveSendable_realJPEG_passesThrough() {
        let jpeg = makeImageBytes(utType: .jpeg)
        let r = VisionImageFormat.resolveSendable(data: jpeg)
        XCTAssertEqual(r?.mimeType, "image/jpeg")
        XCTAssertEqual(r?.wasTranscoded, false)
    }

    func testResolveSendable_unsupportedButDecodable_transcodes() {
        let tiff = makeImageBytes(utType: .tiff)
        let r = VisionImageFormat.resolveSendable(data: tiff)
        XCTAssertEqual(r?.mimeType, "image/jpeg")
        XCTAssertEqual(r?.wasTranscoded, true)
        XCTAssertTrue(isJPEG(r?.data ?? Data()))
    }

    func testResolveSendable_unsupportedAndUndecodable_returnsNil() {
        XCTAssertNil(VisionImageFormat.resolveSendable(data: Data([0xFF, 0xD8])))
        XCTAssertNil(VisionImageFormat.resolveSendable(data: Data("garbage".utf8)))
    }

    func testResolveSendable_decisionIsByBytesNotAnyName() {
        // Real JPEG bytes always resolve to image/jpeg passthrough regardless of any
        // (absent) filename — the decision never consults an extension.
        let jpeg = makeImageBytes(utType: .jpeg)
        XCTAssertEqual(VisionImageFormat.resolveSendable(data: jpeg)?.mimeType, "image/jpeg")
    }

    // MARK: - VisionImageFormat.isVisionEligible (fit-gauge proxy)

    func testIsVisionEligible_coversNativeAndTranscodable() {
        for ext in ["jpg", "jpeg", "png", "webp", "heic", "heif", "tiff", "bmp", "gif", "JPG", "HEIC"] {
            XCTAssertTrue(VisionImageFormat.isVisionEligible(fileExtension: ext), "\(ext) should be eligible")
        }
        for ext in ["pdf", "txt", "mp4", "", "doc"] {
            XCTAssertFalse(VisionImageFormat.isVisionEligible(fileExtension: ext), "\(ext) should NOT be eligible")
        }
    }
}
