//
//  LLMRetryStrategy.swift
//  Devgentic
//
//  Created for ReAct Executor Modularization.
//  Reworked for the Phase-A resilience architecture (audit #5): typed 4xx
//  triage via ProviderErrorClassifier, bounded transient/throttle budgets from
//  TransportResiliencePolicy, and honest `.fatal` verdicts for deterministic
//  failures — provider errors never masquerade as model parse failures.
//

import Foundation
import OSLog

private let logger = DGLogger(category: "LLMRetryStrategy")

/// A concrete implementation of `LLMRetryHandling`.
/// Applies the resolved transport/cognitive retry budgets to errors thrown by
/// the `CognitiveGenerator` and dictates the executor's next move.
struct LLMRetryStrategy: LLMRetryHandling {

    private let maxConsecutiveParseFailures: Int
    private let backoffStrategy: BackoffStrategy
    private let transport: TransportResiliencePolicy

    private(set) var consecutiveRetries = 0            // 429 throttles
    private(set) var consecutiveParseFailures = 0
    private(set) var consecutiveTransientFailures = 0  // 5xx + timeouts + connection drops

    init(
        maxConsecutiveParseFailures: Int = 3,
        backoffStrategy: BackoffStrategy = .exponential,
        transport: TransportResiliencePolicy = ResolvedResiliencePolicy.resolved(for: .cloud).transport
    ) {
        self.maxConsecutiveParseFailures = maxConsecutiveParseFailures
        self.backoffStrategy = backoffStrategy
        self.transport = transport
    }

    // MARK: - Error Handling

