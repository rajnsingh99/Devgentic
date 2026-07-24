//
//  ContextWindowGaugeTests.swift
//  devgenticTests
//
//  Pure-logic coverage for the composer context-window occupancy gauge: the
//  fraction/percent math, the three threshold bands, display formatting, the
//  over-window clamp, and the cross-model comparison. No view or store is
//  exercised here — `ContextWindowUsage.resolve(...)` is @MainActor and store-backed
//  and is left to on-device verification; this pins the display contract.
//

import XCTest
@testable import devgentic

final class ContextWindowGaugeTests: XCTestCase {

    private func usage(used: Int, window: Int, trained: Int? = nil) -> ContextWindowUsage {
        ContextWindowUsage(
            usedTokens: used,
            windowTokens: window,
            trainedTokens: trained,
            modelName: "test-model",
            provider: nil,
            profileID: nil,
            lastTurn: nil,
            windowIsFallback: false
        )
    }

    // MARK: - Fraction / percent

    func testFractionAndPercentRoundHalfUp() {
        let u = usage(used: 47_000, window: 200_000)
        XCTAssertEqual(u.fraction, 0.235, accuracy: 0.0001)
        XCTAssertEqual(u.percent, 24) // 23.5% rounds to 24
        XCTAssertEqual(u.displayFraction, 0.235, accuracy: 0.0001)
    }

    func testDisplayFractionClampsWhenOverWindow() {
        let u = usage(used: 6_000, window: 4_000)
        XCTAssertEqual(u.fraction, 1.5, accuracy: 0.0001)
        XCTAssertEqual(u.percent, 150)          // raw percent is NOT clamped
        XCTAssertEqual(u.displayFraction, 1.0)  // the bar/ring IS clamped
    }

    func testZeroWindowIsSafe() {
        // EffectiveContextWindow never returns 0, but the display math must not divide by it.
        let u = usage(used: 5_000, window: 0)
        XCTAssertEqual(u.fraction, 0)
        XCTAssertEqual(u.percent, 0)
        XCTAssertEqual(u.displayFraction, 0)
    }

    // MARK: - Threshold bands (normal < 0.75 ≤ high < 1.0 ≤ over)

    func testLevelNormalBelow75() {
        XCTAssertTrue(usage(used: 0, window: 100).level == .normal)
        XCTAssertTrue(usage(used: 74, window: 100).level == .normal)
    }

    func testLevelHighAtAndAbove75() {
        XCTAssertTrue(usage(used: 75, window: 100).level == .high)   // boundary is inclusive
        XCTAssertTrue(usage(used: 99, window: 100).level == .high)
    }

    func testLevelOverAtAndAbove100() {
        XCTAssertTrue(usage(used: 100, window: 100).level == .over)  // exactly full = over
        XCTAssertTrue(usage(used: 250, window: 100).level == .over)
    }

    // MARK: - Display formatting

    func testUsedDisplayEstimatePrefixAndEmpty() {
        XCTAssertEqual(usage(used: 0, window: 200_000).usedDisplay, "0")        // empty prints bare 0
        XCTAssertEqual(usage(used: 47_000, window: 200_000).usedDisplay, "~47K") // otherwise "~" + K
        XCTAssertEqual(usage(used: 500, window: 200_000).usedDisplay, "~500")    // sub-1K prints as-is
    }

    func testWindowDisplay() {
        XCTAssertEqual(usage(used: 1, window: 200_000).windowDisplay, "200K")
        XCTAssertEqual(usage(used: 1, window: 4_096).windowDisplay, "4K")
    }

    // MARK: - Effective vs trained window (the "why 8K not 131K" affordance)

    func testCappedBelowTrainedSurfacesOnlyWhenTrainedExceedsEffective() {
        // Ollama num_ctx capping: effective 8K, model supports 131K → surface 131K.
        XCTAssertEqual(usage(used: 2_000, window: 8_192, trained: 131_072).cappedBelowTrained, 131_072)
        // Cloud / MLX: effective == trained → nothing to surface.
        XCTAssertNil(usage(used: 2_000, window: 200_000, trained: 200_000).cappedBelowTrained)
        // Trained unknown → nothing to surface.
        XCTAssertNil(usage(used: 2_000, window: 8_192, trained: nil).cappedBelowTrained)
        // Trained not greater than effective → nothing to surface.
        XCTAssertNil(usage(used: 2_000, window: 16_384, trained: 8_192).cappedBelowTrained)
    }

}
