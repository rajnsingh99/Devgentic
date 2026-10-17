// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
//
//  ResiliencePolicy.swift
//  Devgentic
//
//  Phase A of the resilience architecture (audit #5): one provider-aware
//  vocabulary for retry/abort behavior, resolved ONCE per run at the
//  AgentConnect seam and carried on AgentInput. Three tiers:
//    - transport:  HTTP/network-level budgets (5xx, timeouts, 429) — fully
//      auto-derived from provider class; never user-configured in Phase A.
//    - cognitive:  malformed-model-output retries (parse failures).
//    - loop:       tool-execution circuit-breaker caps.
//
//  The legacy user-facing RetryPolicy (maxRetries + backoffStrategy) is shimmed
//  into the cognitive/loop tiers for exact behavior compatibility; Phase B
//  replaces it with persisted per-tier overrides (nil = the defaults below).
//  ProviderErrorClassifier is deliberately stateless so the bot flow (audit #9)
//  can reuse it without the agent loop's counters.
//

import Foundation

// MARK: - Provider Class

/// Coarse provider classification driving transport-tier defaults. Cloud APIs
/// deserve bounded patience (outages are transient, Retry-After is authoritative);
/// Ollama failures are usually local-config problems (server not running), with
/// slow cold loads as the one legitimate transient; MLX is in-process — there is
/// no transport to retry, and model-unload has its own dedicated reload path.
enum ProviderClass: Sendable, Equatable {
    case cloud
    case ollama
    case mlx

    init(apiProvider: ApiProvider) {
        switch apiProvider {
        case .anthropic, .openAI, .google, .openRouter, .openAICompatible: self = .cloud
        case .ollama: self = .ollama
        case .mlx: self = .mlx
        }
    }
}

// MARK: - Policy Tiers

struct TransportResiliencePolicy: Sendable, Equatable {
    /// The class this policy was derived for — drives message wording (billing
    /// guidance is nonsense for a local server; "reload the model" is the right
    /// remedy for MLX) in addition to the numeric budgets below.
    let providerClass: ProviderClass
    /// Retries for transient failures (5xx incl. 529 overloaded, network timeouts,
    /// connection drops when not fatal) before giving up. 0 = fail on first.
    let maxTransientRetries: Int
    /// Retries for HTTP 429 throttles before giving up (persistent 429 usually
    /// means an exhausted quota, not a momentary burst).
    let maxThrottleRetries: Int
    /// First transient-retry delay; doubles per attempt up to `maxBackoff`.
    let baseBackoff: TimeInterval
    /// Ceiling for transient backoff and the 429 no-header fallback. A server
    /// Retry-After header is authoritative and NOT capped by this.
    let maxBackoff: TimeInterval
    /// Whether connection-refused means "server not running" (Ollama → fatal with
    /// guidance) rather than a transient blip (cloud — laptop offline, VPN flap).
    let connectionRefusedIsFatal: Bool
    /// User-facing endpoint shown in unreachable-server messages.
    let endpointHint: String?
    /// Legacy 429 fallback shape when the provider sends no Retry-After header.
    let backoffStrategy: BackoffStrategy

    /// Exponential transient delay: base, base*2, base*4, … capped at maxBackoff.
    func transientDelay(attempt: Int) -> TimeInterval {
        guard attempt > 1 else { return baseBackoff }
        return min(baseBackoff * pow(2.0, Double(attempt - 1)), maxBackoff)
    }
}

struct CognitiveResiliencePolicy: Sendable, Equatable {
    /// Consecutive malformed-output failures before aborting the run.
    let maxParseFailures: Int
}

struct LoopResiliencePolicy: Sendable, Equatable {
    let maxConsecutiveToolFailures: Int
    let maxRepetitiveActions: Int
    /// Consecutive user-denied tool calls before the run stops. (Clarification loops are
    /// governed by RunInteractionMemory replay + the repetition cap, not a counter.)
    let maxConsecutiveDenials: Int
}

// MARK: - Resolved Policy

