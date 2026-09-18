// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
//
//  RenderCostRegressionTests.swift
//  DevgenticTests
//
//  Pins two 2026-07-16 self-inflicted perf regressions. Both are invisible to plain
//  unit construction — they only appear when the view is MOUNTED and re-rendered,
//  which is exactly how they shipped.
//
//  1. MarkdownTableView measured every visible cell on each `body` pass, and hover
//     state lived on that same view — so moving the mouse between rows re-measured
//     the whole table.
//  2. ImageView decoded the bitmap in `init` via `State(initialValue:)`, which
//     EVALUATES on every init (only the first is retained) — so a parent re-render
//     re-decoded the full payload and threw it away.
//

import XCTest
import SwiftUI
@testable import devgentic

@MainActor
final class RenderCostRegressionTests: XCTestCase {

    private func host<V: View>(_ root: V, height: CGFloat = 900) -> (NSWindow, NSHostingView<V>) {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 900, height: height),
            styleMask: [.borderless], backing: .buffered, defer: false
        )
        let hosting = NSHostingView(rootView: root)
        hosting.frame = NSRect(x: 0, y: 0, width: 900, height: height)
        window.contentView = hosting
        hosting.layoutSubtreeIfNeeded()
        return (window, hosting)
    }

    // MARK: - 1. Table hover must not re-measure

    /// Hover state must not live on the view that measures columns. We can't observe
    /// "did it re-measure" directly, so we assert the structural property that caused
    /// it: `MarkdownTableView` must expose no row-hover state of its own.
    func testTableViewOwnsNoHoverState() {
        let view = MarkdownTableView(
            headers: ["File", "Purpose"],
            rows: (0..<30).map { ["file\($0).swift", "Purpose number \($0)"] }
        )
        let mirrorLabels = Mirror(reflecting: view).children.compactMap(\.label)
        XCTAssertFalse(
            mirrorLabels.contains { $0.lowercased().contains("hover") },
            "Row hover must live on the row view, not on the measuring parent — \(mirrorLabels)"
        )
    }

    /// A repeatedly re-rendered table (the shape of a streaming flush) must stay
    /// responsive. Guards against measurement cost exploding per render.
    func testRepeatedTableRendersStayCheap() {
        struct Harness: View {
            let tick: Int
            let rows: [[String]]
            var body: some View {
                MarkdownTableView(headers: ["File", "Purpose", "Notes"], rows: rows)
                    .id("stable")          // stable identity, like a streamed block
                    .opacity(tick == 0 ? 1 : 1)  // force a re-render per tick
            }
        }
        let rows = (0..<40).map { ["file\($0).swift", "Purpose number \($0) of this file", "Some longer note \($0)"] }
        let (window, hosting) = host(Harness(tick: 0, rows: rows))
        defer { window.orderOut(nil) }

        let start = Date()
        for tick in 1...20 {
            hosting.rootView = Harness(tick: tick, rows: rows)
            hosting.layoutSubtreeIfNeeded()
        }
        let elapsed = Date().timeIntervalSince(start)

        // Generous bound — this is a canary for pathological per-render cost, not a
        // microbenchmark. 20 re-renders of a 40-row table should be well under a second.
        XCTAssertLessThan(elapsed, 3.0, "20 table re-renders took \(elapsed)s — measurement cost regressed")
    }

    // MARK: - 2. ImageView must not decode in init

    /// The decisive structural assertion: constructing the image renderer must NOT
    /// resolve or decode. (Retargeted 2026-07-17 from the retired legacy ImageView, whose
    /// `init` once ran `NSImage(data:)` eagerly via `State(initialValue:)` — construction
    /// alone paid the full decode cost on every parent re-render.)
    func testConstructingImageRendererDoesNotDecode() {
        let data = Self.makeRedPNG(width: 1200, height: 1200)
        XCTAssertGreaterThan(data.count, 1000, "Sanity: need a payload big enough that decoding is measurable")
        let artifact = MediaArtifact(kind: .image, reference: .ephemeralData(data), mimeType: "image/png")

        // 200 constructions ≈ what a long stream's re-renders would do.
        let start = Date()
        for _ in 0..<200 {
            _ = MediaArtifactImageView(artifact: artifact)
        }
        let elapsed = Date().timeIntervalSince(start)

        XCTAssertLessThan(elapsed, 0.5,
                          "200 renderer constructions took \(elapsed)s — init is decoding again (it must not)")
    }

    /// The async resolve+decode must ACTUALLY land — moving work off `init` is worthless
    /// if the picture never appears. End-to-end: pure-red PNG bytes → ephemeralData
    /// reference → off-main decode → SwiftUI Image → real pixels. Asserted by rasterising
    /// the hosted view and sampling the centre, because SwiftUI doesn't back an `Image`
    /// with its own NSView layer (walking the view tree for `layer.contents` finds
    /// nothing either way).
    func testMountedImageRendererStillDecodes() {
        let data = Self.makeRedPNG(width: 64, height: 64)
        let artifact = MediaArtifact(kind: .image, reference: .ephemeralData(data), mimeType: "image/png")
        let (window, hosting) = host(MediaArtifactImageView(artifact: artifact).frame(width: 240, height: 240), height: 240)
        window.orderFront(nil)                 // `.task` needs the view to actually appear
        defer { window.orderOut(nil) }

        let deadline = Date().addingTimeInterval(3.0)
        while Date() < deadline, !Self.centreIsRed(hosting) {
            RunLoop.main.run(until: Date().addingTimeInterval(0.02))
        }
        XCTAssertTrue(Self.centreIsRed(hosting),
                      "Async decode never reached the screen — the image would be permanently blank")
    }

    // MARK: - Helpers

    /// Rasterises the view and reports whether its centre pixel is the red test image
    /// (the loading/error placeholders draw grey chrome, never red).
    private static func centreIsRed(_ view: NSView) -> Bool {
        guard view.bounds.width > 2, view.bounds.height > 2,
              let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return false }
        view.cacheDisplay(in: view.bounds, to: rep)
        guard let color = rep.colorAt(x: Int(view.bounds.midX), y: Int(view.bounds.midY))?
            .usingColorSpace(.deviceRGB) else { return false }
        return color.redComponent > 0.6 && color.greenComponent < 0.4 && color.blueComponent < 0.4
    }

    private static func makeRedPNG(width: Int, height: Int) -> Data {
        let image = NSImage(size: NSSize(width: width, height: height))
        image.lockFocus()
        NSColor(srgbRed: 1, green: 0, blue: 0, alpha: 1)
            .drawSwatch(in: NSRect(x: 0, y: 0, width: width, height: height))
        image.unlockFocus()
        guard let tiff = image.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiff),
              let png = bitmap.representation(using: .png, properties: [:]) else {
            return Data()
        }
        return png
    }
}
