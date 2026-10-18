// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
//
//  LLMRetryStrategyTests.swift
//  DevgenticTests
//
//  Created by Raj Singh.
//

import XCTest
@testable import devgentic

final class LLMRetryStrategyTests: XCTestCase {

    // MARK: - Helpers

    /// Creates a generic NSError that does NOT match 429, timeout, or model-unloaded patterns.
    /// This falls through to the parse failure path.
    private func makeGenericError(_ message: String = "Invalid JSON") -> NSError {
        NSError(domain: "TestDomain", code: 1000, userInfo: [NSLocalizedDescriptionKey: message])
    }

    /// Creates a CloudProviderError with the given status code.
    private func makeCloudError(
        statusCode: Int,
        retryAfterSeconds: TimeInterval? = nil,
        requestId: String? = "req-123",
        rawBody: String = "Error body"
    ) -> CloudProviderError {
        CloudProviderError(
            statusCode: statusCode,
            retryAfterSeconds: retryAfterSeconds,
            requestId: requestId,
            rawBody: rawBody,
            provider: .anthropic
        )
    }

    private var cloudTransport: TransportResiliencePolicy {
        ResolvedResiliencePolicy.resolved(for: .cloud).transport
    }

    private var ollamaTransport: TransportResiliencePolicy {
        ResolvedResiliencePolicy.resolved(for: .ollama).transport
    }

    // MARK: - WF-CC6 fixtures

    /// ⚠️ `maxTransientRetries` is 0 here BY DESIGN (ResiliencePolicy.swift:150-162) — which is why
    /// the model-slot race cannot be routed through `transientAction`.
    private var mlxTransport: TransportResiliencePolicy {
        ResolvedResiliencePolicy.resolved(for: .mlx).transport
    }

    private func makeIdentityMismatch(
        expected: String = "Phi-4-mini-instruct-4bit",
        actual: String = "Qwen3.5-9B-MLX-8bit"
    ) -> MLXService.ServiceError {
        .modelIdentityMismatch(expected: expected, actual: actual)
    }

    /// An UNRECOGNISED error, in the exact shape the generators used to throw for an empty
    /// response before `GenerationError.emptyResponse` existed.
    ///
    /// ⚠️ RENAMED AND REDOCUMENTED 2026-08-20. This was `makeEmptyResponseError`, documented as
    /// "the REAL parse-failure producer … not a hand-written string". That stopped being true the
    /// moment the six generators started throwing a typed error: no production code produces this
    /// NSError any more, so a test asserting "an empty response is a parse retry" through it was
    /// asserting a fiction while still passing.
    ///
    /// It is kept — under an honest name — because the negative control it serves is still
    /// valuable: an error the strategy does NOT recognise must still charge the parse budget,
    /// rather than every unknown error quietly acquiring a free retry.
    private func makeUnrecognisedError() -> NSError {
        NSError(domain: "SomeUnrecognisedDomain", code: 422,
                userInfo: [NSLocalizedDescriptionKey: "Something the strategy has no arm for."])
    }

    /// What the generators ACTUALLY throw for an empty response now.
    private func makeEmptyResponse() -> GenerationError {
        .emptyResponse(generator: "QwenHermes")
    }

    // MARK: - Parse Failure Counting (unchanged contract)

    func testParseFailure_IncrementedCorrectly() {
        var strategy = LLMRetryStrategy(maxConsecutiveParseFailures: 3)
        _ = strategy.handleError(makeGenericError())
        XCTAssertEqual(strategy.consecutiveParseFailures, 1)
    }

    func testParseFailure_AbortAtThreshold() {
        var strategy = LLMRetryStrategy(maxConsecutiveParseFailures: 3)
        _ = strategy.handleError(makeGenericError("fail 1"))
        _ = strategy.handleError(makeGenericError("fail 2"))
        let action = strategy.handleError(makeGenericError("fail 3"))

        if case .abort(let reason) = action {
            XCTAssertTrue(reason.contains("trouble processing"), "Abort reason should explain the issue")
        } else {
            XCTFail("Expected .abort on 3rd parse failure, got \(action)")
        }
    }

    func testParseFailure_RetryBelowThreshold() {
        var strategy = LLMRetryStrategy(maxConsecutiveParseFailures: 3)
        _ = strategy.handleError(makeGenericError("fail 1"))
        let action = strategy.handleError(makeGenericError("fail 2"))

        if case .parseRetry(_, let attemptCount, let maxAttempts) = action {
            XCTAssertEqual(attemptCount, 2)
            XCTAssertEqual(maxAttempts, 3)
        } else {
            XCTFail("Expected .parseRetry, got \(action)")
        }
    }