/// The single resilience vocabulary consumed by executors. Runtime-only — never
/// persisted. Construct via `resolved(for:legacy:endpointHint:)`; components are
/// built from the tiers (CognitiveCircuitBreaker ← loop, LLMRetryStrategy ←
/// transport + cognitive), so no single knob can silently drive unrelated caps.
struct ResolvedResiliencePolicy: Sendable, Equatable {
    let transport: TransportResiliencePolicy
    let cognitive: CognitiveResiliencePolicy
    let loop: LoopResiliencePolicy

    /// The denial cap's fallback. Unlike the parse/tool/repetition caps it is NOT coupled to the
    /// legacy `RetryPolicy.maxRetries`, so it is a genuine constant — and the UI can safely state it.
    static let defaultMaxConsecutiveDenials = 2

    /// What `Auto` resolves to for the three caps that DO fall back to the legacy single knob.
    ///
    /// ⚠️ Register A70. The Advanced panel hardcoded `Auto (3)` for these, but the fallback is the
    /// profile's own `retryPolicy.maxRetries` — `3` only for a profile that never set one. A
    /// migrated profile carrying `maxRetries: 5` was told its cap was 3 while the run used 5. The
    /// label must be computed from the same value the resolver reads, which is what this exposes.
    static func autoDefault(legacy: RetryPolicy?) -> Int {
        (legacy ?? RetryPolicy()).maxRetries
    }

    /// Single resolution point. Per-tier precedence (Phase B):
    ///   explicit user `overrides` field → legacy `RetryPolicy.maxRetries` → provider default.
    /// Keeping `legacy.maxRetries` as the middle fallback means profiles saved before
    /// per-tier overrides existed behave exactly as before (their single knob still
    /// drives all three caps), while a profile that sets one override decouples only
    /// that cap. The transport tier is provider-class-derived and not user-overridable.
    static func resolved(
        for providerClass: ProviderClass,
        overrides: ResilienceOverrides? = nil,
        legacy: RetryPolicy = RetryPolicy(),
        endpointHint: String? = nil
    ) -> ResolvedResiliencePolicy {
        let transport: TransportResiliencePolicy
        switch providerClass {
        case .cloud:
            transport = TransportResiliencePolicy(
                providerClass: .cloud,
                maxTransientRetries: 3,
                maxThrottleRetries: 5,
                baseBackoff: 1.0,
                maxBackoff: 64.0,
                connectionRefusedIsFatal: false,
                endpointHint: endpointHint,
                backoffStrategy: legacy.backoffStrategy
            )
        case .ollama:
            transport = TransportResiliencePolicy(
                providerClass: .ollama,
                maxTransientRetries: 2,
                maxThrottleRetries: 2,
                baseBackoff: 1.0,
                maxBackoff: 8.0,
                connectionRefusedIsFatal: true,
                endpointHint: endpointHint ?? "http://localhost:11434",
                backoffStrategy: legacy.backoffStrategy
            )
        case .mlx:
            // In-process: no transport. Model-unload routes to the dedicated
            // `.modelReload` path in LLMRetryStrategy, not transient retries.
            transport = TransportResiliencePolicy(
                providerClass: .mlx,
                maxTransientRetries: 0,
                maxThrottleRetries: 0,
                baseBackoff: 0,
                maxBackoff: 0,
                connectionRefusedIsFatal: true,
                endpointHint: nil,
                backoffStrategy: legacy.backoffStrategy
            )
        }

        return ResolvedResiliencePolicy(
            transport: transport,
            cognitive: CognitiveResiliencePolicy(
                maxParseFailures: overrides?.maxParseFailures ?? legacy.maxRetries
            ),
            loop: LoopResiliencePolicy(
                maxConsecutiveToolFailures: overrides?.maxConsecutiveToolFailures ?? legacy.maxRetries,
                maxRepetitiveActions: overrides?.maxRepetitiveActions ?? legacy.maxRetries,
                // Never coupled to the legacy single knob — fixed default (the breaker's
                // historical hardcoded value). Named rather than inlined so the "Auto (N)" label
                // in `LoopSafetySection` reads the same constant instead of restating it (A70).
                maxConsecutiveDenials: overrides?.maxConsecutiveDenials ?? Self.defaultMaxConsecutiveDenials
            )
        )
    }
}

