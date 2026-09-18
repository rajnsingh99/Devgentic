// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
//
//  WorkflowCanvasGridTile.swift
//  Devgentic
//
//  The dot-grid background as a cached, GPU-tiled bitmap (register WF-CV9).
//
//  The grid used to be a SwiftUI `Canvas` running a nested while-loop that allocated and filled one
//  `Path` per dot, re-executed on EVERY pan and zoom frame: ~47,600 dots on a maximized external
//  display, ~22,500 on a 16" laptop, measured at 64.3 ms/frame at minimum zoom (this session, CG
//  frame of reference) — the grid alone capped panning around 15–20 fps at exactly the moment a
//  user surveys a large graph.
//
//  ⚠️ The register's original fix — batching all dots into one `CGMutablePath` — was MEASURED as a
//  100× PESSIMIZATION (4,730 ms vs 46.8 ms; CoreGraphics scanline-rasterizes every subpath against
//  the whole path's bounding box). Do not resurrect it.
//
//  ⚠️ Per-frame CPU blitting of a cached tile is ALSO not the fix: measured 7.8 ms/frame with
//  interpolation off — compositing the pane's worth of pixels on the CPU is bandwidth-bound no
//  matter how few draw calls issue it. The tile therefore goes to the GPU as an `ImagePaint` fill:
//  panning becomes a layer transform with ZERO per-frame grid CPU, and the only CPU cost left is
//  regenerating the tile itself — 1.19 ms worst case (441 dots at minimum zoom) — which runs only
//  when the zoom level or the theme changes, never on pan.
//

import AppKit
import SwiftUI
import os

private let logger = DGLogger(category: "WorkflowCanvasGridTile")

@MainActor
enum WorkflowGridTile {

    /// Spacing between minor dots before zoom scaling — the grid's one layout constant.
    static let gridSpacing: CGFloat = 20
    /// Every 5th dot in each axis (in ABSOLUTE canvas indices) is a major dot.
    static let majorEvery = 5
    static let minorDotSize: CGFloat = 1.5

    // MARK: - Pure geometry (nonisolated, unit-tested)

    /// Side length of one tile: the smallest multiple of the pattern period that is at least
    /// `minimum` points.
    ///
    /// ⚠️ MUST be an exact multiple of the period (`majorEvery × scaledSpacing`). The major-dot
    /// pattern repeats every 5 minor dots, so a tile that is not a whole number of periods puts the
    /// major dots at a different offset in every repetition — a visibly drifting grid. The minimum
    /// exists because a small tile at low zoom means many GPU repeats and, worse, frequent
    /// regeneration cost dominated by fixed overhead; ~160pt keeps the tile count and the dot count
    /// per tile both modest across the whole zoom range (clamped to [0.4, 2.0] by `updateScale`).
    nonisolated static func sideLength(scaledSpacing: CGFloat, minimum: CGFloat = 160) -> CGFloat {
        let period = CGFloat(majorEvery) * scaledSpacing
        let multiplier = max(1, (minimum / period).rounded(.up))
        return period * multiplier
    }

    /// Where the tiling starts on screen, given the canvas pan offset.
    ///
    /// `truncatingRemainder` keeps the phase in `(-side, side)`; the caller anchors the fill at
    /// `phase - side` so both signs of pan are covered. This is what makes the grid MOVE with the
    /// canvas — a fixed phase would read as the graph sliding over a stationary floor.
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
    ///
    /// Pan does not touch this — the cache key deliberately excludes the offset, because the offset
    /// is expressed entirely through `phase(offset:side:)` at the fill site.
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

        // ⚠️ INCLUSIVE bounds (0...k). The dots on the tile's edges are clipped in half by the
        // bitmap; the adjacent repetition supplies the other half. Excluding either edge leaves a
        // row of half-dots at every tile seam. `k` is a multiple of `majorEvery` (sideLength
        // guarantees it), so the edge dot at index k is major exactly when the next tile's index-0
        // dot is — the seams agree.
        //
        // Flip note: this pattern is invariant under the CG/SwiftUI vertical-axis disagreement.
        // Dots sit ON the lattice including both edges, so a flip maps row j to row k-j — the same
        // lattice — and circles are symmetric. No flip transform is needed; if the pattern ever
        // gains an asymmetric element, one becomes necessary.
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
