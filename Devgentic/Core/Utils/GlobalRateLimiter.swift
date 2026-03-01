//
//  GlobalRateLimiter.swift
//  Devgentic
//
//  Created by Raj Singh on 17/02/26.
//

import Foundation
import os

/// Defines distinct rate limit profiles for different providers.
enum RateLimitCategory: String, Codable {
    case local
    case openAI
    case geminiFlash
    case anthropic
}

/// A thread-safe Token Bucket implementation to manage API quotas globally.
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
    
    private var buckets: [RateLimitCategory: Bucket]
    
    // MARK: - Initialization
    
    private init() {
        self.buckets = [
            // Gemini Flash Free Tier: 15 RPM
            // Rate: 15/60 = 0.25 tokens/sec (1 token every 4s)
            // Burst: 5 tokens (Allows a quick "Think -> Decide -> Act" burst)
            .geminiFlash: Bucket(
                maxBurst: 5.0,
                tokensPerSecond: 15.0 / 60.0,
                currentTokens: 5.0,
                lastRefill: Date()
            ),
            
            // OpenAI Tier 1: ~500 RPM (Conservative)
            // Rate: 8.33 tokens/sec
            // Burst: 10 tokens
            .openAI: Bucket(
                maxBurst: 10.0,
                tokensPerSecond: 500.0 / 60.0,
                currentTokens: 10.0,
                lastRefill: Date()
            ),
            
            // Local (Ollama/MLX):
            // Hardware limited. We throttle slightly to keep the UI responsive.
            // 60 RPM (1/sec)
            .local: Bucket(
                maxBurst: 1.0,
                tokensPerSecond: 1.0,
                currentTokens: 1.0,
                lastRefill: Date()
            )
        ]
        logger.info("GlobalRateLimiter initialized with Token Bucket algorithm.")
    }
    
    // MARK: - Public API
    
    /// Acquires a token for the specified category.
    /// Suspends execution if the bucket is empty until a token is available.
    /// - Returns: The time waited (in seconds).
    @discardableResult
    func wait(for category: RateLimitCategory) async -> TimeInterval {
        guard var bucket = buckets[category] else {
            // Fallback for unknown categories (no limiting)
            return 0
        }
        
        let now = Date()
        let timeElapsed = now.timeIntervalSince(bucket.lastRefill)
        
        // 1. Refill
        let newTokens = timeElapsed * bucket.tokensPerSecond
        bucket.currentTokens = min(bucket.maxBurst, bucket.currentTokens + newTokens)
        bucket.lastRefill = now
        
        // 2. Consume
        var waitTime: TimeInterval = 0
        
        if bucket.currentTokens >= 1.0 {
            // Happy Path: Token available
            bucket.currentTokens -= 1.0
        } else {
            // Throttling Path: Calculate debt
            let missingTokens = 1.0 - bucket.currentTokens
            waitTime = missingTokens / bucket.tokensPerSecond
            
            // We go into debt (negative tokens) to reserve the slot
            bucket.currentTokens -= 1.0
            
            logger.notice("⏳ Rate Limit Throttling (\(String(describing: category))): Wait \(String(format: "%.2f", waitTime))s. Tokens left: \(String(format: "%.2f", bucket.currentTokens))")
        }
        
        // Save state back
        buckets[category] = bucket
        
        // 3. Suspend if needed
        if waitTime > 0 {
            do {
                // Wait for the calculated duration to "pay off" the debt
                try await Task.sleep(nanoseconds: UInt64(waitTime * 1_000_000_000))
            } catch {
                logger.warning("Rate limit sleep interrupted.")
            }
        }
        
        return waitTime
    }
    
    /// Drains the bucket to force a hard reset.
    /// Used when the server responds with 429 despite our local counting (Drift).
    /// - Parameter penalty: Additional seconds to push the `lastRefill` back (adding debt).
    func drainAndPenalize(category: RateLimitCategory, penaltySeconds: TimeInterval = 0) {
        guard var bucket = buckets[category] else { return }
        
        // Reset tokens to 0 (or keep negative if we are already in deep debt)
        bucket.currentTokens = min(0, bucket.currentTokens)
        
        // Apply penalty by setting tokens negative equivalent to the time
        // tokens = -1 * (penalty * rate)
        let penaltyTokens = penaltySeconds * bucket.tokensPerSecond
        bucket.currentTokens -= penaltyTokens
        
        bucket.lastRefill = Date()
        buckets[category] = bucket
        
        logger.warning("🛑 Bucket Drained for \(String(describing: category)). Penalty applied: \(penaltySeconds)s (New Debt: \(bucket.currentTokens) tokens)")
    }
    
    /// Checks the current estimated wait time without consuming a token.
    /// Useful for UI feedback ("Estimated wait: 3s").
    func timeUntilNextToken(for category: RateLimitCategory) -> TimeInterval {
        guard let bucket = buckets[category] else { return 0 }
        
        // Calculate theoretical tokens right now
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
}
