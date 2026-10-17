// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
//
//  GlobalRateLimiter.swift
//  Devgentic
//
//  Created by Raj Singh on 17/02/26.
//

import Foundation
import os

/// Identifies the provider type for selecting default bucket parameters.
/// No longer used as the bucket key — buckets are keyed on a derived string
/// from (provider + apiKey/baseURL) so profiles sharing the same API key
/// share the same server-side quota boundary.
enum RateLimitCategory: String, Codable, Sendable {
    case local
    case openAI
    case geminiFlash
    case anthropic
    case openRouter
    /// An OpenRouter `:free` model variant. OpenRouter meters these separately from paid models
    /// and far more tightly (20 RPM, plus a daily cap), so they get their own bucket rather than
    /// sharing the paid `.openRouter` one keyed on the same API key.
    case openRouterFree
    case openAICompatible

    /// Conservative default RPM for each provider tier.
    var defaultTokensPerSecond: Double {
        switch self {
        case .local:            return 1.0          // unused — .local bypasses the limiter (see GlobalRateLimiter.wait)
        case .geminiFlash:      return 15.0 / 60.0  // 15 RPM — free tier
        case .anthropic:        return 50.0 / 60.0  // 50 RPM — Tier 1
        case .openAI:           return 500.0 / 60.0 // 500 RPM — Tier 1
        case .openRouter:       return 200.0 / 60.0 // limits scale with credits upstream; reactive 429 handling covers the rest
        case .openRouterFree:   return 20.0 / 60.0  // 20 RPM — OpenRouter's :free limit; the daily cap is left to reactive 429 handling
        case .openAICompatible: return 600.0 / 60.0 // endpoint unknown (often local LM Studio/vLLM) — permissive; reactive 429 covers remote gateways
        }
    }

    /// Maximum burst tokens (allows rapid-fire up to this count).
    var defaultMaxBurst: Double {
        switch self {
        case .local:            return 1.0
        case .geminiFlash:      return 5.0
        case .anthropic:        return 5.0
        case .openAI:           return 10.0
        case .openRouter:       return 10.0
        case .openRouterFree:   return 5.0
        case .openAICompatible: return 20.0
        }
    }
}

// MARK: - Rate Limit Key Derivation

extension RateLimitCategory {

    /// Derives a bucket key from a provider config.
    /// Profiles sharing the same API key (or same local endpoint) share a bucket.
    ///
    /// Key composition:
    /// - Cloud providers: `"anthropic:<apiKey-hash>"` — same key = same server quota
    /// - Ollama: `"local:<baseURL-hash>"` — same endpoint = same server
    /// - MLX: `"local:mlx"` — single GPU, always shared
    /// - OpenRouter `:free` models: `"openRouterFree:<apiKey-hash>"` — metered apart from paid ones
    static func deriveBucketKey(provider: ApiProvider, apiKey: String?, baseURL: String?, modelName: String? = nil) -> String {
        switch provider {
        case .anthropic, .openAI, .google, .openRouter:
            let category = Self.from(provider: provider, modelName: modelName)
            let keyHash = apiKey.map { String($0.hashValue) } ?? "no-key"
            return "\(category.rawValue):\(keyHash)"
        case .openAICompatible:
            // The endpoint IS the server/quota boundary (the key is often absent
            // for local servers), so key the bucket by baseURL — two different
            // compatible endpoints must not share one token bucket.
            let urlHash = baseURL.map { String($0.hashValue) } ?? "no-url"
            return "openAICompatible:\(urlHash)"
        case .ollama:
            let urlHash = baseURL.map { String($0.hashValue) } ?? "localhost"
            return "local:\(urlHash)"
        case .mlx:
            return "local:mlx"
        }
    }

    /// Maps ApiProvider to the corresponding rate limit category.
    ///
    /// ⚠️ Pass `modelName` wherever the model is known. Without it an OpenRouter `:free` model is
    /// classed as paid `.openRouter` (200 RPM) and trips OpenRouter's 20 RPM free limit on 429s
    /// instead of pacing under it. Every caller that shares a bucket key must agree on the
    /// category, because whichever call creates the bucket fixes its rate.
    static func from(provider: ApiProvider, modelName: String? = nil) -> RateLimitCategory {
        switch provider {
        case .anthropic:        return .anthropic
        case .google:           return .geminiFlash
        case .openAI:           return .openAI
        case .openRouter:       return isOpenRouterFreeModel(modelName) ? .openRouterFree : .openRouter
        case .openAICompatible: return .openAICompatible
        case .ollama, .mlx:     return .local
        }
    }

