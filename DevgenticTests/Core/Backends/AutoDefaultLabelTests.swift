// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
//
//  AutoDefaultLabelTests.swift
//  DevgenticTests
//
//  Created by Raj Singh.
//

import XCTest
@testable import devgentic

final class AutoDefaultLabelTests: XCTestCase {

    // MARK: - The label matches what Auto really resolves to

    /// The migrated-profile case from the register: a legacy knob of 5 was displayed as "Auto (3)".
    func testAutoDefaultFollowsTheProfilesLegacyRetryPolicy() {
        XCTAssertEqual(ResolvedResiliencePolicy.autoDefault(legacy: RetryPolicy(maxRetries: 5)), 5)
        XCTAssertEqual(ResolvedResiliencePolicy.autoDefault(legacy: RetryPolicy(maxRetries: 1)), 1)
    }

    /// A profile that never set one falls back to `RetryPolicy()` — which is where the original
    /// hardcoded 3 came from, so the common case must not change.
    func testAutoDefaultForAProfileWithNoRetryPolicy() {
        XCTAssertEqual(ResolvedResiliencePolicy.autoDefault(legacy: nil), RetryPolicy().maxRetries)
        XCTAssertEqual(ResolvedResiliencePolicy.autoDefault(legacy: nil), 3,
                       "the default is still 3 — A70 was about the label lying for OTHER values")
    }

    /// ⚠️ The assertion that matters: the number the label shows and the number the resolver uses
    /// must be the same for every tier that falls back to the legacy knob. This is what a second
    /// hardcoded literal cannot guarantee.
    func testTheLabelAgreesWithTheResolverForEveryLegacyBackedCap() {
        for maxRetries in [1, 2, 3, 5, 8] {
            let legacy = RetryPolicy(maxRetries: maxRetries)
            let label = ResolvedResiliencePolicy.autoDefault(legacy: legacy)
            let resolved = ResolvedResiliencePolicy.resolved(for: .cloud, overrides: nil, legacy: legacy)

            XCTAssertEqual(resolved.cognitive.maxParseFailures, label,
                           "parse-failure cap disagrees with its own Auto label at \(maxRetries)")
            XCTAssertEqual(resolved.loop.maxConsecutiveToolFailures, label,
                           "tool-failure cap disagrees with its own Auto label at \(maxRetries)")
            XCTAssertEqual(resolved.loop.maxRepetitiveActions, label,
                           "repetition cap disagrees with its own Auto label at \(maxRetries)")
        }
    }

    // MARK: - The denial cap is genuinely constant

    /// ⚠️ The denial cap is the one that was NOT lying: it is never coupled to the legacy knob. Its
    /// literal is now named so the panel states the constant instead of restating the number.
    func testTheDenialCapIgnoresTheLegacyKnob() {
        for maxRetries in [1, 3, 8] {
            let resolved = ResolvedResiliencePolicy.resolved(
                for: .cloud, overrides: nil, legacy: RetryPolicy(maxRetries: maxRetries))

            XCTAssertEqual(resolved.loop.maxConsecutiveDenials,
                           ResolvedResiliencePolicy.defaultMaxConsecutiveDenials,
                           "the denial cap must stay fixed — the user already refused the action")
        }
    }

    func testTheNamedDenialConstantStillMatchesTheShippedValue() {
        XCTAssertEqual(ResolvedResiliencePolicy.defaultMaxConsecutiveDenials, 2,
                       "changing this changes behaviour, not just a label — it is the breaker's cap")
    }

    // MARK: - An explicit override still wins

    /// Auto is a fallback, not a clamp: setting a cap explicitly must override both the legacy knob
    /// and the label's default.
    func testAnExplicitOverrideBeatsTheLegacyKnob() {
        var overrides = ResilienceOverrides()
        overrides.maxParseFailures = 1

        let resolved = ResolvedResiliencePolicy.resolved(
            for: .cloud, overrides: overrides, legacy: RetryPolicy(maxRetries: 8))

        XCTAssertEqual(resolved.cognitive.maxParseFailures, 1)
        XCTAssertEqual(resolved.loop.maxRepetitiveActions, 8,
                       "overriding one tier must not decouple the others")
    }
}
