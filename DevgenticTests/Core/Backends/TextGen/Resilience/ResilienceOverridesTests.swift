//
//  ResilienceOverridesTests.swift
//  DevgenticTests
//
//  Phase-B resilience: per-tier override resolution precedence, backward-compat
//  with the legacy single-knob RetryPolicy, Codable round-trip + omit-empty, and
//  end-to-end persistence through a round-tripped AgentConfig profile.
//

import XCTest
@testable import devgentic

final class ResilienceOverridesTests: XCTestCase {

    // MARK: - Resolution precedence

    func testNoOverrides_FallsBackToLegacyMaxRetries() {
        // Old profiles with no overrides: the single legacy knob still drives all
        // three caps exactly as before — behavior preserved.
        let policy = ResolvedResiliencePolicy.resolved(
            for: .cloud,
            overrides: nil,
            legacy: RetryPolicy(maxRetries: 5)
        )
        XCTAssertEqual(policy.cognitive.maxParseFailures, 5)
        XCTAssertEqual(policy.loop.maxConsecutiveToolFailures, 5)
        XCTAssertEqual(policy.loop.maxRepetitiveActions, 5)
    }

    func testEmptyOverrides_BehaveLikeNil() {
        let policy = ResolvedResiliencePolicy.resolved(
            for: .cloud,
            overrides: ResilienceOverrides(),
            legacy: RetryPolicy(maxRetries: 4)
        )
        XCTAssertEqual(policy.cognitive.maxParseFailures, 4)
        XCTAssertEqual(policy.loop.maxConsecutiveToolFailures, 4)
        XCTAssertEqual(policy.loop.maxRepetitiveActions, 4)
    }

    func testPartialOverride_DecouplesOnlyThatCap() {
        // Setting one cap must NOT move the others — the whole point of Phase B.
        let policy = ResolvedResiliencePolicy.resolved(
            for: .cloud,
            overrides: ResilienceOverrides(maxParseFailures: 2),
            legacy: RetryPolicy(maxRetries: 5)
        )
        XCTAssertEqual(policy.cognitive.maxParseFailures, 2, "Explicit override wins")
        XCTAssertEqual(policy.loop.maxConsecutiveToolFailures, 5, "Untouched cap keeps the legacy value")
        XCTAssertEqual(policy.loop.maxRepetitiveActions, 5, "Untouched cap keeps the legacy value")
    }

    func testAllThreeOverridden_LegacyIgnored() {
        let policy = ResolvedResiliencePolicy.resolved(
            for: .ollama,
            overrides: ResilienceOverrides(maxParseFailures: 1, maxConsecutiveToolFailures: 2, maxRepetitiveActions: 4),
            legacy: RetryPolicy(maxRetries: 9)
        )
        XCTAssertEqual(policy.cognitive.maxParseFailures, 1)
        XCTAssertEqual(policy.loop.maxConsecutiveToolFailures, 2)
        XCTAssertEqual(policy.loop.maxRepetitiveActions, 4)
    }

    func testOverridesDoNotAffectTransportTier() {
        // Cognitive/loop overrides must never touch transport budgets — those stay
        // provider-class-derived regardless of the cap overrides.
        let cloud = ResolvedResiliencePolicy.resolved(
            for: .cloud,
            overrides: ResilienceOverrides(maxParseFailures: 1, maxConsecutiveToolFailures: 1, maxRepetitiveActions: 1)
        )
        XCTAssertEqual(cloud.transport.maxTransientRetries, 3)
        XCTAssertEqual(cloud.transport.maxThrottleRetries, 5)

        let ollama = ResolvedResiliencePolicy.resolved(
            for: .ollama,
            overrides: ResilienceOverrides(maxParseFailures: 9)
        )
        XCTAssertTrue(ollama.transport.connectionRefusedIsFatal, "Ollama transport behavior is unaffected by cap overrides")
    }

    // MARK: - Codable round-trip