    mutating func handleError(_ error: Error) -> RetryAction {
        // Recognized transport-level errors (structured CloudProviderError, Ollama
        // LLMProviderError.httpError, or any URLError) classify through the shared
        // vocabulary — the bot path's TransportRetrier uses the same function, so
        // both agree by construction. A nil result means the error is NOT
        // transport-level; we fall through to model/parse handling below.
        if let verdict = ProviderErrorClassifier.classifyTransport(
            error,
            connectionRefusedIsFatal: transport.connectionRefusedIsFatal,
            endpointHint: transport.endpointHint
        ) {
            let cloudError = error as? CloudProviderError
            let providerLabel = cloudError.map { String(describing: $0.provider) } ?? "local"
            return apply(verdict, requestId: cloudError?.requestId, providerLabel: providerLabel)
        }

        // --- Legacy String-Based Detection (local providers, wrapped errors) ---
        let errorDesc = error.localizedDescription
        let isRateLimit = errorDesc.contains("429") || errorDesc.localizedCaseInsensitiveContains("rate limit")
        let isTimeout = errorDesc.contains("timed out")

        if isRateLimit {
            let headerValue = extractRetryAfter(from: error)
            return throttleAction(retryAfter: headerValue, requestId: nil, provider: "local")
        }

        if isTimeout {
            return transientAction(detail: "request timed out", requestId: nil)
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

        // Treat as a Parse Failure (e.g., model returned malformed JSON).
        // This path is now reserved for what it was designed for: the MODEL's
        // output being unprocessable — provider/transport errors are classified
        // above and never reach here.
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
        consecutiveTransientFailures = 0
    }

    // MARK: - Budgeted Verdict Application

    /// Routes a classifier verdict through the stateful retry budgets.
    private mutating func apply(_ verdict: ProviderErrorVerdict, requestId: String?, providerLabel: String) -> RetryAction {
        switch verdict {
        case .throttle(let retryAfter):
            return throttleAction(retryAfter: retryAfter, requestId: requestId, provider: providerLabel)
        case .transient(let detail):
            return transientAction(detail: detail, requestId: requestId)
        case .fatal(let reason, let category):
            logger.error("Provider fatal (\(category.rawValue)): \(reason)")
            return .fatal(reason: reason, category: category)
        }
    }

    /// 429 handling: honor a SANE Retry-After (finite, non-negative, ≤1h) or fall
    /// back to the configured backoff shape; give up past the throttle budget — a
    /// 429 that persists through N waits is an exhausted quota, not a burst.
    private mutating func throttleAction(retryAfter: TimeInterval?, requestId: String?, provider: String) -> RetryAction {
        consecutiveRetries += 1

        if consecutiveRetries > transport.maxThrottleRetries {
            let requestRef = requestId.map { " request-id: \($0)." } ?? ""
            logger.error("Rate limit persisted after \(transport.maxThrottleRetries) waits (\(provider)). Giving up.\(requestRef)")
            // Billing guidance only makes sense for cloud quotas; a local server
            // rate-limiting is a proxy/config situation.
            let reason = transport.providerClass == .cloud
                ? "The provider is still rate-limiting after \(transport.maxThrottleRetries) waits — the quota for this profile looks exhausted. Check your plan/billing with the provider, or switch profiles.\(requestRef)"
                : "The model server is still rate-limiting after \(transport.maxThrottleRetries) waits. Check the server or proxy configuration.\(requestRef)"
            return .fatal(reason: reason, category: .providerQuotaExhausted)
        }

        let defaultBackoff: TimeInterval = switch backoffStrategy {
        case .exponential: min(pow(2.0, Double(min(consecutiveRetries, 6))), transport.maxBackoff)
        case .fixed: 2.0
        }
        let wait = ProviderErrorClassifier.sanitizedRetryAfter(retryAfter) ?? defaultBackoff
        logger.warning("429 (\(provider)). request-id: \(requestId ?? "n/a"). Throttling \(Int(wait))s (\(consecutiveRetries)/\(transport.maxThrottleRetries)).")
        return .throttle(seconds: wait, message: "🛑 API Quota Hit. Pausing for \(Int(wait))s...")
    }

    /// Transient handling (5xx/timeouts/connection blips): bounded retries with
    /// exponential backoff; honest `.fatal` once the budget is spent. Previously
    /// this returned an uncapped, zero-delay `.networkRetry` — an infinite
    /// hammer-loop during outages (audit gap #5).
    private mutating func transientAction(detail: String, requestId: String?) -> RetryAction {
        consecutiveTransientFailures += 1

        if consecutiveTransientFailures > transport.maxTransientRetries {
            // Only reachable at budget+1 — the counter and check move together.
            let attempted = transport.maxTransientRetries
            let requestRef = requestId.map { " request-id: \($0)." } ?? ""
            logger.error("Transient failure persisted (\(detail)) after \(attempted) retries. Giving up.\(requestRef)")
            let retriesSuffix = attempted > 0 ? " after \(attempted) retries" : ""
            let reason: String = switch transport.providerClass {
            case .cloud:
                "The provider is unavailable (\(detail))\(retriesSuffix). Try again in a few minutes.\(requestRef)"
            case .ollama:
                "The model server is unavailable (\(detail))\(retriesSuffix). Check that the model is loaded and the server is healthy.\(requestRef)"
            case .mlx:
                "The local model failed (\(detail)). Try reloading the model or switching to a smaller one."
            }
            return .fatal(reason: reason, category: .providerServerError)
        }

        let delay = transport.transientDelay(attempt: consecutiveTransientFailures)
        logger.warning("Transient failure (\(detail)). request-id: \(requestId ?? "n/a"). Retrying in \(Int(delay))s (\(consecutiveTransientFailures)/\(transport.maxTransientRetries)).")
        return .networkRetry(
            message: "⏳ \(detail) — retrying in \(Int(delay))s (\(consecutiveTransientFailures)/\(transport.maxTransientRetries))...",
            delaySeconds: delay
        )
    }

    // MARK: - Private Header Parsing

    private func extractRetryAfter(from error: Error) -> TimeInterval? {
        let nsError = error as NSError
        let possibleKeys = ["headers", "HTTPHeaders", "com.alamofire.serialization.response.error.response.headers"]

        for key in possibleKeys {
            if let headers = nsError.userInfo[key] as? [AnyHashable: Any] {
                if let retryVal = headers["Retry-After"] as? String ?? headers["retry-after"] as? String {
                     if let val = parseRetryHeader(retryVal) { return val }
                }
            }
        }
        return nil
    }

    private func parseRetryHeader(_ value: String) -> TimeInterval? {
        if let seconds = TimeInterval(value) { return seconds }
        let formatter = DateFormatter()
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
        formatter.locale = Locale(identifier: "en_US_POSIX") // HTTP-dates are English regardless of system locale
        if let date = formatter.date(from: value) {
            let interval = date.timeIntervalSinceNow
            return interval > 0 ? interval : nil
        }
        return nil
    }
}