// MARK: - Stateless HTTP Error Classification

/// Verdict for a single provider HTTP error. Stateless — `LLMRetryStrategy`
/// applies retry budgets and backoff around these verdicts; the bot flow can
/// reuse the classifier without the agent loop's counters.
enum ProviderErrorVerdict: Equatable, Sendable {
    /// HTTP 429 — wait (Retry-After when present) and retry, budget permitting.
    case throttle(retryAfter: TimeInterval?)
    /// 5xx / overloaded — retry with backoff, budget permitting.
    case transient(detail: String)
    /// Deterministic failure — retrying the identical request cannot succeed.
    /// Carries the honest user-facing reason and telemetry category.
    case fatal(reason: String, category: AgentErrorCategory)
}

enum ProviderErrorClassifier {

    /// Conservative provider signatures for context-window overflow inside 400
    /// bodies (Anthropic "prompt is too long", OpenAI "context_length_exceeded",
    /// Gemini token-count INVALID_ARGUMENT). Unmatched 400s stay a generic
    /// fatal — still honest and bounded, never routed back to parse-retry.
    static let contextOverflowSignatures: [String] = [
        "context_length_exceeded",
        "prompt is too long",
        "maximum context length",
        "too many tokens",
        "input token count",
    ]

    /// Rejection markers that, combined with a tools/function-calling mention,
    /// indicate the model or endpoint does not support tool calling AT ALL —
    /// distinct from tool-ARGUMENT validation 400s ("tools[0].function.name is
    /// invalid"), which mean tools ARE supported and fall through to the generic
    /// verdict. Real-world sources: OpenAI-compatible gateways ("Unrecognized
    /// request argument supplied: tools"), Ollama's OpenAI shim ("does not
    /// support tools"), llama.cpp ("tools param requires --jinja"), LM Studio /
    /// vLLM ("not supported"), Gemini ("Function calling is not enabled"),
    /// Anthropic pydantic-style ("tools: Extra inputs are not permitted").
    static let toolsRejectionMarkers: [String] = [
        "does not support",
        "not supported",
        "unsupported",
        "not enabled",
        "unrecognized request argument",
        "unknown parameter",
        "extra inputs are not permitted",
        "requires --jinja",
    ]

    /// True when a 4xx body indicates the endpoint/model rejected tool calling
    /// wholesale (chat-only model), not a malformed tool definition. Requires
    /// BOTH a tools/function mention AND a rejection marker so tool-argument
    /// validation errors keep their generic (accurate) verdict.
    static func indicatesToolsUnsupported(_ loweredBody: String) -> Bool {
        let mentionsTools = loweredBody.contains("tool")
            || loweredBody.contains("function call")
            || loweredBody.contains("function_call")
        guard mentionsTools else { return false }
        return toolsRejectionMarkers.contains(where: { loweredBody.contains($0) })
    }

    static func classify(_ error: CloudProviderError) -> ProviderErrorVerdict {
        classify(
            statusCode: error.statusCode,
            rawBody: error.rawBody,
            retryAfter: error.retryAfterSeconds,
            requestId: error.requestId
        )
    }

