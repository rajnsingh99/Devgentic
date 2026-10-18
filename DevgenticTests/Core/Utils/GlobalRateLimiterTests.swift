// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
//
//  GlobalRateLimiterTests.swift
//  DevgenticTests
//
//  Created by Raj Singh.
//

import XCTest
@testable import devgentic

final class GlobalRateLimiterTests: XCTestCase {

    // Each test gets a fresh limiter instance (not the singleton)
    private var limiter: GlobalRateLimiter!

    override func setUp() async throws {
        limiter = GlobalRateLimiter()
    }

    // MARK: - Key Derivation Tests

    func testDeriveBucketKey_SameApiKey_SameProvider_ProducesSameKey() {
        let key1 = RateLimitCategory.deriveBucketKey(provider: .anthropic, apiKey: "sk-abc123", baseURL: nil)
        let key2 = RateLimitCategory.deriveBucketKey(provider: .anthropic, apiKey: "sk-abc123", baseURL: nil)
        XCTAssertEqual(key1, key2, "Same API key should produce the same bucket key")
    }

    func testDeriveBucketKey_DifferentApiKeys_ProducesDifferentKeys() {
        let key1 = RateLimitCategory.deriveBucketKey(provider: .anthropic, apiKey: "sk-abc123", baseURL: nil)
        let key2 = RateLimitCategory.deriveBucketKey(provider: .anthropic, apiKey: "sk-xyz789", baseURL: nil)
        XCTAssertNotEqual(key1, key2, "Different API keys should produce different bucket keys")
    }

    func testDeriveBucketKey_DifferentProviders_SameKey_ProducesDifferentKeys() {
        let key1 = RateLimitCategory.deriveBucketKey(provider: .anthropic, apiKey: "sk-shared", baseURL: nil)
        let key2 = RateLimitCategory.deriveBucketKey(provider: .openAI, apiKey: "sk-shared", baseURL: nil)
        XCTAssertNotEqual(key1, key2, "Different providers should produce different bucket keys even with same API key")
    }

    func testDeriveBucketKey_MLX_AlwaysSameKey() {
        let key1 = RateLimitCategory.deriveBucketKey(provider: .mlx, apiKey: nil, baseURL: nil)
        let key2 = RateLimitCategory.deriveBucketKey(provider: .mlx, apiKey: nil, baseURL: nil)
        XCTAssertEqual(key1, key2)
        XCTAssertEqual(key1, "local:mlx", "MLX should always produce 'local:mlx'")
    }

    func testDeriveBucketKey_Ollama_SameBaseURL_SameKey() {
        let key1 = RateLimitCategory.deriveBucketKey(provider: .ollama, apiKey: nil, baseURL: "http://localhost:11434")
        let key2 = RateLimitCategory.deriveBucketKey(provider: .ollama, apiKey: nil, baseURL: "http://localhost:11434")
        XCTAssertEqual(key1, key2, "Same Ollama endpoint should share a bucket")
    }

    func testDeriveBucketKey_Ollama_DifferentBaseURLs_DifferentKeys() {
        let key1 = RateLimitCategory.deriveBucketKey(provider: .ollama, apiKey: nil, baseURL: "http://localhost:11434")
        let key2 = RateLimitCategory.deriveBucketKey(provider: .ollama, apiKey: nil, baseURL: "http://remote-server:11434")
        XCTAssertNotEqual(key1, key2, "Different Ollama endpoints should get separate buckets")
    }

    func testDeriveBucketKey_CloudProvider_NilApiKey() {
        let key = RateLimitCategory.deriveBucketKey(provider: .anthropic, apiKey: nil, baseURL: nil)
        XCTAssertTrue(key.hasPrefix("anthropic:"), "Should still produce an anthropic-prefixed key")
        XCTAssertTrue(key.contains("no-key"), "Nil API key should use 'no-key' sentinel")
    }

    // MARK: - Category Mapping Tests

    func testFromProvider_MapsCorrectly() {
        XCTAssertEqual(RateLimitCategory.from(provider: .anthropic), .anthropic)
        XCTAssertEqual(RateLimitCategory.from(provider: .google), .geminiFlash)
        XCTAssertEqual(RateLimitCategory.from(provider: .openAI), .openAI)
        XCTAssertEqual(RateLimitCategory.from(provider: .ollama), .local)
        XCTAssertEqual(RateLimitCategory.from(provider: .mlx), .local)
    }

