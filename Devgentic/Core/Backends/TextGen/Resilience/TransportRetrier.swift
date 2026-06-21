//
//  TransportRetrier.swift
//  Devgentic
//
//  Resilience architecture, Phase C: bounded transport-retry decisions for flows
//  that don't run the agent loop's `LLMRetryStrategy` — primarily the bot path
//  (`ChatExecutor`), which previously had NO retry/throttle handling at all and
//  surfaced a raw error card on the first 429 (audit gap #9).
//
//  This is the bot-side peer of `LLMRetryStrategy`'s transport tier: both call the
//  shared `ProviderErrorClassifier.classifyTransport`, so they classify and bound
//  identically. It is pure decision logic — it performs NO I/O. The caller applies
//  the side effects (drain the rate bucket, emit a warning, sleep) from the
//  returned `RetryStep`, which keeps the retrier trivially unit-testable and free
//  of any `GlobalRateLimiter`/continuation coupling.
//

import Foundation

/// Thrown when transport retries are exhausted or a deterministic provider error
/// occurs. Carries the honest user-facing reason plus the telemetry category,
/// mirroring the agent path's `RetryAction.fatal` so the bot surfaces identical
/// messages. `errorDescription` is the reason, so a plain
/// `error.localizedDescription` render shows the right text.
struct TransportFatalError: Error, LocalizedError, Equatable {
    let reason: String
    let category: AgentErrorCategory
    var errorDescription: String? { reason }
}

/// Bounded transport-retry decision maker. One instance per request; its counters
/// live for that request only.
struct TransportRetrier {

    let transport: TransportResiliencePolicy

    private(set) var transientCount = 0
    private(set) var throttleCount = 0

    init(transport: TransportResiliencePolicy) {
        self.transport = transport
    }

    /// The action the caller should take to retry after a transport error.
    struct RetryStep: Equatable {
        /// Seconds to wait before retrying (already sanitized + bounded).
        let delay: TimeInterval
        /// User-facing warning text for the `.warning` stream event.
        let message: String
        /// Warning bucket — `.throttle` for 429, `.retry` for transient.
        let category: WarningCategory
        /// When non-nil (429), the caller should `drainAndPenalize` the rate bucket
        /// by this many seconds to coordinate with the shared limiter.
        let drainPenalty: TimeInterval?
    }

    /// Classifies `error` and decides the next action:
    ///   - returns a `RetryStep` → caller drains (if set), warns, sleeps, then retries;
    ///   - throws `TransportFatalError` → deterministic failure or budget exhausted;
    ///   - rethrows the original `error` → not a recognized transport error (the bot
    ///     surfaces it unchanged, exactly as before).
    ///
    /// `CancellationError` is never reached here — callers check cancellation around
    /// the operation and rethrow it before consulting the retrier.
    mutating func nextStep(for error: Error) throws -> RetryStep {
        guard let verdict = ProviderErrorClassifier.classifyTransport(
            error,
            connectionRefusedIsFatal: transport.connectionRefusedIsFatal,
            endpointHint: transport.endpointHint
        ) else {
            throw error
        }

        switch verdict {
        case .fatal(let reason, let category):
            throw TransportFatalError(reason: reason, category: category)

        case .throttle(let retryAfter):
            throttleCount += 1
            if throttleCount > transport.maxThrottleRetries {
                let reason = transport.providerClass == .cloud
                    ? "The provider is still rate-limiting after \(transport.maxThrottleRetries) waits — the quota for this profile looks exhausted. Check your plan/billing with the provider, or switch profiles."
                    : "The model server is still rate-limiting after \(transport.maxThrottleRetries) waits. Check the server or proxy configuration."
                throw TransportFatalError(reason: reason, category: .providerQuotaExhausted)
            }
            let wait = ProviderErrorClassifier.sanitizedRetryAfter(retryAfter) ?? fallbackBackoff()
            // chip task_70f0522b: avoid the 429 double-drain. CloudRequestPipeline already drains
            // the bucket for a cloud 429 (it throws CloudProviderError only after draining), so the
            // caller must NOT drain again. Only ask the caller to drain for pipeline-bypassing
            // providers (Ollama/local → LLMProviderError.httpError).
            let drainPenalty: TimeInterval? = (error is CloudProviderError) ? nil : wait
            return RetryStep(
                delay: wait,
                message: "🛑 Rate limited — pausing \(Int(wait))s (\(throttleCount)/\(transport.maxThrottleRetries))…",
                category: .throttle,
                drainPenalty: drainPenalty
            )

        case .transient(let detail):
            transientCount += 1
            if transientCount > transport.maxTransientRetries {
                let retriesSuffix = transport.maxTransientRetries > 0 ? " after \(transport.maxTransientRetries) retries" : ""
                let reason: String = switch transport.providerClass {
                case .cloud:
                    "The provider is unavailable (\(detail))\(retriesSuffix). Try again in a few minutes."
                case .ollama:
                    "The model server is unavailable (\(detail))\(retriesSuffix). Check that the model is loaded and the server is healthy."
                case .mlx:
                    "The local model failed (\(detail)). Try reloading the model or switching to a smaller one."
                }
                throw TransportFatalError(reason: reason, category: .providerServerError)
            }
            let delay = transport.transientDelay(attempt: transientCount)
            return RetryStep(
                delay: delay,
                message: "⏳ \(detail) — retrying in \(Int(delay))s (\(transientCount)/\(transport.maxTransientRetries))…",
                category: .retry,
                drainPenalty: nil
            )
        }
    }

    /// 429 fallback delay when the server sent no usable Retry-After header.
    private func fallbackBackoff() -> TimeInterval {
        switch transport.backoffStrategy {
        case .exponential: return min(pow(2.0, Double(min(throttleCount, 6))), transport.maxBackoff)
        case .fixed: return 2.0
        }
    }
}
