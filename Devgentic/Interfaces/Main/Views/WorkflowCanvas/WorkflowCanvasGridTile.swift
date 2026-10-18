// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
//
//  WorkflowCanvasGridTile.swift
//  Devgentic
//
//  Created by Raj Singh.
//

import AppKit
import SwiftUI
import os

private let logger = DGLogger(category: "WorkflowCanvasGridTile")

/// The workflow canvas dot-grid background as a cached, GPU-tiled bitmap filled via `ImagePaint`.
/// Panning is a layer transform with no per-frame grid drawing; the tile is regenerated only when zoom
/// or theme changes.
@MainActor
enum WorkflowGridTile {

    /// Spacing between minor dots before zoom scaling — the grid's one layout constant.
    static let gridSpacing: CGFloat = 20
    /// Every 5th dot in each axis (in ABSOLUTE canvas indices) is a major dot.
    static let majorEvery = 5
    static let minorDotSize: CGFloat = 1.5

    // MARK: - Pure geometry (nonisolated, unit-tested)

    /// Side length of one tile: the smallest multiple of the pattern period (`majorEvery x scaledSpacing`)
    /// that is at least `minimum` points. The tile must be a whole number of periods or the major dots
    /// drift between repetitions.
    nonisolated static func sideLength(scaledSpacing: CGFloat, minimum: CGFloat = 160) -> CGFloat {
        let period = CGFloat(majorEvery) * scaledSpacing
        let multiplier = max(1, (minimum / period).rounded(.up))
        return period * multiplier
    }

    /// Where the tiling starts on screen, given the canvas pan offset.
    /// `truncatingRemainder` keeps the phase in `(-side, side)`; the caller anchors the fill at `phase -
    /// side`.
    nonisolated static func phase(offset: CGFloat, side: CGFloat) -> CGFloat {
        guard side > 0 else { return 0 }
        return offset.truncatingRemainder(dividingBy: side)
    }

    // MARK: - Cached tile

    private struct Key: Equatable {
        let spacing: CGFloat
        let displayScale: CGFloat
        let dot: Color
        let major: Color
    }

    private static var cachedKey: Key?
    private static var cachedImage: CGImage?
    private static var loggedGenerationFailure = false

    /// The tile bitmap for the given zoom and theme, regenerated only when either changes.
    /// The cache key excludes the pan offset, which is applied through `phase(offset:side:)` at the fill
    /// site.
    static func image(scaledSpacing: CGFloat, dotColor: Color, majorDotColor: Color, displayScale: CGFloat) -> CGImage? {
        let key = Key(spacing: scaledSpacing, displayScale: displayScale, dot: dotColor, major: majorDotColor)
        if key == cachedKey, let cachedImage { return cachedImage }

        guard let image = render(scaledSpacing: scaledSpacing, dotColor: dotColor,
                                 majorDotColor: majorDotColor, displayScale: displayScale) else {
            // Once, not per frame — this runs on every body evaluation while the failure persists.
            if !loggedGenerationFailure {
                loggedGenerationFailure = true
                logger.error("[WF_CANVAS] Dot-grid tile generation FAILED (spacing \(scaledSpacing), scale \(displayScale)). CONSEQUENCE: the canvas renders without its dot grid — gradient only. Editing is unaffected.")
            }
            return nil
        }
        cachedKey = key
        cachedImage = image
        return image
    }

    private static func render(scaledSpacing: CGFloat, dotColor: Color, majorDotColor: Color, displayScale: CGFloat) -> CGImage? {
        let side = sideLength(scaledSpacing: scaledSpacing)
        let scale = displayScale > 0 ? displayScale : 2
        let pixels = Int((side * scale).rounded())
        guard pixels > 0, pixels <= 4096,
              let ctx = CGContext(data: nil, width: pixels, height: pixels,
                                  bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
            return nil
        }
        ctx.scaleBy(x: scale, y: scale)

        let dotCG = NSColor(dotColor).cgColor
        let majorCG = NSColor(majorDotColor).cgColor
        let k = Int((side / scaledSpacing).rounded())

        // Inclusive bounds (0...k): half-clipped edge dots pair with the adjacent repetition's half.
        // `k` is a multiple of `majorEvery`, so seams agree; the lattice is flip-symmetric.
        for i in 0...k {
            for j in 0...k {
                let isMajor = i % majorEvery == 0 && j % majorEvery == 0
                let size = isMajor ? minorDotSize * 2 : minorDotSize
                ctx.setFillColor(isMajor ? majorCG : dotCG)
                ctx.fillEllipse(in: CGRect(x: CGFloat(i) * scaledSpacing - size / 2,
                                           y: CGFloat(j) * scaledSpacing - size / 2,
                                           width: size, height: size))
            }
        }
        return ctx.makeImage()
    }
}
