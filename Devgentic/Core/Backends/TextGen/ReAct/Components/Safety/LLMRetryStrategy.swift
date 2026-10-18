// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
//
//  LLMRetryStrategy.swift
//  Devgentic
//
//  Created by Raj Singh.
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

    // Why: the parse-failure corrective must name this run's own dialect;
    // prescribing a format its parser rejects (e.g. banning a fence a dialect requires) makes retries fail.
    /// The tool-call wire format this run's generator asks for, or nil on a transport-native flow.
    /// Resolved once per run: `AgentConnect.resolveCognitiveGenerator` picks the generator at run start.
    private let dialect: ModelDialect?

    private(set) var consecutiveRetries = 0            // 429 throttles
    private(set) var consecutiveParseFailures = 0
    private(set) var consecutiveTransientFailures = 0  // 5xx + timeouts + connection drops

    /// Consecutive MLX model-slot races (`MLXService.ServiceError.modelIdentityMismatch`).
    /// Has its own budget: the MLX transport budget is 0 by design, and the model produced nothing to parse.
    private(set) var consecutiveModelSlotFailures = 0

    /// Consecutive generations that returned no output (`GenerationError.emptyResponse`).
    /// Has its own budget: the model produced nothing to parse, so charging the parse cap would abort on the wrong limit.
    private(set) var consecutiveEmptyResponses = 0

    /// How many empty generations in a row before giving up.
    /// Lower than the parse cap: a parse failure can be corrected by a nudge, an empty response only by a new sample.
    private static let maxConsecutiveEmptyResponses = 3

    /// The number of outer retries for an MLX model-slot race.
    /// `container(expecting:)` already re-loads twice before throwing, so an outer attempt only adds elapsed time.
    /// One wait covers a short competitor; a second would re-read multi-GB weights against sustained contention.
    private static let maxModelSlotRetries = 1

    /// Wait before the single re-run: long enough for a one-shot classifier to release the slot,
    /// short enough that a genuinely stuck slot fails fast. An estimate, not a measured value.
    private static let modelSlotRetryDelay: TimeInterval = 2.0

    init(
        maxConsecutiveParseFailures: Int = 3,
        backoffStrategy: BackoffStrategy = .exponential,
        transport: TransportResiliencePolicy = ResolvedResiliencePolicy.resolved(for: .cloud).transport,
        dialect: ModelDialect? = nil
    ) {
        self.maxConsecutiveParseFailures = maxConsecutiveParseFailures
        self.backoffStrategy = backoffStrategy
        self.transport = transport
        self.dialect = dialect
    }

    // MARK: - Error Handling

    mutating func handleError(_ error: Error) -> RetryAction {
        // Recognized transport-level errors classify through the shared vocabulary (the same function as the bot path's
        // `TransportRetrier`); nil means not transport-level, so fall through to model/parse handling.
        if let verdict = ProviderErrorClassifier.classifyTransport(
            error,
            connectionRefusedIsFatal: transport.connectionRefusedIsFatal,
            endpointHint: transport.endpointHint
        ) {
            let cloudError = error as? CloudProviderError
            let providerLabel = cloudError.map { String(describing: $0.provider) } ?? "local"
            return apply(verdict, requestId: cloudError?.requestId, providerLabel: providerLabel)
        }

        // Empty output is not a parse failure: every arm here returns, so control never reaches
        // `consecutiveParseFailures += 1` and the parse-failure corrective is not injected.
        if case GenerationError.emptyResponse(let generator) = error {
            return emptyResponseAction(generator: generator)
        }

        // Typed local-runtime errors, matched by type; must precede the string tests below. Every arm returns, so
        // control never reaches `consecutiveParseFailures += 1`. No `default:`, so a new `ServiceError` case breaks the build.
        if let mlxError = error as? MLXService.ServiceError {
            switch mlxError {
            case .noModelLoaded:
                // Currently unreachable: both `MLXLLMProvider` construction sites pin a non-nil `modelDirectory`.
                // Kept and routed by type so the exhaustive switch stays honest if that changes.
                logger.warning("[MLX-LOAD] No MLX model resident and the request carried no expected model identity. CONSEQUENCE: the iteration is rewound and re-run after a reload attempt; the parse budget is untouched and no corrective alert enters the model's context.")
                return .modelReload(message: "⏳ Model was released from memory. Reloading...")

            case .modelIdentityMismatch(let expected, let actual):
                return modelSlotAction(expected: expected, actual: actual)
            }
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
            return transientAction(detail: ProviderErrorClassifier.timeoutDetail, requestId: nil)
        }

        // Ollama's local-model-unloaded string; Ollama's real model-missing error is an `httpError` 404 already
        // classified by `classifyTransport` above, so this branch has no producer in this repo.
        if errorDesc.contains("No Ollama model") {
            logger.warning("Model was unloaded during execution. Requesting reload.")
            return .modelReload(message: "⏳ Model was released from memory. Reloading...")
        }

        // Capability gap: the model does not support tool calling (e.g. the deepseek-r1 family); Ollama rejects the
        // request before the model runs, so fail fast: `capabilityFailure` routes to an error card.
        if let providerError = error as? LLMProviderError,
           case .toolsUnsupported = providerError {
            logger.error("Tools-unsupported capability gap: \(errorDesc). Aborting without retry.")
            return .capabilityFailure(reason: errorDesc)
        }

        // Treat as a parse failure (the model's output was unprocessable); provider and transport errors are
        // classified above and never reach here.
        consecutiveParseFailures += 1

        // Local captures to prevent escaping mutating 'self' in OSLog autoclosure
        let currentFailures = consecutiveParseFailures
        let maxFailures = maxConsecutiveParseFailures
        let errorType = String(describing: type(of: error))
        // Named in the log because the corrective's content depends on it: `native` vs a dialect name selects
        // an entirely different alert.
        let dialectLabel = dialect?.rawValue ?? "native (no text dialect)"

        // The error type and the word UNCLASSIFIED make an unrecognised error visible in logs; if the type is plainly
        // not a model-output fault, it needs a typed arm above.
        logger.error("Cognitive Generation Failed (\(currentFailures)/\(maxFailures)) — UNCLASSIFIED \(errorType): \(errorDesc). dialect=\(dialectLabel). CONSEQUENCE: counted as a MODEL parse failure — a corrective alert naming that dialect's tool-call format is injected into the model's context and telemetry records .parseExhausted. Both are wrong if the model's output was not the cause.")

        if currentFailures >= maxFailures {
            logger.error("Maximum consecutive parse failures reached. Aborting execution.")
            return .abort(reason: "I'm having trouble processing this request right now — the model is returning responses I can't interpret. Please try rephrasing your request or switching to a different model.")
        }

        return .parseRetry(
            systemAlert: Self.correctiveAlert(
                dialect: dialect,
                attempt: currentFailures,
                maxAttempts: maxFailures
            ),
            attemptCount: currentFailures,
            maxAttempts: maxFailures
        )
    }

    // Why: never prescribe a format the run's own parser would reject.
    /// Builds the corrective injected into the model's own context before the retry.
    /// A known dialect names its own format only (`ModelDialect.formatReminder`); no dialect says nothing about format.
    /// Both name `final_answer` so a model that has finished can exit; `static` and pure for testability.
    static func correctiveAlert(dialect: ModelDialect?, attempt: Int, maxAttempts: Int) -> String {
        let preamble = "Your last output could not be parsed (attempt \(attempt)/\(maxAttempts))."
        guard let dialect else {
            return "\(preamble) Emit your tool call using this provider's native tool-calling API, or call `final_answer` if you are finished."
        }
        return "\(preamble) This model's tool-call format is \(dialect.formatReminder). Emit exactly that shape, or call `final_answer` if you are finished."
    }

    mutating func resetParseFailures() {
        consecutiveRetries = 0
        consecutiveParseFailures = 0
        consecutiveTransientFailures = 0
        // Without this, an unrelated race later in the same run would arrive with the budget
        // already spent and fail on its first occurrence with no retry.
        consecutiveModelSlotFailures = 0
        consecutiveEmptyResponses = 0
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

    /// Transient handling (5xx/timeouts/connection blips): bounded retries with exponential backoff.
    /// Returns `.fatal` once the budget is spent.
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
            return .fatal(reason: reason, category: ProviderErrorClassifier.exhaustedCategory(forDetail: detail))
        }

        let delay = transport.transientDelay(attempt: consecutiveTransientFailures)
        logger.warning("Transient failure (\(detail)). request-id: \(requestId ?? "n/a"). Retrying in \(Int(delay))s (\(consecutiveTransientFailures)/\(transport.maxTransientRetries)).")
        return .networkRetry(
            message: "⏳ \(detail) — retrying in \(Int(delay))s (\(consecutiveTransientFailures)/\(transport.maxTransientRetries))...",
            delaySeconds: delay
        )
    }

    // Why: there is no output to correct, so a corrective alert would be a false statement that grows the prompt.
    /// Handles a provider reply with no text and no tool call: retried under its own budget with no corrective alert.
    /// The retry re-sends the same prompt and relies on sampling; a discarded MLX tool call is a parse failure instead.
    /// Same shape as `modelSlotAction`: not a parse failure, since the model produced nothing to parse.
    private mutating func emptyResponseAction(generator: String) -> RetryAction {
        consecutiveEmptyResponses += 1

        // Locals only — a `mutating` func must not let `self` escape into a log autoclosure.
        let attempt = consecutiveEmptyResponses
        let cap = Self.maxConsecutiveEmptyResponses

        if attempt >= cap {
            logger.error("[GEN_EMPTY] \(generator) returned NO output \(attempt) time(s) in a row — giving up. CONSEQUENCE: the run stops. This is NOT charged to the parse budget and telemetry does not record .parseExhausted, because the model produced nothing to parse — the cause is upstream of the parser. Read the [MLX-GEN] line for this attempt BEFORE changing anything: it reports the framework's own generatedTokens, which says whether the model emitted nothing (sampling / chat template) or emitted output that was discarded downstream (tool-call parsing). Those two have opposite fixes.")
            // A native-API empty reply usually means a reasoning model spent its whole output limit thinking.
            let reason = generator == "Native"
                ? "The model returned no answer \(attempt) times in a row. On a reasoning model (o-series, GPT-5, Gemini thinking) this usually means its reasoning used the whole output-token limit before it wrote anything — raise Max Tokens in this profile, or lower Reasoning Effort."
                : "The model returned no output \(attempt) times in a row — not an unreadable answer, but nothing at all. Check this profile's Repetition Penalty (values near 1.05 are typical; high values over a small repetition-context window can suppress the model's first token) and Temperature. If those look right, the model's chat template or its tool-call format may not be producing a usable turn."
            return .abort(reason: reason)
        }

        // `.networkRetry`, not `.parseRetry`: it re-runs the iteration without a corrective alert in the model's
        // context, as `modelSlotAction` does. Zero delay: the next attempt just needs a fresh sample.
        logger.warning("[GEN_EMPTY] \(generator) returned no output (\(attempt)/\(cap)) — retrying with the same message array. CONSEQUENCE: only sampling can change the result — prompts now render byte-identically (swift-jinja 2.5.1 + SWIFT_DETERMINISTIC_HASHING), so at low temperature an identical retry can reproduce the same output (a discarded MLX tool call no longer reaches here: it is reported as a parse failure instead). Also: no corrective alert enters the model's context (there is no output to correct, and the parse-failure alert would be a false statement that also grows the prompt every attempt), and the parse budget is untouched.")
        return .networkRetry(
            message: "The model returned nothing — retrying (\(attempt)/\(cap))...",
            delaySeconds: 0
        )
    }

    private mutating func modelSlotAction(expected: String, actual: String) -> RetryAction {
        consecutiveModelSlotFailures += 1

        // Locals only: a `mutating` func must not let `self` escape into a log autoclosure.
        // "<none>" means a concurrent load emptied the slot, not that a named model holds it; never show it as a model name.
        let holder = (actual == "<none>") ? "another local model load" : "'\(actual)'"
        let attempt = consecutiveModelSlotFailures
        let cap = Self.maxModelSlotRetries
        let delay = Self.modelSlotRetryDelay

        if attempt > cap {
            logger.error("[MLX-LOAD] Model-slot contention PERSISTED for '\(expected)' — \(holder) still holds the slot after \(cap) re-run(s). CONSEQUENCE: the run stops with a model-slot error card; it is NOT counted as a parse failure, so telemetry records .modelUnloaded instead of .parseExhausted and the reliability stats for '\(expected)' are not charged with a bad-output failure.")
            return .fatal(
                reason: "This run needs the local model '\(expected)', but \(holder) still held the model slot after a retry. Only one MLX model stays in memory at a time, so two local runs evict each other. Nothing was answered by the wrong model. Run them one at a time — or point both profiles at the same model — and try again.",
                category: .modelUnloaded
            )
        }

        logger.warning("[MLX-LOAD] Model-slot contention: expected '\(expected)', \(holder) is resident — MLXService refused rather than answering from the wrong model. Re-running the iteration in \(Int(delay))s (\(attempt)/\(cap)). CONSEQUENCE: no corrective alert enters the model's context, the parse budget is untouched, and this attempt is not charged against maxIterations.")
        return .networkRetry(
            message: "⏳ \(holder) is using the local model slot — reloading '\(expected)' and retrying in \(Int(delay))s (\(attempt)/\(cap))...",
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