    // MARK: - Burst Behavior Tests

    func testBurst_AnthropicAllowsFiveImmediateRequests() async {
        // Anthropic has maxBurst = 5, so first 5 calls should not throttle
        let key = "anthropic:test-burst"
        for i in 1...5 {
            let waited = await limiter.wait(forKey: key, category: .anthropic)
            XCTAssertEqual(waited, 0, "Request \(i) within burst should not wait")
        }
    }

    func testBurst_SixthRequestThrottles() async {
        let key = "anthropic:test-throttle"
        // Exhaust burst
        for _ in 1...5 {
            await limiter.wait(forKey: key, category: .anthropic)
        }
        // 6th request should report a wait time > 0
        let waited = await limiter.wait(forKey: key, category: .anthropic)
        XCTAssertGreaterThan(waited, 0, "Request beyond burst should throttle")
    }

    // MARK: - Local Bypass Tests

    func testLocal_BypassesThrottling() async {
        let key = "local:mlx"
        // Local is unmetered: rapid-fire requests never wait.
        for i in 1...10 {
            let waited = await limiter.wait(forKey: key, category: .local)
            XCTAssertEqual(waited, 0, "Local request \(i) should never throttle")
        }
    }

    func testLocal_TimeUntilNextToken_AlwaysZero() async {
        let key = "local:mlx"
        for _ in 1...5 {
            await limiter.wait(forKey: key, category: .local)
        }
        let wait = await limiter.timeUntilNextToken(forKey: key, category: .local)
        XCTAssertEqual(wait, 0, "Local should never project a wait")
    }

    func testLocal_DrainAndPenalize_HasNoEffect() async {
        let key = "local:mlx"
        await limiter.drainAndPenalize(key: key, category: .local, penaltySeconds: 30.0)
        let waited = await limiter.wait(forKey: key, category: .local)
        XCTAssertEqual(waited, 0, "Drain on a local bucket must not introduce throttling")
    }

    func testBurst_OpenAIAllowsTenImmediateRequests() async {
        let key = "openai:test-burst"
        for i in 1...10 {
            let waited = await limiter.wait(forKey: key, category: .openAI)
            XCTAssertEqual(waited, 0, "OpenAI request \(i) within burst should not wait")
        }
    }

    // MARK: - Bucket Isolation Tests

    func testBucketIsolation_DifferentKeysDoNotInterfere() async {
        let keyA = "anthropic:key-A"
        let keyB = "anthropic:key-B"

        // Exhaust bucket A's burst
        for _ in 1...5 {
            await limiter.wait(forKey: keyA, category: .anthropic)
        }

        // Bucket B should still have full burst
        let waited = await limiter.wait(forKey: keyB, category: .anthropic)
        XCTAssertEqual(waited, 0, "Different key should have independent bucket")
    }

    func testBucketIsolation_SameKeySharesState() async {
        let sharedKey = "anthropic:shared-key"

        // Two "profiles" using same key — exhaust burst between them
        for _ in 1...3 {
            await limiter.wait(forKey: sharedKey, category: .anthropic)
        }
        // "Second profile" using same key — only 2 burst tokens left
        for _ in 1...2 {
            let waited = await limiter.wait(forKey: sharedKey, category: .anthropic)
            XCTAssertEqual(waited, 0, "Should still be within shared burst")
        }
        // 6th total request on shared key — should throttle
        let waited = await limiter.wait(forKey: sharedKey, category: .anthropic)
        XCTAssertGreaterThan(waited, 0, "Shared key should throttle after combined burst exhaustion")
    }

    func testBucketIsolation_CrossProviderNoInterference() async {
        let anthropicKey = "anthropic:key-1"
        let openAIKey = "openai:key-1"

        // Exhaust Anthropic burst
        for _ in 1...5 {
            await limiter.wait(forKey: anthropicKey, category: .anthropic)
        }

        // OpenAI should be unaffected
        let waited = await limiter.wait(forKey: openAIKey, category: .openAI)
        XCTAssertEqual(waited, 0, "OpenAI bucket should be independent of Anthropic")
    }

    // MARK: - Drain & Penalize Tests

