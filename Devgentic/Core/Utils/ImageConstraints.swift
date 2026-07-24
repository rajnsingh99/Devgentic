//
//  ImageConstraints.swift
//  Devgentic
//
//  Multimodal Pipeline Migration — Phase 2
//  Size guards for images sent to local models (MLX/Ollama).
//  Prevents OOM and ensures images fit within model context limits.
//
//  Created by Raj Singh on 15/03/26.
//

import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

enum ImageConstraints {
    static let maxDimensionForLocalModels: Int = 1024
    static let maxBytesForLocalModels: Int = 2_097_152  // 2MB
    static let jpegCompressionQuality: CGFloat = 0.8

    /// [M7] Hard per-image attachment cap. Images larger than this are REJECTED (never modified /
    /// downscaled) at attach and at egress, preventing: a main-thread hitch reading the whole file
    /// on the @MainActor, in-row SQLite bloat / SQLITE_TOOBIG on write, uncompressed-RGBA decode
    /// OOM (MLX), and cloud provider HTTP 400s. Set to the tightest cloud per-image limit
    /// (Anthropic ~5 MB); raise it here to accept larger images at the cost of provider
    /// compatibility. (Deliberately a REJECT cap, not the downscale path above.)
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

    /// Largest edge (px) the format-transcode path below emits. Generous enough to
    /// preserve vision detail on any provider, small enough that the re-encoded JPEG
    /// stays comfortably under `maxAttachmentImageBytes`. NOT the aggressive
    /// `maxDimensionForLocalModels` bound — transcoding is a format fix, not a
    /// size-reduction pass, so it must not gratuitously shrink a cloud-bound image.
    static let transcodeMaxDimension: Int = 2048

    /// Convert arbitrary DECODABLE image bytes (HEIC/HEIF/TIFF/BMP/GIF/…) to JPEG so
    /// every vision provider can load them. WHY THIS EXISTS: HEIC is the macOS/iOS
    /// DEFAULT capture format (Photos, Camera, AirDrop), yet Ollama ships no libheif
    /// and Anthropic/OpenAI reject HEIC/HEIF outright — so a photo sent straight from
    /// the library 400s the request with an opaque "Failed to load image" error.
    ///
    /// Decodes frame 0 only (all a vision model ever sees of an animation), bakes EXIF
    /// orientation into the pixels (`…WithTransform`) so portrait phone photos stay
    /// upright, and bounds the long edge (`transcodeMaxDimension`) so the output can't
    /// blow the attachment cap. Returns `nil` only when ImageIO cannot decode the bytes
    /// at all — the caller then OMITS the image with a log, never ships unusable bytes.
    ///
    /// Already-supported formats (jpeg/png/webp) must NOT be routed here: re-encoding a
    /// clean JPEG is pure loss. `VisionImageFormat.resolveSendable` enforces that.
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

        // Use the container's PRIMARY image, not index 0 — a multi-image HEIF (bursts,
        // Live Photos, HDR gain-map pairs) can carry the display image at a non-zero
        // index; index 0 could transcode a thumbnail or the wrong frame.
        let primary = CGImageSourceGetPrimaryImageIndex(source)
        guard let cgImage = CGImageSourceCreateThumbnailAtIndex(source, primary, options) else {
            return nil
        }
        return recompressAsJPEG(flattenedOpaque(cgImage))
    }

    /// The web MIME for `data` **iff** its real container (sniffed from the bytes, not a
    /// filename) is one every vision provider loads as-is (jpeg/png/webp); otherwise nil.
    /// This is the byte-truthful basis for "can I pass this through untouched?" — a file
    /// named `.jpg` that actually holds HEIC bytes returns nil here and gets transcoded,
    /// closing the "declared JPEG, actually HEIC" 400 that a name-only check would miss.
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

    /// Returns JPEG bytes for any decodable image: the original bytes when they are
    /// ALREADY JPEG (no needless re-encode), a transcode otherwise, or nil when the
    /// bytes can't be decoded at all. Used where the destination MIME is fixed to JPEG
    /// (e.g. the imageGen image-to-image providers), so the label is always truthful.
    static func ensureJPEG(_ data: Data) -> Data? {
        if supportedWebMimeType(for: data) == "image/jpeg" { return data }
        return transcodeToJPEG(data)
    }

    /// JPEG cannot carry alpha, and ImageIO logs a scary-but-benign warning on every
    /// encode — "trying to save an opaque image … with alpha … will double (!!!) the
    /// required memory" — when the decoded image has an unused alpha channel, which HEIC
    /// (and PNG) thumbnails routinely do. Flattening to an opaque RGBX buffer first makes
    /// the transcode silent and produces a correct opaque JPEG. It composites over WHITE
    /// (not the context's default clear/black) so a transparent-background subject — e.g.
    /// a dark logo in a TIFF/GIF — doesn't come out invisible black-on-black.
    /// NOTE: this does NOT save memory — RGBX (`noneSkipLast`) is still 32-bit / 4 bytes
    /// per pixel, same as the alpha buffer; the redraw actually adds a transient bitmap.
    /// The payoff is purely a clean, warning-free, correctly-matted JPEG. No-op when the
    /// image is already opaque, so a genuinely-supported passthrough never reaches it.
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