    /// Status+body overload so non-pipeline HTTP errors classify identically —
    /// Ollama throws `LLMProviderError.httpError(status, body)` rather than
    /// `CloudProviderError`, and without this its 404s (model not pulled) and
    /// 500s (runner crash) fell through to the parse-failure path.
    static func classify(
        statusCode: Int,
        rawBody: String,
        retryAfter: TimeInterval? = nil,
        requestId: String? = nil
    ) -> ProviderErrorVerdict {
        let requestRef = requestId.map { " (request-id: \($0))" } ?? ""
        let lowered = rawBody.lowercased()

        switch statusCode {
        case 429:
            // OpenRouter's DAILY free-model cap is a 429 too, but it resets at midnight UTC —
            // backing off and retrying five times cannot succeed and only delays the answer.
            // The per-minute cap ("free-models-per-min") stays an ordinary throttle.
            if lowered.contains("free-models-per-day") {
                return .fatal(
                    reason: "You've reached OpenRouter's daily limit for free models (HTTP 429). It resets at midnight UTC; adding credits to your OpenRouter account raises it, or switch to a paid model.\(requestRef)",
                    category: .providerQuotaExhausted
                )
            }
            return .throttle(retryAfter: retryAfter)

        case 408, 500...599:
            // 408 request-timeout is the one 4xx that is genuinely transient.
            return .transient(detail: "HTTP \(statusCode)")

        case 402:
            // OpenRouter (and some gateways) signal an out-of-credits account with
            // 402 rather than 429 — deterministic until the user tops up, so fatal.
            return .fatal(
                reason: "The provider account is out of credits (HTTP 402). Add credits (OpenRouter: https://openrouter.ai/credits) and try again.\(requestRef)",
                category: .providerQuotaExhausted
            )

        case 401, 403:
            return .fatal(
                reason: "Authentication failed (HTTP \(statusCode)) — the provider rejected the API key. Check the key in this profile's settings.\(requestRef)",
                category: .providerAuth
            )

        case 404:
            // OpenRouter answers 404 when the model exists but no upstream can serve THIS request.
            // "Check the model name" is the wrong remedy for both — say what actually excluded it.
            if lowered.contains("data policy") {
                return .fatal(
                    reason: LLMProviderError.formatHTTPError(status: statusCode, body: rawBody) + requestRef,
                    category: .providerCapabilityMissing
                )
            }
            if lowered.contains("no endpoints found") && lowered.contains("tool") {
                return .fatal(
                    reason: "No provider for this model supports tool calling (HTTP 404). Choose a tool-capable model for this Agent profile, or use a Bot profile for plain chat.\(requestRef)",
                    category: .providerCapabilityMissing
                )
            }
            return .fatal(
                reason: "The provider couldn't find the requested model or endpoint (HTTP 404). Check the model name in this profile.\(requestRef)",
                category: .providerModelNotFound
            )

        default:
            // OpenRouter rejects a slug that is not (or is no longer) in its catalog with a 400 —
            // the usual fate of a `:free` variant that was withdrawn after the profile saved it.
            if statusCode == 400, lowered.contains("not a valid model id") {
                return .fatal(
                    reason: "The provider no longer offers this model (HTTP 400) — it may have been withdrawn. Pick another model in this profile.\(requestRef)",
                    category: .providerModelNotFound
                )
            }
            // "maximum context length" also appears in max_tokens-config 400s
            // ("max_tokens is too large: ... maximum context length is N") where
            // "start a new chat" is the wrong remedy — those fall through to the
            // generic verdict whose body snippet names the real knob.
            if statusCode == 400,
               !lowered.contains("max_tokens"),
               contextOverflowSignatures.contains(where: { lowered.contains($0) }) {
                return .fatal(
                    reason: "The conversation no longer fits the model's context window. Start a new chat, or enable history compaction, then try again.\(requestRef)",
                    category: .providerCapabilityMissing
                )
            }
            // Tools-rejection (register #1 runtime guard): the endpoint refused
            // the `tools` payload — a chat-only model/gateway driven through the
            // Agent loop. Cloud has no pre-flight capability guard (capability
            // is never populated for cloud configs), so this classification is
            // where the user learns the real cause instead of an opaque
            // bad-request.
            if statusCode == 400 || statusCode == 422,
               indicatesToolsUnsupported(lowered) {
                return .fatal(
                    reason: "This model or endpoint rejected tool definitions (HTTP \(statusCode)) — it doesn't support tool calling. Choose a tool-capable model for this Agent profile, or use a Bot profile for plain chat.\(requestRef)",
                    category: .providerCapabilityMissing
                )
            }
            return .fatal(
                reason: "The provider rejected the request (HTTP \(statusCode)): \(bodySnippet(rawBody))\(requestRef)",
                category: .providerBadRequest
            )
        }
    }