    func testDrainAndPenalize_CausesThrottling() async {
        let key = "anthropic:drain-test"
        // Fresh bucket — should be immediate
        let waited1 = await limiter.wait(forKey: key, category: .anthropic)
        XCTAssertEqual(waited1, 0)

        // Simulate 429: drain with 5s penalty
        await limiter.drainAndPenalize(key: key, category: .anthropic, penaltySeconds: 5.0)

        // Next request should report significant wait
        let projectedWait = await limiter.timeUntilNextToken(forKey: key, category: .anthropic)
        XCTAssertGreaterThan(projectedWait, 3.0, "After 5s penalty, wait should be substantial")
    }

    func testDrainAndPenalize_OnlyAffectsTargetBucket() async {
        let keyA = "anthropic:drain-A"
        let keyB = "anthropic:drain-B"

        // Drain bucket A
        await limiter.drainAndPenalize(key: keyA, category: .anthropic, penaltySeconds: 10.0)

        // Bucket B should be unaffected
        let waited = await limiter.wait(forKey: keyB, category: .anthropic)
        XCTAssertEqual(waited, 0, "Drain on key A should not affect key B")
    }

    // MARK: - timeUntilNextToken Tests

    func testTimeUntilNextToken_FreshBucketReturnsZero() async {
        let key = "anthropic:fresh"
        // Trigger lazy creation
        await limiter.wait(forKey: key, category: .anthropic)
        // After 1 token consumed from burst of 5, still tokens available
        let wait = await limiter.timeUntilNextToken(forKey: key, category: .anthropic)
        XCTAssertEqual(wait, 0, "Should have tokens remaining in burst")
    }

    func testTimeUntilNextToken_UnknownKeyReturnsZero() async {
        let wait = await limiter.timeUntilNextToken(forKey: "nonexistent", category: .anthropic)
        XCTAssertEqual(wait, 0, "Unknown key should return 0 (no bucket = no wait)")
    }

    func testTimeUntilNextToken_ExhaustedBucketReturnsPositive() async {
        let key = "anthropic:exhausted"
        // Exhaust burst
        for _ in 1...5 {
            await limiter.wait(forKey: key, category: .anthropic)
        }
        let wait = await limiter.timeUntilNextToken(forKey: key, category: .anthropic)
        XCTAssertGreaterThan(wait, 0, "Exhausted bucket should report positive wait time")
    }

    // MARK: - Lazy Bucket Creation Tests

    func testLazyCreation_BucketCreatedOnFirstWait() async {
        let key = "new-bucket:test"
        // Before any call, timeUntilNextToken returns 0 (no bucket)
        let waitBefore = await limiter.timeUntilNextToken(forKey: key, category: .anthropic)
        XCTAssertEqual(waitBefore, 0)

        // First wait creates the bucket
        let waited = await limiter.wait(forKey: key, category: .anthropic)
        XCTAssertEqual(waited, 0, "First call should create bucket with full burst")

        // Now bucket exists — after consuming 1 token, check remaining
        // Anthropic burst = 5, consumed 1, so 4 remaining → wait = 0
        let waitAfter = await limiter.timeUntilNextToken(forKey: key, category: .anthropic)
        XCTAssertEqual(waitAfter, 0, "Should still have burst tokens")
    }

    // MARK: - Legacy Bridge Tests

    func testLegacyWait_UsesCategoryAsKey() async {
        // Legacy call
        let waited = await limiter.wait(for: .anthropic)
        XCTAssertEqual(waited, 0, "Legacy bridge should work with fresh bucket")

        // Exhaust via legacy
        for _ in 1...4 {
            await limiter.wait(for: .anthropic)
        }

        // Should affect same bucket when using key-based API with raw value
        let waited2 = await limiter.wait(forKey: "anthropic", category: .anthropic)
        XCTAssertGreaterThan(waited2, 0, "Legacy and key-based calls on same category should share bucket")
    }

    // MARK: - Debt Accumulation Tests

    func testDebt_AccumulatesAcrossRequests() async {
        let key = "anthropic:debt-test"
        // Anthropic: burst = 5, rate ≈ 0.83/sec
        // Requests 1-5: immediate (consume the burst)
        for _ in 1...5 {
            let w = await limiter.wait(forKey: key, category: .anthropic)
            XCTAssertEqual(w, 0)
        }

        // Request 6: goes into debt → ~1.2s wait
        let w6 = await limiter.wait(forKey: key, category: .anthropic)
        XCTAssertGreaterThan(w6, 0.5, "Should wait approximately 1.2s")
        XCTAssertLessThan(w6, 2.5, "Should not wait excessively")
    }

