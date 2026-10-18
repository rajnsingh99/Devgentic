// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
//
//  ImageDownsampler.swift
//  Devgentic
//
//  Created by Raj Singh.
//

import AppKit
import ImageIO

/// ImageIO decoding for chat pictures: turns bytes into an NSImage at thumbnail size or full size.
/// `thumbnail` decodes straight to the target size, so memory scales with the output rather than the
/// source.
enum ImageDownsampler {

    /// Decodes `data` into an `NSImage` whose longest side is at most `maxDimension` pixels, EXIF
    /// orientation applied. Returns `nil` for undecodable data or a non-positive dimension.
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

    // Why: `NSImage(data:)` decodes lazily on first draw, on the main thread; call this from a detached task.
    /// Decodes `data` at full resolution, eagerly, with EXIF orientation applied; returns nil for
    /// undecodable data. Multi-frame sources (animated GIF) decode frame 0.
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
        // Without an explicit bound ImageIO may cap the result, so the source's longest side is passed.
        // If properties cannot be read the request is unbounded rather than guessing a size.
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