    func testCodable_RoundTrip_PreservesSetFields() throws {
        let original = ResilienceOverrides(maxParseFailures: 2, maxConsecutiveToolFailures: nil, maxRepetitiveActions: 4)
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(ResilienceOverrides.self, from: data)
        XCTAssertEqual(decoded.maxParseFailures, 2)
        XCTAssertNil(decoded.maxConsecutiveToolFailures)
        XCTAssertEqual(decoded.maxRepetitiveActions, 4)
    }

    func testDecoder_ToleratesMissingAndUnknownKeys() throws {
        // A future field or a stray key must never throw — same tolerance as
        // RetryPolicy/ErrorRecovery, so it can't collapse the enclosing profile.
        let json = #"{"maxParseFailures": 3, "someFutureKnob": 99}"#.data(using: .utf8)!
        let decoded = try JSONDecoder().decode(ResilienceOverrides.self, from: json)
        XCTAssertEqual(decoded.maxParseFailures, 3)
        XCTAssertNil(decoded.maxConsecutiveToolFailures)
    }

    func testIsEmpty() {
        XCTAssertTrue(ResilienceOverrides().isEmpty)
        XCTAssertFalse(ResilienceOverrides(maxRepetitiveActions: 3).isEmpty)
    }

    // MARK: - Profile persistence (ProfileDetails round-trip)

    private func makeAgentProfile(overrides: ResilienceOverrides?) -> ProfileDetails {
        .agent(AgentConfig(
            llmConfig: ProviderConfig(apiProvider: .anthropic, modelName: "claude-test"),
            resilienceOverrides: overrides
        ))
    }

    func testProfileRoundTrip_WithOverrides_Persists() throws {
        let details = makeAgentProfile(overrides: ResilienceOverrides(maxConsecutiveToolFailures: 5))
        let data = try JSONEncoder().encode(details)
        let decoded = try JSONDecoder().decode(ProfileDetails.self, from: data)

        guard case .agent(let config) = decoded else { return XCTFail("Expected .agent") }
        XCTAssertEqual(config.resilienceOverrides?.maxConsecutiveToolFailures, 5)
        XCTAssertNil(config.resilienceOverrides?.maxParseFailures)
    }

    func testProfileRoundTrip_AllAuto_OmitsOverridesKey() throws {
        // An untouched (all-Auto) profile must not emit a resilienceOverrides key,
        // keeping it byte-compatible with pre-Phase-B persisted data.
        let details = makeAgentProfile(overrides: nil)
        let data = try JSONEncoder().encode(details)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertNil(json["resilienceOverrides"], "All-Auto profile should omit the overrides object")

        // And an explicitly-empty overrides object collapses the same way.
        let emptyDetails = makeAgentProfile(overrides: ResilienceOverrides())
        let emptyData = try JSONEncoder().encode(emptyDetails)
        let emptyJSON = try XCTUnwrap(JSONSerialization.jsonObject(with: emptyData) as? [String: Any])
        XCTAssertNil(emptyJSON["resilienceOverrides"], "Empty overrides should be omitted, not persisted as {}")
    }

    func testLegacyProfileWithoutOverrides_DecodesToNil() throws {
        // Simulate a pre-Phase-B agent JSON (no resilienceOverrides key) and confirm
        // it decodes cleanly with overrides == nil (Auto).
        let details = makeAgentProfile(overrides: nil)
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: try JSONEncoder().encode(details)) as? [String: Any])
        json.removeValue(forKey: "resilienceOverrides") // ensure absent
        json["retryPolicy"] = ["maxRetries": 5, "backoffStrategy": "exponential"]
        let data = try JSONSerialization.data(withJSONObject: json)

        let decoded = try JSONDecoder().decode(ProfileDetails.self, from: data)
        guard case .agent(let config) = decoded else { return XCTFail("Expected .agent") }
        XCTAssertNil(config.resilienceOverrides)
        XCTAssertEqual(config.retryPolicy?.maxRetries, 5, "Legacy knob still decodes and drives the resolver fallback")
    }
}
