// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
//
//  WorkflowGridTileTests.swift
//  DevgenticTests
//
//  Created by Raj Singh.
//

import XCTest
@testable import devgentic

final class WorkflowGridTileTests: XCTestCase {

    // MARK: - Side length

    /// ⚠️ THE pattern invariant: the tile side must be an exact multiple of the period
    /// (majorEvery × spacing), or the every-5th-dot-is-major rhythm breaks at every tile seam.
    func testSideLengthIsAlwaysAWholeNumberOfPeriods() {
        // The zoom clamp is [0.4, 2.0] → spacing ∈ [8, 40]; probe beyond it on both sides anyway.
        for spacing: CGFloat in [3, 8, 12.5, 20, 33.3, 40, 80] {
            let period = CGFloat(WorkflowGridTile.majorEvery) * spacing
            let side = WorkflowGridTile.sideLength(scaledSpacing: spacing)
            let periods = side / period
            XCTAssertEqual(periods, periods.rounded(), accuracy: 0.0001,
                           "side \(side) at spacing \(spacing) is not a whole number of periods — the major dots drift per repetition")
        }
    }

    func testSideLengthMeetsTheMinimum() {
        for spacing: CGFloat in [8, 20, 40] {
            XCTAssertGreaterThanOrEqual(WorkflowGridTile.sideLength(scaledSpacing: spacing), 160)
        }
    }

    /// A period already over the minimum is used as-is — a needlessly larger tile is regeneration
    /// cost for nothing.
    func testLargePeriodIsNotInflated() {
        // spacing 40 → period 200 ≥ 160 → exactly one period.
        XCTAssertEqual(WorkflowGridTile.sideLength(scaledSpacing: 40), 200)
        // spacing 8 → period 40 → four periods to reach 160.
        XCTAssertEqual(WorkflowGridTile.sideLength(scaledSpacing: 8), 160)
    }

    // MARK: - Phase

    /// The phase is the pan offset folded into one tile — this is what makes the grid MOVE with
    /// the canvas. A fixed phase would read as the graph sliding over a stationary floor.
    func testPhaseFoldsTheOffsetIntoOneTile() {
        XCTAssertEqual(WorkflowGridTile.phase(offset: 130, side: 100), 30)
        XCTAssertEqual(WorkflowGridTile.phase(offset: 100, side: 100), 0)
        XCTAssertEqual(WorkflowGridTile.phase(offset: 0, side: 100), 0)
    }

    /// ⚠️ Negative pan (left/up) yields a NEGATIVE phase — `truncatingRemainder`, not a modulo.
    /// The fill site anchors at `phase − side`, which covers both signs; these pin the range that
    /// anchoring depends on.
    func testNegativeOffsetKeepsPhaseWithinOneTileEitherSide() {
        XCTAssertEqual(WorkflowGridTile.phase(offset: -30, side: 100), -30)
        XCTAssertEqual(WorkflowGridTile.phase(offset: -230, side: 100), -30)
        for offset: CGFloat in [-1234.5, -100, -1, 0, 1, 99.9, 1234.5] {
            let phase = WorkflowGridTile.phase(offset: offset, side: 100)
            XCTAssertGreaterThan(phase, -100)
            XCTAssertLessThan(phase, 100)
        }
    }

    /// Coverage arithmetic the fill site relies on: a rect of `viewport + 2×side` whose origin is
    /// at `phase − side` spans the whole viewport for ANY phase in (−side, side).
    func testAnchoredRectCoversTheViewportForBothPhaseSigns() {
        let side: CGFloat = 100, viewport: CGFloat = 1440
        for offset: CGFloat in [-3210, -101, -1, 0, 1, 99, 4321] {
            let phase = WorkflowGridTile.phase(offset: offset, side: side)
            let origin = phase - side
            XCTAssertLessThanOrEqual(origin, 0, "grid must start at or left of the viewport edge")
            XCTAssertGreaterThanOrEqual(origin + viewport + 2 * side, viewport,
                                        "grid must reach past the trailing edge (offset \(offset))")
        }
    }

    func testZeroSideDoesNotDivideByZero() {
        XCTAssertEqual(WorkflowGridTile.phase(offset: 42, side: 0), 0)
    }

    // MARK: - Tile bitmap

    @MainActor
    func testTileIsGeneratedAtTheBackingScale() {
        let tile = WorkflowGridTile.image(scaledSpacing: 20, dotColor: .gray,
                                          majorDotColor: .blue, displayScale: 2)
        XCTAssertNotNil(tile)
        // spacing 20 → period 100 → side 200pt → 400px at 2x.
        XCTAssertEqual(tile?.width, 400)
        XCTAssertEqual(tile?.height, 400)
    }

    @MainActor
    func testTileIsCachedForIdenticalInputsAndRegeneratedOnChange() {
        let a = WorkflowGridTile.image(scaledSpacing: 20, dotColor: .gray,
                                       majorDotColor: .blue, displayScale: 2)
        let b = WorkflowGridTile.image(scaledSpacing: 20, dotColor: .gray,
                                       majorDotColor: .blue, displayScale: 2)
        XCTAssertTrue(a === b, "same zoom + theme must reuse the cached bitmap — pan must never regenerate")

        let c = WorkflowGridTile.image(scaledSpacing: 10, dotColor: .gray,
                                       majorDotColor: .blue, displayScale: 2)
        XCTAssertNotNil(c)
        XCTAssertFalse(a === c, "a zoom change is a different tile")
    }
}
