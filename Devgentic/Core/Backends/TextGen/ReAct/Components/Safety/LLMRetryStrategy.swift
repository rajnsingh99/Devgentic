// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
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

    /// The tool-call wire format this run's generator asks for, or nil on a transport-native flow.
    ///
    /// ⚠️ Exists ONLY to make the parse-failure corrective honest. It used to be absent, and the
    /// single corrective string that resulted prescribed the `.nativeJSON` shape to every model:
    /// "You MUST output a valid JSON response containing `reasoning` and `toolCalls`. No prose or
    /// markdown fences (```json)." For 16 of the 18 dialects that is the wrong format, and for
    /// `.deepseekV3JsonFence` and `.commandRAction` the fence prohibition is the exact inverse of
    /// their requirement — both formats put the arguments INSIDE a ```json fence. A model that
    /// complied with the alert produced output its own parser then rejected, so three compliant
    /// retries spent the parse budget and aborted the run.
    ///
    /// Resolved once per run, because the dialect is: `AgentConnect.resolveCognitiveGenerator`
    /// picks the generator at run start and it does not change across iterations.
    private let dialect: ModelDialect?

    private(set) var consecutiveRetries = 0            // 429 throttles
    private(set) var consecutiveParseFailures = 0
    private(set) var consecutiveTransientFailures = 0  // 5xx + timeouts + connection drops

    /// Consecutive MLX model-slot races (`MLXService.ServiceError.modelIdentityMismatch`).
    ///
    /// ⚠️ Its own budget on purpose. This is neither a transport failure — the MLX transport
    /// budget is `maxTransientRetries: 0` BY DESIGN (ResiliencePolicy.swift:150-162, "In-process:
    /// no transport"), so `transientAction` would fail on the FIRST hit and diagnose it as
    /// "try reloading the model or switching to a smaller one", a memory verdict for a
    /// concurrency fault — nor a parse failure, since the model produced nothing to parse.
    private(set) var consecutiveModelSlotFailures = 0

    /// Consecutive generations that returned NO output (`GenerationError.emptyResponse`).
    ///
    /// ⚠️ Its own budget, for the same reason `consecutiveModelSlotFailures` has one: the model
    /// produced nothing to parse, so charging the parse budget both aborts on the wrong cap and
    /// mislabels the run in telemetry.
    private(set) var consecutiveEmptyResponses = 0

    /// How many empty generations in a row before giving up.
    ///
    /// Lower than the parse cap on purpose. A parse failure can be argued out of the model with a
    /// corrective nudge, so more attempts genuinely help; an empty response gets the identical
    /// prompt back and only a different sample can change the outcome. If three fresh samples all
    /// return nothing, the cause is configuration, not luck, and more attempts only delay the
    /// diagnosis the abort message carries.
    private static let maxConsecutiveEmptyResponses = 3

    /// ONE outer retry. `MLXService.container(expecting:)` already re-loads the expected model
    /// TWICE back-to-back before it throws (MLXService.swift:120-129), and `loadModel` coalesces
    /// behind any in-flight load (:210-212) — so the only thing an outer attempt adds is ELAPSED
    /// TIME for a competitor to release the slot. One wait covers the short competitor (the
    /// workflow AI Classifier loads, generates once, then unloads). A second would re-read
    /// multi-GB weights against contention that has already proven sustained.
    private static let maxModelSlotRetries = 1

    /// Wait before the single re-run: long enough for a one-shot classifier to release the slot,
    /// short enough that a genuinely stuck slot fails fast.
    /// ⚠️ Judgement, not a measurement — nothing on device has timed a classifier's
    /// load → generate → unload cycle. Measure one before treating this as tuned.
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

        // --- Empty output: NOT a parse failure ---
        //
        // ⚠️ Placement matters for the same reason the MLX block below documents: every arm here
        // returns, so control never reaches `consecutiveParseFailures += 1`.
        //
        // Six generators used to throw an untyped `NSError(domain: <their own string>, code: 422)`
        // for this, so nothing could match them and all six landed in the UNCLASSIFIED catch-all —
        // which injects "Your last output failed validation … you MUST output valid JSON" into the
        // model's context. For a model that emitted NOTHING that text is false, it grows the prompt
        // by ~205 chars on every attempt, and it instructs the model to stop doing something it
        // never did. A device log showed five of these in a row aborting a run on the parse cap.
        if case GenerationError.emptyResponse(let generator) = error {
            return emptyResponseAction(generator: generator)
        }

        // --- Typed local-runtime errors (MUST precede the string tests below) ---
        // Matched BY TYPE. The prose test this replaces classified `.noModelLoaded` only because
        // its `errorDescription` happened to contain the literal being grepped for, and left its
        // sibling `.modelIdentityMismatch` — the MLX model-slot race — falling through to the
        // parse-failure catch-all, telling the user their prompt was malformed when the model had
        // produced no output at all (WF-CC6).
        //
        // ⚠️ Placement is load-bearing, not cosmetic: every arm here returns, so control can never
        // reach `consecutiveParseFailures += 1` below. Moving this block under the catch-all would
        // keep the verdict correct while still charging the parse budget — after which three races
        // abort the run with "please try rephrasing your request", the very lie this fixes.
        //
        // ⚠️ No `default:` on purpose: a new `ServiceError` case must BREAK THIS BUILD rather than
        // silently inherit the parse-failure verdict. That compiler check is the actual fix; the
        // missing branch was only the symptom.
        if let mlxError = error as? MLXService.ServiceError {
            switch mlxError {
            case .noModelLoaded:
                // ⚠️ Unreachable in production today: both `MLXLLMProvider` construction sites pin
                // a non-nil `modelDirectory` (AgentConnect.swift:1256, WorkflowExecutor.swift:2997),
                // so `container(expecting:)` never takes the nil-identity path that throws this.
                // Kept — and routed by TYPE — so the exhaustive switch stays honest if that changes.
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

        // Ollama's local-model-unloaded string.
        //
        // ⚠️ The MLX half of this test was DELETED 2026-08-16 (WF-CC6) and is now the typed
        // `MLXService.ServiceError` switch above. It is NOT kept as belt-and-braces, deliberately:
        // it could not catch anything the type test misses (one throw site, unwrapped all the way
        // to here), but it COULD catch something it shouldn't — any future error whose prose
        // happens to contain the substring, which is WF-CC6 again in the opposite direction. Two
        // rules for one condition means neither is load-bearing.
        //
        // ⚠️ This remaining Ollama branch has NO PRODUCER in this repo (grep 2026-08-16: this line
        // and its test only); Ollama's real model-missing error is an `LLMProviderError.httpError`
        // 404 already classified by `classifyTransport` above. Left in place only so its removal
        // is a separate, separately-testable change.
        if errorDesc.contains("No Ollama model") {
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
        let errorType = String(describing: type(of: error))
        // Named in the log because the corrective's CONTENT now depends on it: reading a field
        // log, "which format were we telling the model to emit" is otherwise unanswerable, and
        // `native` vs a dialect name is the difference between two entirely different alerts.
        let dialectLabel = dialect?.rawValue ?? "native (no text dialect)"

        // ⚠️ The TYPE and the word UNCLASSIFIED are the point (WF-CC6). The previous line named
        // the event but not its consequence and never revealed that the error was unrecognised —
        // so an MLX model-slot race read in the logs exactly like a model emitting bad JSON, and
        // the misclassification was invisible from a field bundle. If this line names a type that
        // is plainly not a model-output fault, that type needs a typed arm above.
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

    /// Builds the corrective injected into the model's own context before the retry.
    ///
    /// ⚠️ `static` and pure so the text is testable without constructing a run, and so a
    /// `mutating` caller cannot let `self` escape into it.
    ///
    /// Two shapes, because there are two honest things to say:
    ///
    ///   - **A known dialect** — name that dialect's format and nothing else. The one thing this
    ///     must never do again is prescribe a format the run's own parser would reject; that is
    ///     why the shape comes from `ModelDialect.formatReminder` (exhaustive, compiler-checked)
    ///     rather than a literal here.
    ///   - **No dialect (transport-native flow)** — say nothing about format at all. On
    ///     Claude/OpenAI/Gemini/Ollama-native the tool call rides in the protocol, not in the
    ///     text, so there is no format the model could emit differently; a format instruction
    ///     would be noise the model cannot act on. Nil also covers "dialect unknown", where
    ///     silence is the only honest option.
    ///
    /// Both name `final_answer`, matching `ParseFailureReason.modelCorrectiveAlert` — a model
    /// that has finished but cannot express it in the expected shape needs the exit, not a
    /// reformatting lesson.
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
            return .fatal(reason: reason, category: ProviderErrorClassifier.exhaustedCategory(forDetail: detail))
        }

        let delay = transport.transientDelay(attempt: consecutiveTransientFailures)
        logger.warning("Transient failure (\(detail)). request-id: \(requestId ?? "n/a"). Retrying in \(Int(delay))s (\(consecutiveTransientFailures)/\(transport.maxTransientRetries)).")
        return .networkRetry(
            message: "⏳ \(detail) — retrying in \(Int(delay))s (\(consecutiveTransientFailures)/\(transport.maxTransientRetries))...",
            delaySeconds: delay
        )
    }

    /// Model-slot contention on the single global MLX container: another run loaded a different
    /// model and `MLXService` refused to answer from the wrong one (WF-CC6).
    ///
    /// ⚠️ Deliberately NOT `.modelReload`, which is the intuitive answer and hangs the run.
    /// `reloadCurrentModel()` returns `true` immediately when a container is resident
    /// (MLXService.swift:369-370) — and resident-but-wrong IS this state — so it would repair
    /// nothing while reporting success; and the executor's `.modelReload` arm rewinds
    /// `currentIteration` with no counter of its own, so the loop would spin unbounded at zero
    /// cost, yielding a warning chip on every pass (WF-CC8).
    ///
    /// ⚠️ Also NOT `transientAction`: the MLX transport budget is 0, so it would fail on the first
    /// hit and blame model size for a concurrency fault. See `consecutiveModelSlotFailures`.
    ///
    /// One bounded retry strictly dominates the pre-fix behaviour: today's defect ACCIDENTALLY
    /// retries three times (`.parseRetry` re-enters the loop and `container(expecting:)` re-attempts
    /// the load each pass), so a short race usually self-heals — at the cost of a false
    /// "your last output failed validation" alert pinned in the model's own context and a burned
    /// iteration. Bare `.fatal` would remove that recovery and produce MORE hard failures than
    /// before; this keeps the recovery and drops the lie.
    /// The provider returned successfully but produced no text and no tool call.
    ///
    /// ⚠️ ITS OWN BUDGET, and NO system alert — the two things that distinguish it from a parse
    /// failure. There is no output to correct, so there is no honest corrective instruction to
    /// give; the retry re-sends the SAME prompt and relies on sampling non-determinism, which is
    /// what actually recovers it (a device log showed the identical prompt yielding a clean tool
    /// call on one run and immediate EOS on the next, 7 tokens apart).
    ///
    /// Same shape and same reasoning as `modelSlotAction` below, whose own comment already draws
    /// the distinction: not a parse failure "since the model produced nothing to parse".
    private mutating func emptyResponseAction(generator: String) -> RetryAction {
        consecutiveEmptyResponses += 1

        // Locals only — a `mutating` func must not let `self` escape into a log autoclosure.
        let attempt = consecutiveEmptyResponses
        let cap = Self.maxConsecutiveEmptyResponses

        if attempt >= cap {
            logger.error("[GEN_EMPTY] \(generator) returned NO output \(attempt) time(s) in a row — giving up. CONSEQUENCE: the run stops. This is NOT charged to the parse budget and telemetry does not record .parseExhausted, because the model produced nothing to parse — the cause is upstream of the parser. Read the [MLX-GEN] line for this attempt BEFORE changing anything: it reports the framework's own generatedTokens, which says whether the model emitted nothing (sampling / chat template) or emitted output that was discarded downstream (tool-call parsing). Those two have opposite fixes.")
            return .abort(
                reason: "The model returned no output \(attempt) times in a row — not an unreadable answer, but nothing at all. Check this profile's Repetition Penalty (values near 1.05 are typical; high values over a small repetition-context window can suppress the model's first token) and Temperature. If those look right, the model's chat template or its tool-call format may not be producing a usable turn."
            )
        }

        // ⚠️ `.networkRetry` deliberately, NOT `.parseRetry` — it re-runs the iteration WITHOUT
        // putting a corrective alert into the model's context. `modelSlotAction` uses the same
        // case for the same reason. Zero delay: nothing external needs time to settle, the next
        // attempt just needs a fresh sample.
        logger.warning("[GEN_EMPTY] \(generator) returned no output (\(attempt)/\(cap)) — retrying with the same message array (tool-schema key order may differ between renders; see BridgedToolsStore). CONSEQUENCE: no corrective alert enters the model's context (there is no output to correct, and the parse-failure alert would be a false statement that also grows the prompt every attempt), and the parse budget is untouched.")
        return .networkRetry(
            message: "The model returned nothing — retrying (\(attempt)/\(cap))...",
            delaySeconds: 0
        )
    }

    private mutating func modelSlotAction(expected: String, actual: String) -> RetryAction {
        consecutiveModelSlotFailures += 1

        // Locals only — a `mutating` func must not let `self` escape into a log autoclosure.
        // "<none>" means the slot was EMPTIED by a concurrent load (MLXService.swift:135), not that
        // a named model is squatting — never render it to the user as a model name.
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
