// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
//
//  AbortTriggerTests.swift
//  DevgenticTests
//
//  Created by Raj Singh.
//

import XCTest
@testable import devgentic

final class AbortTriggerTests: XCTestCase {

    private static let allKinds: [AbortTrigger.Kind] = [
        .repetitiveAction, .staleToolRepetition, .consecutiveToolFailures, .consecutiveDenials,
    ]

    private func trigger(_ kind: AbortTrigger.Kind) -> AbortTrigger {
        AbortTrigger(kind: kind, reason: "r", modelNarrative: "n")
    }

    // MARK: - Identity cannot collapse

    func testEveryKindMapsToItsOwnErrorCategory() {
        // ⚠️ THE REGRESSION GUARD. With a hardcoded `var abortCategory`, all four kinds reported
        // `.cbRepetitiveAction`, so a dashboard could not tell a failing tool from a stuck loop
        // from a user repeatedly saying no. If two kinds ever share a category again, the
        // telemetry is lying in exactly the same way.
        let categories = Self.allKinds.map { trigger($0).category }

        XCTAssertEqual(
            Set(categories).count, Self.allKinds.count,
            "Two abort kinds share an AgentErrorCategory (\(categories.map(\.rawValue))). Each "
            + "trigger must be distinguishable in the error dashboards — that is the whole reason "
            + "the category is derived from `kind` instead of stored beside it."
        )
    }

    func testFailuresAndLoopsAreNotFiledTogether() {
        // The specific conflation that shipped: a loop and a failure are different events for
        // anyone reading the error panels, and they were indistinguishable.
        XCTAssertNotEqual(
            trigger(.repetitiveAction).category,
            trigger(.consecutiveToolFailures).category,
            "A degenerate loop and a run of tool failures must not share a category."
        )
    }

    // MARK: - Narrative honesty (the defect that corrupted a file)

    func testLoopNarrativesStateThatTheCallsSucceeded() {
        // ⚠️⚠️ Field-observed 2026-09-20. Every abort injected "Tools are failing repeatedly: …"
        // — including a repetition loop in which all three `read_file` calls SUCCEEDED. The model
        // replied "I understand the frustration with the tool failures", concluded it could not
        // read a 531-byte file it had just read three times, and committed an edit it called a
        // "high-risk guess". That edit deleted a method and duplicated another.
        //
        // A loop narrative must therefore never describe the tools as failing, and must say the
        // results in hand are good.
        for kind in [AbortTrigger.Kind.repetitiveAction, .staleToolRepetition] {
            let narrative = CircuitBreakerNarrativeProbe.narrative(for: kind).lowercased()

            XCTAssertFalse(
                narrative.contains("fail"),
                "The \(kind) narrative tells the model its tools are FAILING, but in a repetition "
                + "loop every call succeeded. This exact wording caused a model to distrust a "
                + "successful read and guess at an edit instead."
            )
            XCTAssertTrue(
                narrative.contains("succeed"),
                "A loop narrative must state that the calls SUCCEEDED, so the model trusts the "
                + "results it already holds instead of re-fetching or guessing."
            )
        }
    }

    func testEveryKindCarriesANonEmptyNarrative() {
        // A trigger with no narrative would fall back to whatever generic text the call site
        // happens to have — which is how the shared "tools are failing" sentence spread to
        // every kind in the first place.
        for kind in Self.allKinds {
            XCTAssertFalse(
                CircuitBreakerNarrativeProbe.narrative(for: kind).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                "\(kind) has no model narrative; the call site would have to invent one."
            )
        }
    }

    // MARK: - Policy applicability is answered per kind

    func testPolicyApplicabilityIsDecidedForEveryKind() {
        // Not asserting WHICH value — that is a product decision (2026-09-20: every kind honours
        // the profile's tolerance, preserving the behaviour the dead flag accidentally produced).
        // Asserting only that the property is reachable and total, so adding a `Kind` forces an
        // answer instead of silently inheriting one.
        for kind in Self.allKinds {
            _ = trigger(kind).honoursToolFailurePolicy
        }
    }

    func testTodaysPolicyIsUniformAndDeliberate() {
        // ⚠️ A CHANGE-DETECTOR ON PURPOSE, and the only one in this file. Flipping any kind to
        // `false` makes it abort regardless of the profile's `onToolFailure`, which is a real
        // behavioural change to when runs stop. This test failing means someone made that
        // change — update it with intent, do not silence it.
        for kind in Self.allKinds {
            XCTAssertTrue(
                trigger(kind).honoursToolFailurePolicy,
                "\(kind) no longer honours ErrorRecovery.onToolFailure. That is a deliberate "
                + "product change (runs will now hard-stop on this trigger) — confirm it was "
                + "intended, then update this expectation."
            )
        }
    }
}

/// Reaches the narrative each producer actually emits, by driving the real breaker.
///
/// ⚠️ Deliberately drives `CognitiveCircuitBreaker` rather than restating the strings: a test
/// that hardcoded its own copies would pass while the shipped wording said something else —
/// which is precisely the failure mode being guarded against.
private enum CircuitBreakerNarrativeProbe {

    static func narrative(for kind: AbortTrigger.Kind) -> String {
        switch kind {
        case .repetitiveAction:        return driveRepetitiveLoop()
        case .staleToolRepetition:     return driveStaleRepetition()
        case .consecutiveToolFailures: return driveConsecutiveFailures()
        case .consecutiveDenials:      return driveConsecutiveDenials()
        }
    }

    private static func observation(tool: String, params: String, output: String, isSuccess: Bool) -> ToolObservation {
        ToolObservation(
            stepId: 0, toolCallId: UUID().uuidString, toolName: tool,
            result: output, summary: output, isSuccess: isSuccess,
            params: params, output: output, artifacts: []
        )
    }

    private static func driveRepetitiveLoop() -> String {
        var breaker = CognitiveCircuitBreaker()
        let obs = [observation(tool: "read_file", params: "{\"path\":\"a\"}", output: "same", isSuccess: true)]
        for _ in 0..<10 {
            if case .abort(let t) = breaker.evaluateRepetitiveActions(obs), t.kind == .repetitiveAction {
                return t.modelNarrative
            }
        }
        return ""
    }

    private static func driveStaleRepetition() -> String {
        var breaker = CognitiveCircuitBreaker()
        // Alternate the iteration fingerprint so the per-iteration check cannot fire first,
        // while the same single tool call repeats — the global-frequency path.
        let a = observation(tool: "read_file", params: "{\"path\":\"a\"}", output: "same", isSuccess: true)
        let b = observation(tool: "list_directory", params: "{\"path\":\"b\"}", output: "\(UUID())", isSuccess: true)
        for i in 0..<12 {
            let obs = i % 2 == 0 ? [a] : [a, b]
            if case .abort(let t) = breaker.evaluateRepetitiveActions(obs), t.kind == .staleToolRepetition {
                return t.modelNarrative
            }
        }
        return ""
    }

    private static func driveConsecutiveFailures() -> String {
        var breaker = CognitiveCircuitBreaker()
        for _ in 0..<10 {
            if case .abort(let t) = breaker.recordToolResult(isSuccess: false), t.kind == .consecutiveToolFailures {
                return t.modelNarrative
            }
        }
        return ""
    }

    private static func driveConsecutiveDenials() -> String {
        var breaker = CognitiveCircuitBreaker()
        for _ in 0..<10 {
            if case .abort(let t) = breaker.recordDenial(), t.kind == .consecutiveDenials {
                return t.modelNarrative
            }
        }
        return ""
    }
}