    // MARK: - Workflow Scenario Tests

    func testWorkflow_DifferentProviders_NoInterference() async {
        // Simulate: Node A (Anthropic) → Node B (OpenAI) → Node C (Gemini)
        let keyA = "anthropic:workflow-A"
        let keyB = "openai:workflow-B"
        let keyC = "geminiFlash:workflow-C"

        // Node A exhausts its burst
        for _ in 1...5 {
            await limiter.wait(forKey: keyA, category: .anthropic)
        }

        // Node B (different provider) should be unaffected
        let waitB = await limiter.wait(forKey: keyB, category: .openAI)
        XCTAssertEqual(waitB, 0, "Different provider in workflow should not be affected")

        // Node C (different provider) should also be unaffected
        let waitC = await limiter.wait(forKey: keyC, category: .geminiFlash)
        XCTAssertEqual(waitC, 0, "Third provider in workflow should not be affected")
    }

    func testWorkflow_SameProvider_SameKey_DebtCarriesOver() async {
        // Simulate: Node A (Anthropic, key-1) → Node B (Anthropic, key-1)
        // Same API key = same bucket = debt carries over
        let sharedKey = "anthropic:shared-workflow"

        // Node A exhausts burst
        for _ in 1...5 {
            await limiter.wait(forKey: sharedKey, category: .anthropic)
        }

        // Node B starts — should hit throttle immediately
        let waitB = await limiter.wait(forKey: sharedKey, category: .anthropic)
        XCTAssertGreaterThan(waitB, 0, "Same key across workflow nodes should carry debt")
    }

    func testWorkflow_SameProvider_DifferentKeys_Independent() async {
        // Simulate: Node A (Anthropic, key-1) → Node B (Anthropic, key-2)
        // Different API keys = separate buckets
        let keyA = "anthropic:workflow-key1"
        let keyB = "anthropic:workflow-key2"

        // Node A exhausts burst
        for _ in 1...5 {
            await limiter.wait(forKey: keyA, category: .anthropic)
        }

        // Node B (different key) should have full burst
        let waitB = await limiter.wait(forKey: keyB, category: .anthropic)
        XCTAssertEqual(waitB, 0, "Different API keys should have independent buckets in workflow")
    }

    // MARK: - D-09: an unusable Retry-After must never become debt

    /// `Retry-After: inf` (or NaN, negative, or absurdly large) used to become −∞ debt, and the next
    /// `wait` trapped in `UInt64(seconds * 1e9)` — an app crash from one response header (Timeout
    /// inventory D-09). Asserted through `timeUntilNextToken`, which reads the same debt without
    /// the trapping conversion, so a regression FAILS here instead of killing the test host.
    func testDrainAndPenalize_UnusablePenalty_LeavesNoUnboundedDebt() async {
        for penalty in [Double.infinity, -.infinity, .nan, -1, 1e30] {
            let key = "anthropic:d09-\(penalty)"
            await limiter.drainAndPenalize(key: key, category: .anthropic, penaltySeconds: penalty)
            let wait = await limiter.timeUntilNextToken(forKey: key, category: .anthropic)
            XCTAssertTrue(wait.isFinite, "penalty \(penalty) left a non-finite wait (\(wait)) — the next request would trap")
            XCTAssertLessThanOrEqual(wait, 3600 + 2, "penalty \(penalty) was not clamped to the 1-hour ceiling (wait \(wait)s)")
        }
    }

    /// The clamp must not swallow an honest Retry-After.
    func testDrainAndPenalize_SanePenalty_IsStillHonoured() async {
        let key = "anthropic:d09-sane"
        await limiter.drainAndPenalize(key: key, category: .anthropic, penaltySeconds: 30)
        let wait = await limiter.timeUntilNextToken(forKey: key, category: .anthropic)
        XCTAssertGreaterThanOrEqual(wait, 30, "a 30 s Retry-After must still produce at least 30 s of debt, got \(wait)s")
        XCTAssertLessThan(wait, 33)
    }
}
