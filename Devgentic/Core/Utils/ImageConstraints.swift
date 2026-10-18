// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
//
//  ImageConstraints.swift
//  Devgentic
//
//  Created by Raj Singh.
//

import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

/// Size guards for images sent to local models (MLX/Ollama), preventing OOM and keeping images within
/// context limits.
enum ImageConstraints {
    static let maxDimensionForLocalModels: Int = 1024
    static let maxBytesForLocalModels: Int = 2_097_152  // 2MB
    static let jpegCompressionQuality: CGFloat = 0.8

    /// Hard per-image attachment cap: larger images are rejected, never downscaled, at attach and at
    /// egress. Set to the tightest cloud limit (Anthropic ~5 MB); raising it risks provider HTTP 400s,
    /// SQLite size errors and decode OOM.
    static let maxAttachmentImageBytes: Int64 = 5 * 1024 * 1024  // 5 MB

    /// Downscale and compress an image if it exceeds local model limits.
    /// Returns the original data if already within bounds.
    static func constrainForLocalModel(_ data: Data, mimeType: String) -> Data {
        guard data.count > maxBytesForLocalModels else { return data }

        // Attempt to downscale via CGImage
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let cgImage = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
            return data
        }

        let width = cgImage.width
        let height = cgImage.height
        let maxDim = max(width, height)

        guard maxDim > maxDimensionForLocalModels else {
            // Image is small enough dimensionally — just re-compress as JPEG
            return recompressAsJPEG(cgImage) ?? data
        }

        let scale = Double(maxDimensionForLocalModels) / Double(maxDim)
        let newWidth = Int(Double(width) * scale)
        let newHeight = Int(Double(height) * scale)

        guard let context = CGContext(
            data: nil,
            width: newWidth,
            height: newHeight,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            return data
        }

        context.interpolationQuality = .high
        context.draw(cgImage, in: CGRect(x: 0, y: 0, width: newWidth, height: newHeight))

        guard let scaledImage = context.makeImage() else { return data }

        return recompressAsJPEG(scaledImage) ?? data
    }

    /// Largest edge (px) the format-transcode path emits: enough to keep vision detail, small enough to
    /// stay under the attachment cap. Transcoding is a format fix, not a size-reduction pass.
    static let transcodeMaxDimension: Int = 2048

    /// Converts decodable image bytes (HEIC/HEIF/TIFF/BMP/GIF) to JPEG so every vision provider can load
    /// them. Decodes frame 0 only, bakes EXIF orientation into the pixels and bounds the long edge.
    /// Returns `nil` only when ImageIO cannot decode the bytes. JPEG, PNG and WebP must not be routed here.
    static func transcodeToJPEG(_ data: Data) -> Data? {
        guard let source = CGImageSourceCreateWithData(
            data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary
        ) else { return nil }

        let options = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,   // bake EXIF orientation
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: transcodeMaxDimension
        ] as [CFString: Any] as CFDictionary

        // Uses the container's primary image, not index 0: a multi-image HEIF can carry the display image at a
        // non-zero index.
        let primary = CGImageSourceGetPrimaryImageIndex(source)
        guard let cgImage = CGImageSourceCreateThumbnailAtIndex(source, primary, options) else {
            return nil
        }
        return recompressAsJPEG(flattenedOpaque(cgImage))
    }

    /// The web MIME for `data` if its sniffed container is one every vision provider loads as-is
    /// (jpeg/png/webp), else nil. Byte-truthful: a `.jpg` that actually holds HEIC returns nil and is
    /// transcoded.
    static func supportedWebMimeType(for data: Data) -> String? {
        guard let source = CGImageSourceCreateWithData(
            data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary
        ), let uti = CGImageSourceGetType(source) as String? else { return nil }
        switch uti {
        case UTType.jpeg.identifier: return "image/jpeg"
        case UTType.png.identifier:  return "image/png"
        case UTType.webP.identifier: return "image/webp"
        default:                     return nil
        }
    }

    /// Returns JPEG bytes for any decodable image: the original if already JPEG, a transcode otherwise, or
    /// nil if undecodable. For destinations whose MIME is fixed to JPEG, such as the imageGen
    /// image-to-image providers.
    static func ensureJPEG(_ data: Data) -> Data? {
        if supportedWebMimeType(for: data) == "image/jpeg" { return data }
        return transcodeToJPEG(data)
    }

    /// Flattens an image to an opaque RGBX buffer, compositing over white, before JPEG encoding.
    /// Silences ImageIO's alpha warning and keeps transparent-background subjects visible; it does not save
    /// memory.
    private static func flattenedOpaque(_ image: CGImage) -> CGImage {
        switch image.alphaInfo {
        case .none, .noneSkipLast, .noneSkipFirst:
            return image                       // already opaque — nothing to flatten
        default:
            break
        }
        guard let ctx = CGContext(
            data: nil, width: image.width, height: image.height,
            bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue   // RGBX, no alpha
        ) else { return image }
        let rect = CGRect(x: 0, y: 0, width: image.width, height: image.height)
        ctx.setFillColor(CGColor(gray: 1, alpha: 1))            // white matte
        ctx.fill(rect)
        ctx.draw(image, in: rect)
        return ctx.makeImage() ?? image
    }

    private static func recompressAsJPEG(_ image: CGImage) -> Data? {
        let mutableData = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(mutableData, "public.jpeg" as CFString, 1, nil) else {
            return nil
        }
        let options: [CFString: Any] = [
            kCGImageDestinationLossyCompressionQuality: jpegCompressionQuality
        ]
        CGImageDestinationAddImage(destination, image, options as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return mutableData as Data
    }
}
