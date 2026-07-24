//
//  ImageDownsampler.swift
//  Devgentic
//
//  Bounded-memory thumbnail decoding via ImageIO. `NSImage(data:)` materialises the
//  FULL bitmap (a 12 MB photo decodes to ~45 MB of pixels); a message can carry
//  several attached photos and a conversation many messages, so thumbnails must
//  cost what a thumbnail costs. `CGImageSourceCreateThumbnailAtIndex` decodes
//  straight to the target size — memory scales with the thumbnail, not the source.
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
}
