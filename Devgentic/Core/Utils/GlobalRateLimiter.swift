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

    /// Conservative default RPM for each provider tier.
    var defaultTokensPerSecond: Double {
        switch self {
        case .local:       return 1.0          // 60 RPM — hardware bound
        case .geminiFlash: return 15.0 / 60.0  // 15 RPM — free tier
        case .anthropic:   return 50.0 / 60.0  // 50 RPM — Tier 1
        case .openAI:      return 500.0 / 60.0 // 500 RPM — Tier 1
        }
    }

    /// Maximum burst tokens (allows rapid-fire up to this count).
    var defaultMaxBurst: Double {
        switch self {
        case .local:       return 1.0
        case .geminiFlash: return 5.0
        case .anthropic:   return 5.0
        case .openAI:      return 10.0
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
    static func deriveBucketKey(provider: ApiProvider, apiKey: String?, baseURL: String?) -> String {
        switch provider {
        case .anthropic, .openAI, .google:
            let category = Self.from(provider: provider)
            let keyHash = apiKey.map { String($0.hashValue) } ?? "no-key"
            return "\(category.rawValue):\(keyHash)"
        case .ollama:
            let urlHash = baseURL.map { String($0.hashValue) } ?? "localhost"
            return "local:\(urlHash)"
        case .mlx:
            return "local:mlx"
        }
    }

    /// Maps ApiProvider to the corresponding rate limit category.
    static func from(provider: ApiProvider) -> RateLimitCategory {
        switch provider {
        case .anthropic: return .anthropic
        case .google:    return .geminiFlash
        case .openAI:    return .openAI
        case .ollama, .mlx: return .local
        }
    }
}

/// A thread-safe Token Bucket implementation to manage API quotas.
/// Buckets are keyed on (provider + apiKey/baseURL) so profiles sharing
/// the same API key share the same server-side quota boundary.
/// Prevents "Death Spirals" where multiple agent loops exhaust limits simultaneously.
actor GlobalRateLimiter {

    // MARK: - Singleton
    static let shared = GlobalRateLimiter()

    private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "com.devgentic.app", category: "GlobalRateLimiter")

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
    func drainAndPenalize(key: String, category: RateLimitCategory, penaltySeconds: TimeInterval = 0) {
        var bucket = getOrCreateBucket(key: key, category: category)

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

    /// Checks the current estimated wait time without consuming a token.
    func timeUntilNextToken(forKey key: String, category: RateLimitCategory) -> TimeInterval {
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
