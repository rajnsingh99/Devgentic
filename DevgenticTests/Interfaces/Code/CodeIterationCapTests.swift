// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
//
//  CodeIterationCapTests.swift
//  DevgenticTests
//
//  The Code iteration cap is OPTIONAL since 2026-09-25 (user decision): no cap by default, and a
//  typed cap of 10–1000 in the quick settings. Previously a +/- stepper, default 20.
//

import XCTest
@testable import devgentic

@MainActor
final class CodeIterationCapTests: XCTestCase {

    private func agentConfig(maxIterations: Int? = 20) -> AgentConfig {
        AgentConfig(
            llmConfig: ProviderConfig(apiProvider: .ollama, modelName: "qwen2.5-coder:7b"),
            tools: CodeToolPreset.defaultTools,
            maxIterations: maxIterations,
            executionTimeout: 300
        )
    }

    private func applied(_ cap: Int?) -> Int? {
        var settings = CodeQuickSettings.default
        settings.maxIterations = cap
        var config = agentConfig()
        CodeSessionManager.apply(settings, to: &config)
        return config.maxIterations
    }

    // MARK: - The default and the range

    func testTheShippedDecisions() {
        XCTAssertEqual(CodeSessionManager.presetMaxIterations, AgentExecutionDefaults.uncapped,
                       "user decision 2026-09-25: a Code run has no iteration cap unless one is set")
        XCTAssertEqual(CodeSessionManager.iterationCapRange, 10...1000,
                       "user decision 2026-09-25: a typed cap is 10–1000")
    }

    func testNoCapIsAppliedAsUncapped() {
        XCTAssertEqual(applied(nil), AgentExecutionDefaults.uncapped,
                       "an unset cap must become 'no cap', not the executor's default 15")
    }

    func testATypedCapIsAppliedAsIs() {
        XCTAssertEqual(applied(42), 42)
    }

    /// A value stored before the range existed (the old stepper went down to 3) is clamped, not trusted.
    func testAStoredValueOutsideTheRangeIsClamped() {
        XCTAssertEqual(applied(3), 10)
        XCTAssertEqual(applied(5_000), 1_000)
    }

    /// ⚠️ THE WIRING. `nil` on the config means "executor default (15)" to every reader, so "no cap"
    /// must arrive as a value the executor loops on.
    func testNoCapReachesTheExecutor() {
        var config = agentConfig(maxIterations: 20)
        CodeSessionManager.apply(.default, to: &config)
        let profile = BackendProfileSnapshot(displayName: "Code Session", details: .code(config),
                                             fileContextStrategy: .stateless)
        let react = ExecutorFactory.create(for: profile) as? ReActAgentExecutor
        XCTAssertEqual(react?.maxIterations, AgentExecutionDefaults.uncapped,
                       "the executor still caps an uncapped Code run")
    }

    func testTheLogSaysNoCapRatherThanANineteenDigitNumber() {
        XCTAssertEqual(AgentExecutionDefaults.describe(AgentExecutionDefaults.uncapped), "no cap")
        XCTAssertEqual(AgentExecutionDefaults.describe(40), "40")
        XCTAssertEqual(AgentExecutionDefaults.describe(nil), "15 (default)")
    }

    // MARK: - The field

    func testTheFieldsRules() {
        typealias P = CodeQuickSettingsPopover
        XCTAssertEqual(P.parseIterations(""), .noCap, "empty means no limit")
        XCTAssertEqual(P.parseIterations("10"), .cap(10))
        XCTAssertEqual(P.parseIterations("1000"), .cap(1000))
        XCTAssertEqual(P.parseIterations("9"), .outOfRange)
        XCTAssertEqual(P.parseIterations("1001"), .outOfRange)
        XCTAssertEqual(P.parseIterations("0"), .outOfRange)
    }

    func testOnlyDigitsAreAccepted() {
        typealias P = CodeQuickSettingsPopover
        XCTAssertEqual(P.digitsOnly("1,000"), "1000")
        XCTAssertEqual(P.digitsOnly("-25"), "25")
        XCTAssertEqual(P.digitsOnly("4o"), "4")
        XCTAssertEqual(P.digitsOnly("١٢"), "", "non-ASCII digits are not numbers Int() will read")
        XCTAssertEqual(P.digitsOnly("12345"), "1234", "four digits reach the ceiling; a fifth is never valid")
    }

    func testTheStoredValueRoundTripsThroughTheField() {
        typealias P = CodeQuickSettingsPopover
        XCTAssertEqual(P.IterationsInput(nil), .noCap)
        XCTAssertEqual(P.IterationsInput(42), .cap(42))
        XCTAssertEqual(P.parseIterations("42"), P.IterationsInput(42))
    }

    func testTheWarningShowsOnlyWhenBothLimitsAreOff() {
        var s = CodeQuickSettings.default
        XCTAssertFalse(CodeQuickSettingsPopover.bothLimitsOff(s), "the default timeout still bounds the run")
        s.executionTimeout = 0
        XCTAssertTrue(CodeQuickSettingsPopover.bothLimitsOff(s))
        s.maxIterations = 50
        XCTAssertFalse(CodeQuickSettingsPopover.bothLimitsOff(s))
    }
}
