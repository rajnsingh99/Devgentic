//
//  LLMRetryStrategy.swift
//  Devgentic
//
//  Created for ReAct Executor Modularization.
//

import Foundation
import OSLog

private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "com.devgentic.app", category: "LLMRetryStrategy")

/// A concrete implementation of `LLMRetryHandling`.
/// Parses errors thrown by the `CognitiveGenerator` (HTTP 429s, Timeouts, JSON Parse Failures)
/// and dictates the retry backoff sequence to the orchestrator.
struct LLMRetryStrategy: LLMRetryHandling {
    
    private static let maxConsecutiveParseFailures = 3
    
    private(set) var consecutiveRetries = 0
    private(set) var consecutiveParseFailures = 0
    
    // MARK: - Error Handling
    
    mutating func handleError(_ error: Error) -> RetryAction {
        let errorDesc = error.localizedDescription
        let isRateLimit = errorDesc.contains("429") || errorDesc.localizedCaseInsensitiveContains("rate limit")
        let isTimeout = (error as? URLError)?.code == .timedOut || errorDesc.contains("timed out")
        
        if isRateLimit {
            consecutiveRetries += 1
            let retryAfter = extractRetryAfter(from: error, consecutiveRetries: consecutiveRetries)
            // Local capture for OSLog
            let retrySecs = Int(retryAfter)
            logger.warning("Rate limit hit (HTTP 429). Throttling for \(retrySecs)s.")
            return .throttle(seconds: retryAfter, message: "🛑 API Quota Hit. Pausing for \(retrySecs)s...")
        }
        
        if isTimeout {
            logger.warning("Network timeout. Retrying request.")
            return .networkRetry(message: "⏳ Network Timeout. Retrying request...")
        }
        
        // Treat as a Parse Failure (e.g., model returned malformed JSON)
        consecutiveParseFailures += 1
        
        // Local captures to prevent escaping mutating 'self' in OSLog autoclosure
        let currentFailures = consecutiveParseFailures
        let maxFailures = Self.maxConsecutiveParseFailures
        
        logger.error("Cognitive Generation Failed (\(currentFailures)/\(maxFailures)): \(errorDesc)")
        
        if currentFailures >= maxFailures {
            logger.error("Maximum consecutive parse failures reached. Aborting execution.")
            return .abort(reason: "I'm having trouble processing this request right now — the model is returning responses I can't interpret. Please try rephrasing your request or switching to a different model.")
        }
        
        let systemAlert = "Your last output failed validation (attempt \(currentFailures)/\(maxFailures)). You MUST output a valid JSON response containing `reasoning` and `toolCalls` (an array of tools). No prose or markdown fences (```json)."
        
        return .parseRetry(
            systemAlert: systemAlert,
            attemptCount: currentFailures,
            maxAttempts: maxFailures
        )
    }
    
    mutating func resetParseFailures() {
        consecutiveRetries = 0
        consecutiveParseFailures = 0
    }
    
    // MARK: - Private Header Parsing
    
    private func extractRetryAfter(from error: Error, consecutiveRetries: Int) -> TimeInterval {
        let fallback = pow(2.0, Double(min(consecutiveRetries, 6)))
        let nsError = error as NSError
        let possibleKeys = ["headers", "HTTPHeaders", "com.alamofire.serialization.response.error.response.headers"]
        
        for key in possibleKeys {
            if let headers = nsError.userInfo[key] as? [AnyHashable: Any] {
                if let retryVal = headers["Retry-After"] as? String ?? headers["retry-after"] as? String {
                     if let val = parseRetryHeader(retryVal) { return val }
                }
            }
        }
        return fallback
    }
    
    private func parseRetryHeader(_ value: String) -> TimeInterval? {
        if let seconds = TimeInterval(value) { return seconds }
        let formatter = DateFormatter()
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
        if let date = formatter.date(from: value) { return date.timeIntervalSinceNow }
        return nil
    }
}
