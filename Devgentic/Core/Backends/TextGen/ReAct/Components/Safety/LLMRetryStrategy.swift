//
//  LLMRetryStrategy.swift
//  Devgentic
//
//  Created for ReAct Executor Modularization.
//

import Foundation
import OSLog

private let logger = DGLogger(category: "LLMRetryStrategy")

/// A concrete implementation of `LLMRetryHandling`.
/// Parses errors thrown by the `CognitiveGenerator` (HTTP 429s, Timeouts, JSON Parse Failures)
/// and dictates the retry backoff sequence to the orchestrator.
struct LLMRetryStrategy: LLMRetryHandling {

    private let maxConsecutiveParseFailures: Int
    private let backoffStrategy: BackoffStrategy

    private(set) var consecutiveRetries = 0
    private(set) var consecutiveParseFailures = 0

    init(maxConsecutiveParseFailures: Int = 3, backoffStrategy: BackoffStrategy = .exponential) {
        self.maxConsecutiveParseFailures = maxConsecutiveParseFailures
        self.backoffStrategy = backoffStrategy
    }
    
    // MARK: - Error Handling
    
    mutating func handleError(_ error: Error) -> RetryAction {
        // --- Structured Cloud Provider Error (from CloudRequestPipeline) ---
        // This is the preferred path for cloud providers (Anthropic, OpenAI, Gemini)
        // which provides exact status codes and retry-after headers.
        if let cloudError = error as? CloudProviderError {
            if cloudError.statusCode == 429 {
                consecutiveRetries += 1
                let defaultBackoff: TimeInterval = switch backoffStrategy {
                case .exponential: pow(2.0, Double(min(consecutiveRetries, 6)))
                case .fixed: 2.0
                }
                let retryAfter = cloudError.retryAfterSeconds ?? defaultBackoff
                let retrySecs = Int(retryAfter)
                logger.warning("Cloud 429 (\(String(describing: cloudError.provider))). request-id: \(cloudError.requestId ?? "n/a"). Throttling for \(retrySecs)s.")
                return .throttle(seconds: retryAfter, message: "🛑 API Quota Hit. Pausing for \(retrySecs)s...")
            }
            if cloudError.statusCode >= 500 {
                logger.warning("Cloud server error (\(cloudError.statusCode)). request-id: \(cloudError.requestId ?? "n/a"). Retrying.")
                return .networkRetry(message: "⏳ Server Error (\(cloudError.statusCode)). Retrying...")
            }
            // For 4xx errors other than 429 (e.g., 400 bad request, 401 auth),
            // these are not retryable — fall through to parse failure handling.
        }

        // --- Legacy String-Based Detection (for local providers: Ollama, MLX) ---
        let errorDesc = error.localizedDescription
        let isRateLimit = errorDesc.contains("429") || errorDesc.localizedCaseInsensitiveContains("rate limit")
        let isTimeout = (error as? URLError)?.code == .timedOut || errorDesc.contains("timed out")

        if isRateLimit {
            consecutiveRetries += 1
            let retryAfter = extractRetryAfter(from: error, consecutiveRetries: consecutiveRetries)
            let retrySecs = Int(retryAfter)
            logger.warning("Rate limit hit (HTTP 429). Throttling for \(retrySecs)s.")
            return .throttle(seconds: retryAfter, message: "🛑 API Quota Hit. Pausing for \(retrySecs)s...")
        }

        if isTimeout {
            logger.warning("Network timeout. Retrying request.")
            return .networkRetry(message: "⏳ Network Timeout. Retrying request...")
        }

        // Model was unloaded (e.g., idle timer fired during HITL suspension).
        // Must be detected BEFORE the catch-all parse failure to avoid futile retries.
        let isModelUnloaded = errorDesc.contains("No MLX model is currently loaded") ||
                              errorDesc.contains("No Ollama model")
        if isModelUnloaded {
            logger.warning("Model was unloaded during execution. Requesting reload.")
            return .modelReload(message: "⏳ Model was released from memory. Reloading...")
        }

        // Capability gap: the model doesn't support tool calling at all.
        // Reasoning-only models (deepseek-r1 family, o1-likes) hit this — Ollama
        // rejects the request at the server layer before the model runs. Retrying
        // yields the same 400 every time, so fail fast with a distinct UI path:
        // `capabilityFailure` routes to an error card, not plain content.
        if let providerError = error as? LLMProviderError,
           case .toolsUnsupported = providerError {
            logger.error("Tools-unsupported capability gap: \(errorDesc). Aborting without retry.")
            return .capabilityFailure(reason: errorDesc)
        }

        // Treat as a Parse Failure (e.g., model returned malformed JSON)
        consecutiveParseFailures += 1
        
        // Local captures to prevent escaping mutating 'self' in OSLog autoclosure
        let currentFailures = consecutiveParseFailures
        let maxFailures = maxConsecutiveParseFailures
        
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
        let fallback: TimeInterval = switch backoffStrategy {
        case .exponential: pow(2.0, Double(min(consecutiveRetries, 6)))
        case .fixed: 2.0
        }
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