    /// Maps ANY thrown error to a transport verdict when it is a recognized
    /// transport-level failure: a structured `CloudProviderError`, Ollama's
    /// `LLMProviderError.httpError`, or any `URLError`. Returns `nil` for errors
    /// that are NOT transport-level — the agent path then falls through to its
    /// parse-failure handling, and the bot path surfaces them unchanged.
    ///
    /// Shared by `LLMRetryStrategy` (agent loop) and `TransportRetrier` (bot flow)
    /// so both classify byte-identically — there is one transport vocabulary.
    static func classifyTransport(
        _ error: Error,
        connectionRefusedIsFatal: Bool,
        endpointHint: String?
    ) -> ProviderErrorVerdict? {
        if let cloudError = error as? CloudProviderError {
            return classify(cloudError)
        }
        if let providerError = error as? LLMProviderError,
           case .httpError(let status, let body) = providerError {
            return classify(statusCode: status, rawBody: body)
        }
        // ⚠️ A refusal is the same answer every time for the same request — retrying spends the
        // budget and the user's money to be refused again (CR-16).
        if let providerError = error as? LLMProviderError, case .refused = providerError {
            return .fatal(reason: providerError.localizedDescription, category: .providerBadRequest)
        }
        // A stream cut off upstream (CR-26) is a transport failure: the same request normally completes.
        if let providerError = error as? LLMProviderError, case .streamEndedEarly = providerError {
            return .transient(detail: "the response stream ended before the model finished")
        }
        if let urlError = error as? URLError {
            switch urlError.code {
            case .timedOut:
                return .transient(detail: ProviderErrorClassifier.timeoutDetail)

            case .cannotConnectToHost, .networkConnectionLost, .cannotFindHost, .dnsLookupFailed:
                // Local servers: connection-refused means "not running" — an
                // actionable config problem. Cloud: the user's own network may be
                // flapping; treat as transient.
                if connectionRefusedIsFatal {
                    let hint = endpointHint.map { " at \($0)" } ?? ""
                    return .fatal(
                        reason: "Couldn't reach the model server\(hint) — is it running?",
                        category: .providerUnreachable
                    )
                }
                return .transient(detail: "connection failed")

            case .notConnectedToInternet, .dataNotAllowed:
                return .transient(detail: "no internet connection")

            default:
                // Every URLError is transport-level; none can legitimately mean the
                // model produced unparseable output, so we never return nil for one.
                return .transient(detail: "network error (code \(urlError.code.rawValue))")
            }
        }
        return nil
    }

    /// Retry-After sanitization shared by both retry paths. Header values flow into
    /// `Task.sleep`'s trapping `UInt64` conversion, and real-world proxies send "-1",
    /// past dates, even "inf". Anything non-finite, negative, or absurd is dropped
    /// (caller falls back to local backoff); sane values are honored up to an hour.
    /// The transient detail for a request that timed out — ONE spelling, so the fatal path can file
    /// an exhausted timeout as `.providerTimeout` (it was `.providerServerError`, "Provider 5xx";
    /// `providerTimeout` had no producer — Timeout inventory D-16) without matching free text.
    static let timeoutDetail = "request timed out"

    /// The category for a transient failure that exhausted its retries.
    static func exhaustedCategory(forDetail detail: String) -> AgentErrorCategory {
        detail == timeoutDetail ? .providerTimeout : .providerServerError
    }

    static func sanitizedRetryAfter(_ value: TimeInterval?) -> TimeInterval? {
        guard let value, value.isFinite, value >= 0 else { return nil }
        return min(value, 3600)
    }

    /// Single-line, length-capped body excerpt for user-facing messages.
    static func bodySnippet(_ body: String, max: Int = 200) -> String {
        let condensed = body
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !condensed.isEmpty else { return "no error detail provided" }
        return condensed.count > max ? String(condensed.prefix(max)) + "…" : condensed
    }
}