    func testParseFailure_SystemAlertContainsAttemptInfo() {
        var strategy = LLMRetryStrategy(maxConsecutiveParseFailures: 3)
        let action = strategy.handleError(makeGenericError())

        if case .parseRetry(let alert, let attempt, _) = action {
            XCTAssertEqual(attempt, 1)
            XCTAssertTrue(alert.contains("1/3"), "System alert should contain attempt count")
        } else {
            XCTFail("Expected .parseRetry, got \(action)")
        }
    }

    // MARK: - 429 Throttling (bounded)

    func testExponentialBackoff_HTTP429_ProducesIncreasingDelays() {
        var strategy = LLMRetryStrategy(maxConsecutiveParseFailures: 10, backoffStrategy: .exponential)
        var delays: [TimeInterval] = []

        for _ in 1...4 {
            let action = strategy.handleError(makeCloudError(statusCode: 429))
            if case .throttle(let seconds, _) = action {
                delays.append(seconds)
            }
        }

        XCTAssertEqual(delays.count, 4, "All 4 should produce throttle actions (budget is 5)")
        // Exponential: pow(2, 1)=2, pow(2, 2)=4, pow(2, 3)=8, pow(2, 4)=16
        XCTAssertEqual(delays[0], 2.0, accuracy: 0.01)
        XCTAssertEqual(delays[1], 4.0, accuracy: 0.01)
        XCTAssertEqual(delays[2], 8.0, accuracy: 0.01)
        XCTAssertEqual(delays[3], 16.0, accuracy: 0.01)
    }

    func testFixedBackoff_HTTP429_ProducesConstantDelays() {
        var strategy = LLMRetryStrategy(maxConsecutiveParseFailures: 10, backoffStrategy: .fixed)
        var delays: [TimeInterval] = []

        for _ in 1...3 {
            let action = strategy.handleError(makeCloudError(statusCode: 429))
            if case .throttle(let seconds, _) = action {
                delays.append(seconds)
            }
        }

        XCTAssertEqual(delays.count, 3)
        for delay in delays {
            XCTAssertEqual(delay, 2.0, accuracy: 0.01, "Fixed backoff should always be 2.0s")
        }
    }

    func testHTTP429_WithRetryAfterHeader_UsesProvidedValue() {
        var strategy = LLMRetryStrategy()
        let action = strategy.handleError(makeCloudError(statusCode: 429, retryAfterSeconds: 30))

        if case .throttle(let seconds, _) = action {
            XCTAssertEqual(seconds, 30.0, accuracy: 0.01, "Should use the Retry-After value from the error")
        } else {
            XCTFail("Expected .throttle, got \(action)")
        }
    }

    func testHTTP429_ExhaustedBudget_BecomesFatalRateLimit() {
        // Cloud budget is 5 throttle waits; the 6th consecutive 429 gives up
        // with an honest quota message instead of waiting forever.
        var strategy = LLMRetryStrategy()

        for _ in 1...5 {
            let action = strategy.handleError(makeCloudError(statusCode: 429))
            if case .throttle = action {} else {
                XCTFail("Expected .throttle within budget, got \(action)")
            }
        }

        let action = strategy.handleError(makeCloudError(statusCode: 429))
        if case .fatal(let reason, let category) = action {
            XCTAssertEqual(category, .providerQuotaExhausted, "Run-ending quota failures need a fatal-severity category")
            XCTAssertTrue(reason.contains("quota"), "Reason should point at quota, got: \(reason)")
        } else {
            XCTFail("Expected .fatal after exhausting throttle budget, got \(action)")
        }
    }