    /// OpenRouter marks free variants with a `:free` suffix on the model slug
    /// (e.g. `nvidia/nemotron-3-ultra-550b-a55b:free`).
    static func isOpenRouterFreeModel(_ modelName: String?) -> Bool {
        guard let modelName else { return false }
        return modelName.trimmingCharacters(in: .whitespacesAndNewlines).lowercased().hasSuffix(":free")
    }
}

/// A thread-safe Token Bucket implementation to manage API quotas.
/// Buckets are keyed on (provider + apiKey/baseURL) so profiles sharing
/// the same API key share the same server-side quota boundary.
/// Prevents "Death Spirals" where multiple agent loops exhaust limits simultaneously.
///
/// `.local` providers bypass the limiter entirely: MLX runs in-process (requests
/// already serialize on the GPU) and Ollama queues at the server, so there is no
/// upstream quota to protect — a proactive bucket only added ~1s latency per
/// agent iteration.
actor GlobalRateLimiter {

    // MARK: - Singleton
    static let shared = GlobalRateLimiter()

    private let logger = DGLogger(category: "GlobalRateLimiter")

    // MARK: - State

    private struct Bucket {
        let maxBurst: Double
        let tokensPerSecond: Double
        var currentTokens: Double
        var lastRefill: Date
    }

    /// Buckets keyed on derived string from (provider + apiKey/baseURL).
    /// Created lazily on first access for each unique key.
    private var buckets: [String: Bucket] = [:]

    // MARK: - Initialization

    // internal init so tests can create isolated instances via @testable import
    init() {
        logger.info("GlobalRateLimiter initialized with profile-scoped Token Bucket algorithm.")
    }

    // MARK: - Lazy Bucket Creation

    /// Returns the bucket for the given key, creating one with provider defaults if needed.
    private func getOrCreateBucket(key: String, category: RateLimitCategory) -> Bucket {
        if let existing = buckets[key] {
            return existing
        }
        let newBucket = Bucket(
            maxBurst: category.defaultMaxBurst,
            tokensPerSecond: category.defaultTokensPerSecond,
            currentTokens: category.defaultMaxBurst,
            lastRefill: Date()
        )
        buckets[key] = newBucket
        logger.info("Created rate limit bucket: \(key) (category: \(category.rawValue), burst: \(category.defaultMaxBurst), rate: \(String(format: "%.2f", category.defaultTokensPerSecond))/s)")
        return newBucket
    }

    // MARK: - Public API

    /// Acquires a token for the specified bucket key.
    /// Suspends execution if the bucket is empty until a token is available.
    /// - Parameters:
    ///   - key: The derived bucket key from `RateLimitCategory.deriveBucketKey()`.
    ///   - category: The provider category (used for default bucket params if key is new).
    /// - Returns: The time waited (in seconds).
    @discardableResult
    func wait(forKey key: String, category: RateLimitCategory) async -> TimeInterval {
        // Local inference is unmetered — no bucket is ever created. This also
        // covers a remote Ollama baseURL (still classified `.local`): self-hosted
        // servers have no quota tiers and apply their own request queueing.
        guard category != .local else { return 0 }

        var bucket = getOrCreateBucket(key: key, category: category)

        let now = Date()
        let timeElapsed = now.timeIntervalSince(bucket.lastRefill)

        // 1. Refill
        let newTokens = timeElapsed * bucket.tokensPerSecond
        bucket.currentTokens = min(bucket.maxBurst, bucket.currentTokens + newTokens)
        bucket.lastRefill = now

        // 2. Consume
        var waitTime: TimeInterval = 0

        if bucket.currentTokens >= 1.0 {
            bucket.currentTokens -= 1.0
        } else {
            let missingTokens = 1.0 - bucket.currentTokens
            waitTime = missingTokens / bucket.tokensPerSecond
            bucket.currentTokens -= 1.0

            logger.notice("Rate Limit Throttling (\(key)): Wait \(String(format: "%.2f", waitTime))s. Tokens left: \(String(format: "%.2f", bucket.currentTokens))")
        }

        buckets[key] = bucket

        // 3. Suspend if needed
        if waitTime > 0 {
            do {
                try await Task.sleep(nanoseconds: UInt64(waitTime * 1_000_000_000))
            } catch {
                logger.warning("Rate limit sleep interrupted.")
            }
        }

        return waitTime
    }

    // MARK: - Legacy convenience (bridges old RateLimitCategory-based calls)

    /// Legacy bridge: acquires a token using a category as the key.
    /// Used by call sites that don't have a profile-scoped key yet.
    @discardableResult
    func wait(for category: RateLimitCategory) async -> TimeInterval {
        await wait(forKey: category.rawValue, category: category)
    }

    /// Drains the bucket to force a hard reset.
    /// Used when the server responds with 429 despite our local counting (Drift).
    func drainAndPenalize(key: String, category: RateLimitCategory, penaltySeconds requestedPenalty: TimeInterval = 0) {
        // Local is unmetered — nothing to drain. A 429 from a local endpoint is
        // still backed off by LLMRetryStrategy's Retry-After sleep independently.
        guard category != .local else { return }

        var bucket = getOrCreateBucket(key: key, category: category)

        // ⚠️ Clamped HERE, at the one place debt is written, not only at the callers. The penalty
        // is a server's Retry-After, and `wait` turns debt into `UInt64(seconds * 1e9)`, which
        // TRAPS on infinity, NaN or anything past ~584 years. A `Retry-After: inf` used to set the
        // debt to −∞ and crash the app on the next request to that provider (Timeout inventory
        // D-09, 2026-09-26). Same bounds the retry sleeps already use: finite, ≥ 0, ≤ 1 hour.
        let penaltySeconds: TimeInterval
        if let sane = ProviderErrorClassifier.sanitizedRetryAfter(requestedPenalty) {
            penaltySeconds = sane
        } else {
            penaltySeconds = 0
            logger.warning("[RATE_LIMIT] Bucket \(key): ignored an unusable 429 penalty of \(requestedPenalty)s. CONSEQUENCE: the bucket is drained but carries no extra debt; the retry path's own Retry-After handling still backs off.")
        }

        bucket.currentTokens = min(0, bucket.currentTokens)
        let penaltyTokens = penaltySeconds * bucket.tokensPerSecond
        bucket.currentTokens -= penaltyTokens
        bucket.lastRefill = Date()
        buckets[key] = bucket

        logger.warning("Bucket Drained (\(key)). Penalty: \(penaltySeconds)s (Debt: \(bucket.currentTokens) tokens)")
    }

    /// Legacy bridge for drainAndPenalize using category as key.
    func drainAndPenalize(category: RateLimitCategory, penaltySeconds: TimeInterval = 0) {
        drainAndPenalize(key: category.rawValue, category: category, penaltySeconds: penaltySeconds)
    }

    /// Waits until the bucket would have a token, WITHOUT taking it. Returns the time waited.
    ///
    /// ⚠️ For callers ABOVE the HTTP layer — the ReAct loop, Planning, Reflexion. The token itself is
    /// taken exactly once per request by `CloudRequestPipeline`, which every metered provider call
    /// goes through. These callers used `wait(forKey:)` too, so each model call cost TWO tokens and
    /// every limit was effectively halved (a `:free` OpenRouter model got ~10 steps/min, not 20).
    /// They still want backpressure — pause before a step rather than fire it into a dry bucket, and
    /// show "Throttling…" while doing it — which is what this provides without the second charge.
    @discardableResult
    func waitForCapacity(forKey key: String, category: RateLimitCategory) async -> TimeInterval {
        let delay = timeUntilNextToken(forKey: key, category: category)
        // Debt is bounded by `drainAndPenalize` (≤ 1 h); clamp anyway so a bad value can't trap
        // the `UInt64` conversion.
        guard delay > 0, delay.isFinite else { return 0 }
        let bounded = min(delay, 3600)
        do {
            try await Task.sleep(nanoseconds: UInt64(bounded * 1_000_000_000))
        } catch {
            logger.warning("Rate limit capacity wait interrupted.")
        }
        return bounded
    }

    /// Tokens the bucket would hold right now (refill included), or nil when it doesn't exist yet.
    /// Read-only; for diagnostics and tests.
    func availableTokens(forKey key: String) -> Double? {
        guard let bucket = buckets[key] else { return nil }
        let refill = Date().timeIntervalSince(bucket.lastRefill) * bucket.tokensPerSecond
        return min(bucket.maxBurst, bucket.currentTokens + refill)
    }

    /// Checks the current estimated wait time without consuming a token.
    func timeUntilNextToken(forKey key: String, category: RateLimitCategory) -> TimeInterval {
        guard category != .local else { return 0 } // local is unmetered

        guard let bucket = buckets[key] else { return 0 }

        let now = Date()
        let timeElapsed = now.timeIntervalSince(bucket.lastRefill)
        let projectedTokens = min(bucket.maxBurst, bucket.currentTokens + (timeElapsed * bucket.tokensPerSecond))

        if projectedTokens >= 1.0 {
            return 0
        } else {
            let missing = 1.0 - projectedTokens
            return missing / bucket.tokensPerSecond
        }
    }

    /// Legacy bridge for timeUntilNextToken using category as key.
    func timeUntilNextToken(for category: RateLimitCategory) -> TimeInterval {
        timeUntilNextToken(forKey: category.rawValue, category: category)
    }
}
