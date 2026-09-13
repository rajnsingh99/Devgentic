// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2026 Raj Singh
//
//  TokenUsageBadgeSpeechTests.swift
//  DevgenticTests
//
//  Register CF-41 — what VoiceOver is told about a token-usage badge.
//
//  The label was the constant-shaped "Token usage: \(inputTokens) input, \(outputTokens) output":
//  it never consulted `isEstimated`, so a locally-guessed figure was read out as an exact one,
//  and it read the raw integer where the badge itself shows "1.2K".
//

import XCTest
@testable import devgentic

final class TokenUsageBadgeSpeechTests: XCTestCase {

    // MARK: - The estimate marker

    /// ⚠️ THE CF-41 PIN. `~` is the ONLY thing separating a guess from a provider-reported count,
    /// and VoiceOver does not pronounce it — so the label carries it as a word.
    func testEstimatedUsageIsSpokenAsEstimated() {
        let usage = TokenUsage(inputTokens: 1183, outputTokens: 412, isEstimated: true)
        XCTAssertEqual(TokenUsageBadge.spokenLabel(for: usage),
                       "Estimated token usage: 1.2 thousand input, 412 output")
    }

    /// A provider-reported count must NOT be hedged — the badge doesn't hedge it either.
    func testReportedUsageIsNotSpokenAsEstimated() {
        let usage = TokenUsage(inputTokens: 1183, outputTokens: 412, isEstimated: false)
        XCTAssertEqual(TokenUsageBadge.spokenLabel(for: usage),
                       "Token usage: 1.2 thousand input, 412 output")
    }

    /// The two renderings describe the same figures, so a sighted helper reading the badge and a
    /// VoiceOver user hearing the label cannot disagree about what it says.
    func testBadgeAndLabelDescribeTheSameNumbers() {
        let usage = TokenUsage(inputTokens: 1183, outputTokens: 412, isEstimated: true)
        XCTAssertEqual(TokenUsageBadge.badgeText(for: usage), "~1.2K in \u{00B7} ~412 out")
        XCTAssertTrue(TokenUsageBadge.spokenLabel(for: usage).contains("1.2 thousand"))
        XCTAssertTrue(TokenUsageBadge.spokenLabel(for: usage).contains("412"))
        XCTAssertFalse(TokenUsageBadge.spokenLabel(for: usage).contains("1183"),
                       "The badge never shows the raw integer, so neither may the label.")
    }

    // MARK: - Magnitude

    /// Thresholds are 1,000 and 1,000,000; below the first the count is exact.
    func testAbbreviationThresholds() {
        XCTAssertEqual(TokenUsageBadge.abbreviated(0), "0")
        XCTAssertEqual(TokenUsageBadge.abbreviated(999), "999")
        XCTAssertEqual(TokenUsageBadge.abbreviated(1_000), "1.0K")
        // ⚠️ UPDATED 2026-09-12 (mm-9). This line used to pin "1000.0K" as a known wart —
        // deferred by CF-41, not endorsed by it: CF-41 was about the LABEL disagreeing with the
        // badge, and the wart was left because both renderings said the same wrong thing.
        // `magnitude` now picks its bucket from the ROUNDED value, so the last thousand before a
        // million reads "1.0M". CF-41's invariant is untouched — badge and spoken label still
        // come from that one function, so they still agree.
        XCTAssertEqual(TokenUsageBadge.abbreviated(999_999), "1.0M")
        XCTAssertEqual(TokenUsageBadge.abbreviated(999_949), "999.9K", "…and the bucket below it is unchanged")
        XCTAssertEqual(TokenUsageBadge.abbreviated(1_000_000), "1.0M")
        XCTAssertEqual(TokenUsageBadge.abbreviated(2_500_000), "2.5M")
    }

    /// Same buckets, spelled for speech — "K" and "M" are read as letters.
    func testSpokenFormUsesTheSameBucketsWithWordsForUnits() {
        XCTAssertEqual(TokenUsageBadge.spoken(999), "999")
        XCTAssertEqual(TokenUsageBadge.spoken(1_000), "1.0 thousand")
        XCTAssertEqual(TokenUsageBadge.spoken(2_500_000), "2.5 million")
    }

    /// One decision behind both renderings — if this ever splits, the badge and the label can
    /// disagree about magnitude again.
    func testTheMagnitudeDecisionIsShared() {
        for count in [0, 1, 999, 1_000, 12_345, 999_999, 1_000_000, 7_800_000] {
            let abbreviated = TokenUsageBadge.abbreviated(count)
            let spoken = TokenUsageBadge.spoken(count)
            let numberOnly = abbreviated.replacingOccurrences(of: "K", with: "")
                .replacingOccurrences(of: "M", with: "")
            XCTAssertTrue(spoken.hasPrefix(numberOnly),
                          "badge \(abbreviated) vs spoken \(spoken) for \(count)")
        }
    }
}