    func testHTTP429_NegativeOrAbsurdRetryAfter_FallsBackToLocalBackoff() {
        // Real-world proxies send "-1" / past dates / "inf" — these must not
        // reach Task.sleep's trapping UInt64 conversion.
        var strategy = LLMRetryStrategy(backoffStrategy: .fixed)

        let negative = strategy.handleError(makeCloudError(statusCode: 429, retryAfterSeconds: -1))
        if case .throttle(let seconds, _) = negative {
            XCTAssertEqual(seconds, 2.0, accuracy: 0.01, "Negative Retry-After must fall back to local backoff")
        } else {
            XCTFail("Expected .throttle, got \(negative)")
        }

        let infinite = strategy.handleError(makeCloudError(statusCode: 429, retryAfterSeconds: .infinity))
        if case .throttle(let seconds, _) = infinite {
            XCTAssertTrue(seconds.isFinite, "Non-finite Retry-After must be sanitized")
        } else {
            XCTFail("Expected .throttle, got \(infinite)")
        }

        let absurd = strategy.handleError(makeCloudError(statusCode: 429, retryAfterSeconds: 1_000_000_000))
        if case .throttle(let seconds, _) = absurd {
            XCTAssertLessThanOrEqual(seconds, 3600, "Sane ceiling of 1h on honored Retry-After")
        } else {
            XCTFail("Expected .throttle, got \(absurd)")
        }
    }

    // MARK: - Transient Errors (bounded with backoff)

    func testHTTP5xx_RetriesWithBackoffThenFatal() {
        // Cloud budget is 3 transient retries with exponential delays (1, 2, 4),
        // then an honest provider-unavailable fatal — never an infinite loop.
        var strategy = LLMRetryStrategy()
        var delays: [TimeInterval] = []

        for _ in 1...3 {
            let action = strategy.handleError(makeCloudError(statusCode: 503))
            if case .networkRetry(_, let delaySeconds) = action {
                delays.append(delaySeconds)
            } else {
                XCTFail("Expected .networkRetry within budget, got \(action)")
            }
        }
        XCTAssertEqual(delays, [1.0, 2.0, 4.0], "Transient backoff should escalate")

        let action = strategy.handleError(makeCloudError(statusCode: 503))
        if case .fatal(let reason, let category) = action {
            XCTAssertEqual(category, .providerServerError)
            XCTAssertTrue(reason.contains("unavailable"), "Reason should say the provider is unavailable, got: \(reason)")
        } else {
            XCTFail("Expected .fatal after exhausting transient budget, got \(action)")
        }
    }

    func testNetworkTimeout_URLError_CountsAsTransient() {
        var strategy = LLMRetryStrategy()
        let action = strategy.handleError(URLError(.timedOut))

        if case .networkRetry(let message, let delaySeconds) = action {
            XCTAssertGreaterThan(delaySeconds, 0, "Transient retries must back off, not hammer")
            XCTAssertTrue(message.contains("timed out"))
        } else {
            XCTFail("Expected .networkRetry for URLError.timedOut, got \(action)")
        }
        XCTAssertEqual(strategy.consecutiveTransientFailures, 1)
    }

    func testConnectionRefused_CloudTransport_IsTransient() {
        // Cloud: the user's own network may be flapping — retry, don't blame config.
        var strategy = LLMRetryStrategy(transport: cloudTransport)
        let action = strategy.handleError(URLError(.cannotConnectToHost))

        if case .networkRetry = action {} else {
            XCTFail("Expected .networkRetry for cloud connection failure, got \(action)")
        }
    }

    func testConnectionRefused_OllamaTransport_IsFatalWithGuidance() {
        // Ollama: connection-refused means the server isn't running — actionable
        // config problem, fail fast with the endpoint in the message.
        var strategy = LLMRetryStrategy(transport: ollamaTransport)
        let action = strategy.handleError(URLError(.cannotConnectToHost))

        if case .fatal(let reason, let category) = action {
            XCTAssertEqual(category, .providerUnreachable, "Server-not-running is not a timeout — needs its own fatal category")
            XCTAssertTrue(reason.contains("is it running"), "Should ask whether the server is running, got: \(reason)")
            XCTAssertTrue(reason.contains("localhost:11434"), "Should include the endpoint hint, got: \(reason)")
        } else {
            XCTFail("Expected .fatal for Ollama connection-refused, got \(action)")
        }
    }

    func testOfflineInternet_URLError_IsTransientNotParseFailure() {
        // The single most common cloud transport failure (laptop offline) must
        // never be presented as a model parse failure.
        var strategy = LLMRetryStrategy()
        let action = strategy.handleError(URLError(.notConnectedToInternet))

        if case .networkRetry(let message, _) = action {
            XCTAssertTrue(message.contains("internet"), "Should name the real cause, got: \(message)")
        } else {
            XCTFail("Expected .networkRetry for offline internet, got \(action)")
        }
        XCTAssertEqual(strategy.consecutiveParseFailures, 0)
    }

