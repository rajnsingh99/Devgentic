// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2026 Raj Singh
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

    private func usage(used: Int, window: Int, trained: Int? = nil,
                       lastTurn: TokenUsage? = nil,
                       multiCall: Bool = false,
                       usesRetrieval: Bool = false) -> ContextWindowUsage {
        ContextWindowUsage(
            usedTokens: used,
            windowTokens: window,
            trainedTokens: trained,
            modelName: "test-model",
            provider: nil,
            profileID: nil,
            lastTurn: lastTurn,
            windowIsFallback: false,
            usesRetrieval: usesRetrieval,
            turnSpansMultipleCalls: multiCall
        )
    }

    // MARK: - Ring bands vs the send-time threshold

    /// They used to disagree: the ring reddened at 100% while the banner fired at 75%, so
    /// between those the user saw an amber ring beside a red "will be cut off" advisory.
    func testRingTurnsRedExactlyWhereTheSendTimeCheckFires() {
        let window = 100_000
        let limit = Int(Double(window) * ContextWindowUsage.usableFraction)

        let justUnder = usage(used: limit - 1_000, window: window)
        XCTAssertNotEqual(justUnder.level, .over)
        XCTAssertFalse(PromptFitCheck.exceeds(estimatedTokens: justUnder.usedTokens, windowTokens: window))

        let justOver = usage(used: limit + 1_000, window: window)
        XCTAssertEqual(justOver.level, .over, "red must start where the banner does")
        XCTAssertTrue(PromptFitCheck.exceeds(estimatedTokens: justOver.usedTokens, windowTokens: window))
    }

    /// `.over` now means "past the usable share"; only `exceedsWindow` means the conversation
    /// genuinely outgrew the window. The two notes must not both claim the latter.
    func testOverTheUsableShareIsNotTheSameAsOverTheWindow() {
        let past = usage(used: 80_000, window: 100_000)
        XCTAssertEqual(past.level, .over)
        XCTAssertFalse(past.exceedsWindow, "80% is past the usable share but inside the window")

        XCTAssertTrue(usage(used: 120_000, window: 100_000).exceedsWindow)
    }

    func testUsableFractionTracksTheResponseHeadroom() {
        XCTAssertEqual(ContextWindowUsage.usableFraction, 1.0 - PromptFitCheck.responseHeadroom)
    }

    // MARK: - The two figures measure different things

    /// `usedTokens` estimates ONE next send; `lastTurn.inputTokens` is the measured total
    /// across every model call in a turn. On an agent those diverge by the iteration count,
    /// which read as a contradiction until the breakdown labelled both.
    func testMultiCallProfileIsFlaggedSoTheTwoFiguresCanBeReconciled() {
        let agent = usage(used: 12_000, window: 128_000,
                          lastTurn: TokenUsage(inputTokens: 40_000, outputTokens: 1_000),
                          multiCall: true)
        XCTAssertTrue(agent.turnSpansMultipleCalls)
        XCTAssertGreaterThan(agent.lastTurn?.inputTokens ?? 0, agent.usedTokens,
                             "the sum across steps normally exceeds a single-send estimate")

        let bot = usage(used: 12_000, window: 128_000,
                        lastTurn: TokenUsage(inputTokens: 11_500, outputTokens: 400))
        XCTAssertFalse(bot.turnSpansMultipleCalls, "a bot makes exactly one call per turn")
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

    // MARK: - Threshold bands (normal < 0.8 × usable ≤ high < usable ≤ over)
    // `usable` is `ContextWindowUsage.usableFraction` = 1 − responseHeadroom, so at today's
    // 25% headroom those land at 60% and 75% OF THE WINDOW — not at 75% and 100%. Nothing
    // turns on the full window here; that is `exceedsWindow`, a separate property.

    // Bands are derived from `responseHeadroom` now, not hard-coded at 75/100. They used to
    // reden at 100% while the send-time banner fired at 75%, so 75–100% showed an amber ring
    // beside a red "content will be cut off" advisory.

    func testLevelNormalWellInsideTheUsableShare() {
        XCTAssertEqual(usage(used: 0, window: 100).level, .normal)
        XCTAssertEqual(usage(used: 55, window: 100).level, .normal)   // 55% of a 75% budget
    }

    func testLevelHighWhileApproachingTheUsableLimit() {
        XCTAssertEqual(usage(used: 70, window: 100).level, .high, "past 80% of the usable share")
        XCTAssertEqual(usage(used: 74, window: 100).level, .high)
    }

    /// The alignment that matters: red begins at the usable limit, where the banner fires —
    /// not at the full window, which is 25 points later.
    func testLevelOverFromTheUsableLimitOnward() {
        let limit = Int(ContextWindowUsage.usableFraction * 100)
        XCTAssertEqual(usage(used: limit, window: 100).level, .over, "boundary is inclusive")
        XCTAssertEqual(usage(used: 99, window: 100).level, .over)
        XCTAssertEqual(usage(used: 250, window: 100).level, .over)
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
