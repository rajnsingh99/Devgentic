// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
//
//  ValidationAndTelemetryGapTests.swift
//  DevgenticTests
//
//  Created on 08/08/26.
//
//  Registers A35 (the "instructions are required" rule lived in two views and nowhere else),
//  A36 (`ProfileValidator` never inspected `advancedConfiguration` at all) and A38 (the limits that
//  terminate a run were unrecoverable from telemetry). A33 is a menu action with no testable seam.
//

import XCTest
@testable import devgentic

// MARK: - A35: one definition of the instructions rule

final class InstructionsRuleTests: XCTestCase {

    private func agent(instructions: String?) -> BackendProfileSnapshot {
        BackendProfileSnapshot(
            displayName: "Researcher",
            details: .agent(AgentConfig(
                llmConfig: ProviderConfig(apiProvider: .anthropic,
                                          modelName: "claude-opus-5",
                                          apiKey: "sk-test"),
                tools: [],
                instructions: instructions)))
    }

    func testMissingInstructionsCoversNilEmptyAndWhitespace() {
        XCTAssertTrue(ProfileValidator.instructionsAreMissing(nil))
        XCTAssertTrue(ProfileValidator.instructionsAreMissing(""))
        XCTAssertTrue(ProfileValidator.instructionsAreMissing("   \n\t "),
                      "the editors trimmed before checking — the shared rule must too")
        XCTAssertFalse(ProfileValidator.instructionsAreMissing("Be precise."))
    }

    /// ⚠️ The A35 defect: every non-editor save path had no rule at all. Now it is recorded.
    func testAProfileWithNoInstructionsIsReportedOnSave() {
        let findings = ProfileValidator.validate(agent(instructions: nil), strict: true)

        XCTAssertTrue(findings.contains { $0.field == "instructions" },
                      "creation from + and every out-of-band save used to produce nothing here")
    }

    /// ⚠️ **Advisory, and this is the load-bearing assertion.** Blocking at the store would refuse
    /// every out-of-band write to such a profile — including `disableThinkingOnProfile`, whose whole
    /// job is to stop a recurring provider 400. An agent created from + and not yet configured is
    /// exactly the profile this rule fires on, so those saves are not hypothetical.
    func testTheInstructionsRuleNeverRefusesASave() {
        let findings = ProfileValidator.validate(agent(instructions: nil), strict: true)

        XCTAssertTrue(findings.blocking.filter { $0.field == "instructions" }.isEmpty,
                      "making this blocking breaks the thinking auto-heal for the very profiles it targets")
        XCTAssertFalse(findings.advisories.filter { $0.field == "instructions" }.isEmpty)
    }

    func testAConfiguredProfileProducesNoInstructionsFinding() {
        let findings = ProfileValidator.validate(agent(instructions: "Be precise."), strict: true)
        XCTAssertFalse(findings.contains { $0.field == "instructions" })
    }

    /// The over-length rule stays BLOCKING — deterministic, visible in a live counter, and fixable
    /// by the person who caused it. The two must not be conflated.
    func testTheOverLengthRuleIsStillBlocking() {
        let tooLong = String(repeating: "a", count: ProfileValidationLimits.maxInstructionsLength + 1)
        let findings = ProfileValidator.validate(agent(instructions: tooLong), strict: true)

        XCTAssertTrue(findings.blocking.contains { $0.field == "instructions" })
    }
}

// MARK: - A36: the advanced-config blob is inspected at last

final class ThinkingBudgetValidationTests: XCTestCase {

    private func anthropicBot(maxTokens: Double, budget: Double, thinkingOn: Bool = true) -> BackendProfileSnapshot {
        var config = ProviderConfig(apiProvider: .anthropic, modelName: "claude-opus-5", apiKey: "sk-test")
        config.advancedConfiguration = [
            "maxTokens": .number(maxTokens),
            "extendedThinking": .bool(thinkingOn),
            "thinkingBudgetTokens": .number(budget)
        ]
        return BackendProfileSnapshot(
            displayName: "Thinker",
            details: .bot(BotConfig(llmConfig: config, instructions: "Be precise.")))
    }

    /// The register's exact numbers. `ProfileValidator` never looked inside
    /// `advancedConfiguration`, so this saved cleanly and then 400'd on every send.
    func testABudgetLargerThanMaxTokensIsReported() {
        let findings = ProfileValidator.validate(anthropicBot(maxTokens: 2048, budget: 64000), strict: true)

        XCTAssertTrue(findings.contains { $0.field == "thinkingBudgetTokens" })
    }