    func testUnlistedURLError_IsTransientNotParseFailure() {
        // ANY URLError is transport-level by definition — no code may fall
        // through to the parse path.
        var strategy = LLMRetryStrategy()
        let action = strategy.handleError(URLError(.secureConnectionFailed))

        if case .networkRetry = action {} else {
            XCTFail("Expected .networkRetry for unlisted URLError, got \(action)")
        }
        XCTAssertEqual(strategy.consecutiveParseFailures, 0)
    }

    // MARK: - Ollama httpError Routing (LLMProviderError, not CloudProviderError)

    func testOllamaHTTP404_ModelNotPulled_IsFatalModelNotFound() {
        var strategy = LLMRetryStrategy(transport: ollamaTransport)
        let action = strategy.handleError(
            LLMProviderError.httpError(404, #"{"error":"model 'llama9' not found, try pulling it first"}"#)
        )

        if case .fatal(_, let category) = action {
            XCTAssertEqual(category, .providerModelNotFound)
        } else {
            XCTFail("Expected .fatal(.providerModelNotFound) for Ollama 404, got \(action)")
        }
        XCTAssertEqual(strategy.consecutiveParseFailures, 0, "Ollama HTTP errors must not be treated as parse failures")
    }

    func testOllamaHTTP500_RunnerCrash_BoundedTransientThenFatal() {
        // Ollama budget is 2 transient retries.
        var strategy = LLMRetryStrategy(transport: ollamaTransport)
        let runnerCrash = LLMProviderError.httpError(500, #"{"error":"model runner has unexpectedly stopped"}"#)

        for _ in 1...2 {
            let action = strategy.handleError(runnerCrash)
            if case .networkRetry = action {} else {
                XCTFail("Expected .networkRetry within Ollama budget, got \(action)")
            }
        }

        let action = strategy.handleError(runnerCrash)
        if case .fatal(let reason, let category) = action {
            XCTAssertEqual(category, .providerServerError)
            XCTAssertTrue(reason.contains("model server"), "Ollama wording should say model server, got: \(reason)")
        } else {
            XCTFail("Expected .fatal after Ollama transient budget, got \(action)")
        }
        XCTAssertEqual(strategy.consecutiveParseFailures, 0)
    }

    func testOllamaHTTP429_QuotaFormattedBody_StillThrottles() {
        // formatHTTPError rewrites OpenAI-compat 429 bodies into text containing
        // neither "429" nor "rate limit" — classification must be status-driven,
        // not description-string-driven.
        var strategy = LLMRetryStrategy(transport: ollamaTransport)
        let action = strategy.handleError(
            LLMProviderError.httpError(429, #"{"error":{"message":"openai quota exceeded"}}"#)
        )

        if case .throttle = action {} else {
            XCTFail("Expected .throttle for httpError 429, got \(action)")
        }
        XCTAssertEqual(strategy.consecutiveParseFailures, 0)
    }

    func testMLXTimeout_FailsFastWithReloadGuidance() {
        // MLX transport budget is 0 — in-process failures fail fast with
        // MLX-appropriate wording, not "provider unavailable, try later".
        var strategy = LLMRetryStrategy(transport: ResolvedResiliencePolicy.resolved(for: .mlx).transport)
        let action = strategy.handleError(URLError(.timedOut))

        if case .fatal(let reason, _) = action {
            XCTAssertTrue(reason.contains("local model"), "MLX wording should say local model, got: \(reason)")
            XCTAssertTrue(reason.contains("reload"), "MLX remedy is reloading the model, got: \(reason)")
        } else {
            XCTFail("Expected immediate .fatal for MLX transient, got \(action)")
        }
    }

    // MARK: - Deterministic 4xx (typed fatal, never parse-retry)

    func testHTTP401_IsFatalAuth() {
        var strategy = LLMRetryStrategy()
        let action = strategy.handleError(makeCloudError(statusCode: 401))

        if case .fatal(let reason, let category) = action {
            XCTAssertEqual(category, .providerAuth)
            XCTAssertTrue(reason.contains("API key"), "Should point at the API key, got: \(reason)")
            XCTAssertTrue(reason.contains("req-123"), "Should carry the request-id for support")
        } else {
            XCTFail("Expected .fatal(.providerAuth) for 401, got \(action)")
        }
        XCTAssertEqual(strategy.consecutiveParseFailures, 0, "Provider errors must not touch the parse counter")
    }

    func testHTTP403_IsFatalAuth() {
        var strategy = LLMRetryStrategy()
        let action = strategy.handleError(makeCloudError(statusCode: 403))

        if case .fatal(_, let category) = action {
            XCTAssertEqual(category, .providerAuth)
        } else {
            XCTFail("Expected .fatal(.providerAuth) for 403, got \(action)")
        }
    }

    func testHTTP404_IsFatalModelNotFound() {
        var strategy = LLMRetryStrategy()
        let action = strategy.handleError(makeCloudError(statusCode: 404))

        if case .fatal(let reason, let category) = action {
            XCTAssertEqual(category, .providerModelNotFound)
            XCTAssertTrue(reason.contains("model"), "Should point at the model name, got: \(reason)")
        } else {
            XCTFail("Expected .fatal(.providerModelNotFound) for 404, got \(action)")
        }
    }

    func testHTTP400_ContextOverflow_IsFatalWithGuidance() {
        var strategy = LLMRetryStrategy()
        let action = strategy.handleError(makeCloudError(
            statusCode: 400,
            rawBody: #"{"type":"error","error":{"type":"invalid_request_error","message":"prompt is too long: 210000 tokens > 200000 maximum"}}"#
        ))

        if case .fatal(let reason, let category) = action {
            XCTAssertEqual(category, .providerCapabilityMissing)
            XCTAssertTrue(reason.contains("context window"), "Should explain the overflow, got: \(reason)")
            XCTAssertTrue(reason.contains("new chat") || reason.contains("compaction"), "Should suggest a remedy, got: \(reason)")
        } else {
            XCTFail("Expected context-overflow .fatal for 400 with overflow body, got \(action)")
        }
    }

    func testHTTP400_Generic_IsFatalBadRequest_WithBodySnippet() {
        var strategy = LLMRetryStrategy(maxConsecutiveParseFailures: 3)
        let action = strategy.handleError(makeCloudError(
            statusCode: 400,
            rawBody: #"{"error":{"message":"tools: unexpected field 'banana'"}}"#
        ))

        if case .fatal(let reason, let category) = action {
            XCTAssertEqual(category, .providerBadRequest)
            XCTAssertTrue(reason.contains("banana"), "Should include the body snippet for triage, got: \(reason)")
        } else {
            XCTFail("Expected .fatal(.providerBadRequest) for generic 400, got \(action)")
        }
        XCTAssertEqual(strategy.consecutiveParseFailures, 0, "4xx must never be treated as a model parse failure")
    }

    // MARK: - Model Unloaded (unchanged contract)

    // ⚠️ `testModelUnloaded_MLX_ReturnsModelReload` was DELETED 2026-08-16 (WF-CC6). It fabricated
    // a generic `NSError` carrying the string "No MLX model is currently loaded…" — prose no
    // production code path emits in that form — and so passed whether or not the TYPED routing
    // worked. That is precisely how WF-CC6 survived: the enum had tests, its ROUTING had none.
    // `testNoModelLoaded_TypedError_RoutesToModelReload` below replaces it and is prose-independent.

    func testModelUnloaded_Ollama_ReturnsModelReload() {
        var strategy = LLMRetryStrategy()
        let error = makeGenericError("No Ollama model available for inference.")
        let action = strategy.handleError(error)

        if case .modelReload = action {} else {
            XCTFail("Expected .modelReload for Ollama unloaded, got \(action)")
        }
    }

    // MARK: - Reset

    func testResetParseFailures_ResetsAllCounters() {
        var strategy = LLMRetryStrategy()
        _ = strategy.handleError(makeCloudError(statusCode: 429))
        _ = strategy.handleError(makeCloudError(statusCode: 500))
        _ = strategy.handleError(makeGenericError())
        XCTAssertGreaterThan(strategy.consecutiveRetries, 0)
        XCTAssertGreaterThan(strategy.consecutiveTransientFailures, 0)
        XCTAssertGreaterThan(strategy.consecutiveParseFailures, 0)

        strategy.resetParseFailures()
        XCTAssertEqual(strategy.consecutiveRetries, 0)
        XCTAssertEqual(strategy.consecutiveTransientFailures, 0)
        XCTAssertEqual(strategy.consecutiveParseFailures, 0)
    }

    // MARK: - WF-CC6: the MLX model-slot race is not a parse failure
    //
    // ⚠️ `MLXService` keeps ONE model container. When another run loads a different model,
    // `container(expecting:)` refuses rather than answering from the wrong one and throws
    // `.modelIdentityMismatch`. That error matched NO branch here and fell to the parse-failure
    // catch-all — so the user was told "your last output failed validation… please try rephrasing
    // your request" for a fault that had nothing to do with their prompt or the model's output.
    //
    // ⚠️ The counter assertions are not decoration. Correcting only the ACTION would still charge
    // the parse budget, and three races would still abort the run with the "rephrase" message.

    func testModelSlotRace_IsNeverAParseFailure() {
        var strategy = LLMRetryStrategy(transport: mlxTransport)
        let action = strategy.handleError(makeIdentityMismatch())

        if case .parseRetry = action { XCTFail("a model-slot race is not a parse failure — got \(action)") }
        if case .abort = action { XCTFail("must not abort on the first race — got \(action)") }
        XCTAssertEqual(strategy.consecutiveParseFailures, 0,
                       "the parse budget must be untouched — otherwise three races still end the run with 'please try rephrasing your request'")
    }

    func testModelSlotRace_FirstHitRetriesAndNamesBothModels() {
        var strategy = LLMRetryStrategy(transport: mlxTransport)
        let action = strategy.handleError(makeIdentityMismatch())

        guard case .networkRetry(let message, let delay) = action else {
            return XCTFail("Expected a bounded retry, got \(action)")
        }
        XCTAssertEqual(delay, 2.0, accuracy: 0.001)
        XCTAssertTrue(message.contains("Phi-4-mini-instruct-4bit"), "the needed model must be named: \(message)")
        XCTAssertTrue(message.contains("Qwen3.5-9B-MLX-8bit"), "the model holding the slot must be named: \(message)")
        XCTAssertFalse(message.localizedCaseInsensitiveContains("rephras"),
                       "the user's prompt must never be blamed for a slot race: \(message)")
    }

    func testModelSlotRace_SecondHitIsFatalWithModelUnloadedCategory() {
        var strategy = LLMRetryStrategy(transport: mlxTransport)
        _ = strategy.handleError(makeIdentityMismatch())
        let action = strategy.handleError(makeIdentityMismatch())

        guard case .fatal(let reason, let category) = action else {
            return XCTFail("Expected .fatal once the slot budget is spent, got \(action)")
        }
        XCTAssertEqual(category, .modelUnloaded,
                       "telemetry must record a model-slot fault, not a parse failure")
        XCTAssertTrue(reason.contains("Phi-4-mini-instruct-4bit") && reason.contains("Qwen3.5-9B-MLX-8bit"),
                      "the error card must name both models: \(reason)")
        XCTAssertFalse(reason.localizedCaseInsensitiveContains("rephras"), reason)
    }

    /// ⚠️ THE ASSERTION THAT SEPARATES A REAL FIX FROM A COSMETIC ONE. Moving the typed block
    /// BELOW `consecutiveParseFailures += 1` leaves every action above correct while still burning
    /// the parse budget — so a genuine parse failure afterwards would arrive pre-charged and the
    /// run would abort early with the false "rephrase" message.
    func testModelSlotRace_DoesNotBurnTheParseBudget() {
        var strategy = LLMRetryStrategy(transport: mlxTransport)
        _ = strategy.handleError(makeIdentityMismatch())
        _ = strategy.handleError(makeIdentityMismatch())

        let action = strategy.handleError(makeUnrecognisedError())
        guard case .parseRetry(_, let attempt, _) = action else {
            return XCTFail("an unrecognised error is still a parse failure, got \(action)")
        }
        XCTAssertEqual(attempt, 1, "the first REAL parse failure must be attempt 1, not pre-charged by two races")
        XCTAssertEqual(strategy.consecutiveParseFailures, 1)
    }

    /// `"<none>"` means the slot was EMPTIED by a concurrent load, not that a model named
    /// "<none>" is squatting. It must never be rendered to the user as a model name.
    func testModelSlotRace_NoneHolderIsNotRenderedAsAModelName() {
        var strategy = LLMRetryStrategy(transport: mlxTransport)
        let action = strategy.handleError(makeIdentityMismatch(actual: "<none>"))

        guard case .networkRetry(let message, _) = action else {
            return XCTFail("Expected a bounded retry, got \(action)")
        }
        XCTAssertTrue(message.contains("another local model load"), message)
        XCTAssertFalse(message.contains("'<none>'"), "'<none>' must not surface as a model name: \(message)")
    }

    /// ⚠️ The verdict must not depend on which transport policy happens to be resolved. Routing
    /// this through `transientAction` would make it `.fatal` under MLX (budget 0) but
    /// `.networkRetry` under cloud — a fault whose classification changes with the provider class.
    func testModelSlotRace_ClassificationIsTransportIndependent() {
        for (label, transport) in [("mlx", mlxTransport), ("cloud", cloudTransport), ("ollama", ollamaTransport)] {
            var strategy = LLMRetryStrategy(transport: transport)
            let action = strategy.handleError(makeIdentityMismatch())
            guard case .networkRetry = action else {
                return XCTFail("[\(label)] expected a bounded retry regardless of transport, got \(action)")
            }
            XCTAssertEqual(strategy.consecutiveTransientFailures, 0,
                           "[\(label)] the slot race has its own budget and must not consume the transport budget")
        }
    }

    /// ⚠️ PROSE-INDEPENDENT by construction: this passes a TYPED `.noModelLoaded`, so it holds
    /// even if `errorDescription`'s wording changes. The deleted test asserted the opposite —
    /// it depended entirely on the wording.
    func testNoModelLoaded_TypedError_RoutesToModelReload() {
        var strategy = LLMRetryStrategy(transport: mlxTransport)
        let action = strategy.handleError(MLXService.ServiceError.noModelLoaded)

        if case .modelReload = action {} else {
            XCTFail("a typed .noModelLoaded must route to .modelReload, got \(action)")
        }
        XCTAssertEqual(strategy.consecutiveParseFailures, 0)
    }

    /// ⚠️ NEGATIVE CONTROL. A fix that routed EVERYTHING away from `.parseRetry` would pass every
    /// test above. An error the strategy has no arm for must still charge the parse budget.
    ///
    /// ⚠️ The vehicle changed 2026-08-20: this used to pass an untyped "Empty response from model"
    /// NSError and was named `testEmptyModelResponse_IsStillAParseRetry`. Empty responses are now
    /// typed and correctly NOT parse failures, so keeping that name and payload would have asserted
    /// behaviour no production code can produce. The control now uses a genuinely unrecognised error.
    func testUnrecognisedError_IsStillAParseRetry() {
        var strategy = LLMRetryStrategy(transport: mlxTransport)
        let action = strategy.handleError(makeUnrecognisedError())

        guard case .parseRetry(let alert, let attempt, _) = action else {
            return XCTFail("an unrecognised error IS a parse failure, got \(action)")
        }
        XCTAssertEqual(attempt, 1)
        XCTAssertEqual(strategy.consecutiveParseFailures, 1)

        // ⚠️ This line used to read `XCTAssertTrue(alert.contains("reasoning"), "the corrective
        // alert is still correct HERE")`. It was not correct here — it was asserting the defect.
        // This strategy was built with no dialect, which is the "unknown / transport-native" case,
        // and the alert it produced prescribed the `.nativeJSON` shape (`reasoning` + `toolCalls`)
        // to whatever model happened to be running. The assertion pinned that prescription in
        // place, so the fix had to delete it. What the negative control is FOR — an error with no
        // typed arm still charges the parse budget — is asserted above and is untouched.
        XCTAssertFalse(alert.contains("toolCalls"),
                       "with no dialect the corrective must not prescribe one dialect's shape: \(alert)")
        XCTAssertTrue(alert.contains("final_answer"),
                      "the corrective must always leave the model an exit: \(alert)")
    }

    // MARK: - Empty response: NOT a parse failure

    /// ⚠️ THE ASSERTION THAT MATTERS MOST. A model that produced nothing must not be told
    /// "Your last output failed validation … you MUST output valid JSON … no markdown fences."
    /// That text is false, it is ~205 chars added to the prompt on EVERY attempt, and it instructs
    /// a silent model to stop doing something it never did. A device log showed it accumulating —
    /// scratchpad 21 → 203 → 408 → 613 — across five empties that then aborted the run.
    func testEmptyResponse_InjectsNothingIntoTheModelsContext() {
        var strategy = LLMRetryStrategy(transport: mlxTransport)
        let action = strategy.handleError(makeEmptyResponse())

        if case .parseRetry(let alert, _, _) = action {
            XCTFail("an empty response must NOT return .parseRetry — that injects '\(alert)' into the model's context")
        }
        guard case .networkRetry = action else {
            return XCTFail("expected a retry that carries no corrective alert, got \(action)")
        }
    }

    /// It must not burn the budget meant for malformed OUTPUT — otherwise a genuine parse failure
    /// afterwards arrives pre-charged, exactly the defect `testModelSlotRace_DoesNotBurnTheParseBudget`
    /// pins for the MLX race.
    func testEmptyResponse_DoesNotBurnTheParseBudget() {
        var strategy = LLMRetryStrategy(transport: mlxTransport)
        _ = strategy.handleError(makeEmptyResponse())
        _ = strategy.handleError(makeEmptyResponse())

        XCTAssertEqual(strategy.consecutiveParseFailures, 0, "empties must not charge the parse budget")
        XCTAssertEqual(strategy.consecutiveEmptyResponses, 2)

        guard case .parseRetry(_, let attempt, _) = strategy.handleError(makeUnrecognisedError()) else {
            return XCTFail("a real parse failure must still be one")
        }
        XCTAssertEqual(attempt, 1, "the first REAL parse failure must be attempt 1, not pre-charged by two empties")
    }

    /// The abort names the actual lever. The old message said "the model is returning responses I
    /// can't interpret — try rephrasing your request or switching to a different model", which sent
    /// the reader toward the prompt when the cause was a sampling setting.
    func testEmptyResponse_AbortsWithSamplingAdviceNotRephraseAdvice() {
        var strategy = LLMRetryStrategy(transport: mlxTransport)
        var last: RetryAction = .abort(reason: "")
        for _ in 0..<5 { last = strategy.handleError(makeEmptyResponse()) }

        guard case .abort(let reason) = last else {
            return XCTFail("repeated empties must eventually abort, got \(last)")
        }
        XCTAssertTrue(reason.localizedCaseInsensitiveContains("repetition penalty"),
                      "the abort must name the setting that actually causes this: \(reason)")
        XCTAssertFalse(reason.localizedCaseInsensitiveContains("rephras"),
                       "rephrasing cannot fix a model that emitted nothing: \(reason)")
        XCTAssertFalse(reason.localizedCaseInsensitiveContains("can't interpret"),
                       "there was nothing to interpret: \(reason)")
    }

    /// Bounded — and lower than the parse cap, because a fresh sample is the only variable an
    /// empty-response retry changes.
    func testEmptyResponse_IsBoundedBelowTheParseCap() {
        var strategy = LLMRetryStrategy(maxConsecutiveParseFailures: 5, transport: mlxTransport)
        var aborted = 0
        for _ in 0..<5 {
            if case .abort = strategy.handleError(makeEmptyResponse()) { aborted += 1 }
        }
        XCTAssertGreaterThan(aborted, 0, "empties must be bounded, not retried forever")
        XCTAssertEqual(strategy.consecutiveParseFailures, 0)
    }

    func testResetClearsEmptyResponseBudget() {
        var strategy = LLMRetryStrategy(transport: mlxTransport)
        _ = strategy.handleError(makeEmptyResponse())
        XCTAssertEqual(strategy.consecutiveEmptyResponses, 1)
        strategy.resetParseFailures()
        XCTAssertEqual(strategy.consecutiveEmptyResponses, 0,
                       "a successful iteration must clear this, or an unrelated empty later in the run starts pre-charged")
    }

    func testResetClearsModelSlotBudget() {
        var strategy = LLMRetryStrategy(transport: mlxTransport)
        _ = strategy.handleError(makeIdentityMismatch())
        strategy.resetParseFailures()

        let action = strategy.handleError(makeIdentityMismatch())
        guard case .networkRetry = action else {
            return XCTFail("after a successful parse the slot budget must be fresh, got \(action)")
        }
    }

    /// ⚠️ Documents WHY the production `switch` has no `default:`. If a third `ServiceError` case
    /// is ever added, the production switch fails to BUILD — that compiler check is the real fix.
    /// This test fails to build alongside it, pointing here.
    func testMLXServiceErrorCaseInventoryIsComplete() {
        let all: [MLXService.ServiceError] = [.noModelLoaded, makeIdentityMismatch()]
        for error in all {
            switch error {
            case .noModelLoaded, .modelIdentityMismatch:
                continue    // exhaustive by design — add the new case to the production switch too
            }
        }
        XCTAssertEqual(all.count, 2, "a new ServiceError case needs a typed arm in LLMRetryStrategy")
    }
}
