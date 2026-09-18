// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
//
//  ImageDownsampler.swift
//  Devgentic
//
//  ImageIO decoding for chat pictures — the app's one place for "turn these bytes
//  into an NSImage", at thumbnail size or full size.
//
//  `thumbnail` exists because `NSImage(data:)` ends up materialising the FULL bitmap
//  (a 12 MB photo decodes to ~45 MB of pixels); a message can carry several attached
//  photos and a conversation many messages, so thumbnails must cost what a thumbnail
//  costs. `CGImageSourceCreateThumbnailAtIndex` decodes straight to the target size —
//  memory scales with the output, not the source.
//
//  `fullSize` exists because `NSImage(data:)` defers that decode to first DRAW, i.e.
//  onto the main thread — see its doc comment.
//
//  ATT-2 (chat hardening round 3): first consumer is `AttachedImageCardView`,
//  the user-bubble renderer for attached images.
//

import AppKit
import ImageIO

enum ImageDownsampler {

    /// Decodes `data` into an `NSImage` whose longest side is at most `maxDimension`
    /// pixels. EXIF orientation is baked in (`kCGImageSourceCreateThumbnailWithTransform`),
    /// so portrait phone photos come out upright. Returns `nil` for undecodable data
    /// or a non-positive dimension.
    static func thumbnail(from data: Data, maxDimension: CGFloat) -> NSImage? {
        guard maxDimension > 0 else { return nil }

        let sourceOptions = [kCGImageSourceShouldCache: false] as CFDictionary
        guard let source = CGImageSourceCreateWithData(data as CFData, sourceOptions) else {
            return nil
        }

        let thumbnailOptions = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: maxDimension
        ] as [CFString: Any] as CFDictionary

        guard let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, thumbnailOptions) else {
            return nil
        }
        return NSImage(cgImage: cgImage, size: NSSize(width: cgImage.width, height: cgImage.height))
    }

    /// Decodes `data` at FULL resolution, EAGERLY, with EXIF orientation applied.
    ///
    /// [CF-23] Exists because `NSImage(data:)` decodes lazily: constructing one from a 4000×3000
    /// JPEG takes ~0.2 ms because it only reads headers, and the ~60 ms that actually turns the
    /// bytes into pixels happens at FIRST DRAW — inside `Image(nsImage:)`, on the main thread.
    /// Wrapping `NSImage(data:)` in a `Task.detached` therefore moved the 0.2 ms off-main and
    /// left the 60 ms exactly where it was stalling the transcript. `…ShouldCacheImmediately`
    /// forces the pixels NOW, on the caller's thread — so callers MUST keep calling this from a
    /// detached task, or the stall simply moves back.
    ///
    /// ⚠️ `…WithTransform` is PRESERVATION, not a fix: `NSImage(data:)` already honours the EXIF
    /// orientation tag (a 100×60 JPEG tagged orientation 6 arrives as 60×100, and pastes that
    /// way), so a plain `CGImageSourceCreateImageAtIndex` here — which does NOT apply it — would
    /// have introduced rotated lightbox photos while fixing the decode. Do not drop the flag.
    ///
    /// ⚠️ The result is wrapped through `NSBitmapImageRep` rather than `NSImage(cgImage:size:)`
    /// for the same "don't regress what worked" reason: the latter produces an
    /// `NSCGImageSnapshotRep` that reports `pixelsWide/High` multiplied by the display's backing
    /// scale (120×200 for a 60×100 image on a 2× screen), and `ImageLightbox` captions the photo
    /// from exactly that property.
    ///
    /// Returns nil for undecodable data. Multi-frame sources (an animated GIF) decode frame 0;
    /// SwiftUI's `Image(nsImage:)` does not animate, so nothing is lost that was ever shown.
    static func fullSize(from data: Data) -> NSImage? {
        let sourceOptions = [kCGImageSourceShouldCache: false] as CFDictionary
        guard let source = CGImageSourceCreateWithData(data as CFData, sourceOptions) else {
            return nil
        }

        var options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true
        ]
        // Without an explicit bound ImageIO is free to cap the result; the source's own longest
        // side is the "do not downsample" value. If the properties can't be read we fall back to
        // an unbounded request rather than guessing a size and silently shrinking the picture.
        if let longestSide = pixelLongestSide(of: source) {
            options[kCGImageSourceThumbnailMaxPixelSize] = longestSide
        }

        guard let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
            return nil
        }
        let image = NSImage(size: NSSize(width: cgImage.width, height: cgImage.height))
        image.addRepresentation(NSBitmapImageRep(cgImage: cgImage))
        return image
    }

    /// The longest side of the source image in PIXELS, read from its properties without
    /// decoding it. Nil when the source declares no usable dimensions.
    private static func pixelLongestSide(of source: CGImageSource) -> Int? {
        guard let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int,
              width > 0, height > 0 else { return nil }
        return max(width, height)
    }
}