    /// The budget is drawn FROM the output allowance, so equal is already too much — there would be
    /// nothing left to answer with.
    func testABudgetEqualToMaxTokensIsReported() {
        let findings = ProfileValidator.validate(anthropicBot(maxTokens: 8000, budget: 8000), strict: true)
        XCTAssertTrue(findings.contains { $0.field == "thinkingBudgetTokens" })
    }

    func testASensibleBudgetIsAccepted() {
        let findings = ProfileValidator.validate(anthropicBot(maxTokens: 16000, budget: 8000), strict: true)
        XCTAssertFalse(findings.contains { $0.field == "thinkingBudgetTokens" })
    }

    /// ⚠️ The false positive that would matter: with thinking OFF the budget is inert, so warning
    /// about it would be noise on a profile that works fine.
    func testAnInertBudgetIsNotReportedWhenThinkingIsOff() {
        let findings = ProfileValidator.validate(
            anthropicBot(maxTokens: 2048, budget: 64000, thinkingOn: false), strict: true)

        XCTAssertFalse(findings.contains { $0.field == "thinkingBudgetTokens" })
    }

    /// Advisory: the blob cannot be decoded with certainty for every provider, and a false positive
    /// here would refuse a legitimate save.
    func testTheBudgetRuleNeverRefusesASave() {
        let findings = ProfileValidator.validate(anthropicBot(maxTokens: 2048, budget: 64000), strict: true)
        XCTAssertTrue(findings.blocking.filter { $0.field == "thinkingBudgetTokens" }.isEmpty)
    }

    /// Only Anthropic carries these two keys; other providers must not be probed for them.
    func testANonAnthropicProfileIsNotInspected() {
        var config = ProviderConfig(apiProvider: .openAI, modelName: "gpt-4o", apiKey: "sk-test")
        config.advancedConfiguration = [
            "maxTokens": .number(2048),
            "extendedThinking": .bool(true),
            "thinkingBudgetTokens": .number(64000)
        ]
        let profile = BackendProfileSnapshot(
            displayName: "OpenAI",
            details: .bot(BotConfig(llmConfig: config, instructions: "Be precise.")))

        XCTAssertFalse(ProfileValidator.validate(profile, strict: true)
            .contains { $0.field == "thinkingBudgetTokens" })
    }
}

// MARK: - A38: the limits are recoverable from telemetry

final class ExecutionDefaultsTests: XCTestCase {

    /// ⚠️ The drift A38 exposed: `Executor` used `?? 15`, the panel's "Auto" label used `?? 15`, and
    /// `logProfileSelection` — the dump a support engineer reads — used `?? 20`. The configuration
    /// record stated a cap the run never had.
    func testTheIterationDefaultHasOneDefinition() {
        XCTAssertEqual(AgentExecutionDefaults.maxIterations, 15,
                       "this decides when runs terminate — changing it is a behaviour change, and "
                       + "every display of it now follows this constant")
    }

    /// The resolved caps must come from the same function the runtime uses, or telemetry records
    /// numbers that were never in force.
    func testResolvedCapsMatchTheRuntimeResolver() {
        let legacy = RetryPolicy(maxRetries: 4)
        let resolved = ResolvedResiliencePolicy.resolved(for: .cloud, overrides: nil, legacy: legacy)

        XCTAssertEqual(resolved.cognitive.maxParseFailures, 4)
        XCTAssertEqual(resolved.loop.maxConsecutiveToolFailures, 4)
        XCTAssertEqual(resolved.loop.maxRepetitiveActions, 4)
        XCTAssertEqual(resolved.loop.maxConsecutiveDenials,
                       ResolvedResiliencePolicy.defaultMaxConsecutiveDenials,
                       "the denial cap is never coupled to the legacy knob")
    }

    /// ⚠️ Why the snapshot stores RESOLVED values rather than the overrides: a stored `nil` means
    /// "Auto", and Auto resolves through the profile's legacy `retryPolicy.maxRetries` (A70) — which
    /// may have changed by the time anyone reads the trace. The number has to be written down.
    func testAutoResolvesToSomethingWorthRecording() {
        let viaAuto = ResolvedResiliencePolicy.resolved(
            for: .cloud, overrides: nil, legacy: RetryPolicy(maxRetries: 7))
        let viaOverride = ResolvedResiliencePolicy.resolved(
            for: .cloud, overrides: ResilienceOverrides(maxParseFailures: 7), legacy: RetryPolicy())

        XCTAssertEqual(viaAuto.cognitive.maxParseFailures, 7)
        XCTAssertEqual(viaOverride.cognitive.maxParseFailures, 7,
                       "the same effective cap reached two ways — the trace cannot tell them apart "
                       + "without recording the resolved value, which is the point of A38")
    }
}
