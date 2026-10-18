// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
//
//  TransportRetrier.swift
//  Devgentic
//
//  Created by Raj Singh.
//

import Foundation

/// Thrown when transport retries are exhausted or a deterministic provider error occurs.
/// Carries the user-facing reason and telemetry category, mirroring the agent path's `RetryAction.fatal`.
/// `errorDescription` is the reason, so `localizedDescription` shows the right text.
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
    // Why: charging it to `transientCount` would fail on the first hit because the MLX transient budget is 0
    /// Budget for the MLX model-slot race, mirroring `LLMRetryStrategy.consecutiveModelSlotFailures`.
    private(set) var modelSlotCount = 0

    /// One bounded re-attempt, then fail; same bound and delay as the agent path (`LLMRetryStrategy`).
    /// The retry reloads the requested model, so a second consecutive loss means a live contender keeps evicting it.
    private static let maxModelSlotRetries = 1
    private static let modelSlotRetryDelay: TimeInterval = 2.0

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

    /// Classifies `error` and decides the next action: returns a `RetryStep` (caller drains if set, warns, sleeps, retries),
    /// throws `TransportFatalError` if deterministic or exhausted, else rethrows an unrecognized error.
    mutating func nextStep(for error: Error) throws -> RetryStep {
        // Why: adding `ServiceError` to `classifyTransport` would intercept it ahead of the agent path's own typed switch
        // Typed MLX model-slot arm, checked before the shared classifier.
        if let mlxError = error as? MLXService.ServiceError {
            return try modelSlotStep(for: mlxError)
        }

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
            // The caller must not drain again for a cloud 429: `CloudRequestPipeline` already drained the bucket.
            // Only pipeline-bypassing providers (Ollama/local, `LLMProviderError.httpError`) ask the caller to drain.
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
                throw TransportFatalError(reason: reason, category: ProviderErrorClassifier.exhaustedCategory(forDetail: detail))
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

    // Why: no `default:` on purpose: a new `ServiceError` case must break the build instead of falling through to rethrow
    /// The MLX model-slot race, bounded identically to the agent path's `modelSlotAction`, with the same messages.
    private mutating func modelSlotStep(for error: MLXService.ServiceError) throws -> RetryStep {
        switch error {
        case .modelIdentityMismatch(let expected, let actual):
            modelSlotCount += 1
            // "<none>" means the slot was EMPTIED by a concurrent load, not that a named model
            // is squatting — never render it to the user as a model name (mirrors modelSlotAction).
            let holder = (actual == "<none>") ? "another local model load" : "'\(actual)'"
            if modelSlotCount > Self.maxModelSlotRetries {
                throw TransportFatalError(
                    reason: "This run needs the local model '\(expected)', but \(holder) still held the model slot after a retry. Only one MLX model stays in memory at a time, so two local runs evict each other. Nothing was answered by the wrong model. Run them one at a time — or point both profiles at the same model — and try again.",
                    category: .modelUnloaded
                )
            }
            return RetryStep(
                delay: Self.modelSlotRetryDelay,
                message: "⏳ \(holder) is using the local model slot — reloading '\(expected)' and retrying in \(Int(Self.modelSlotRetryDelay))s (\(modelSlotCount)/\(Self.maxModelSlotRetries))...",
                category: .retry,
                drainPenalty: nil
            )

        case .noModelLoaded:
            // Deterministic: thrown only when the request carried no expected model identity, so a retry re-issues the same request.
            throw TransportFatalError(
                reason: error.localizedDescription,
                category: .modelUnloaded
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
