//
//  CloudRequestPipeline.swift
//  Devgentic
//
//  Created by Raj Singh on 27/03/26.
//
//  Shared HTTP middleware for all cloud LLM providers (Anthropic, OpenAI, Google).
//  Handles rate limiting, error enrichment, and request-id logging.
//

import Foundation
import OSLog

private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "com.devgentic.app", category: "CloudRequestPipeline")

/// A stateless pipeline that wraps URLSession calls with cross-cutting concerns
/// shared by all cloud LLM providers: rate limiting, structured error creation,
/// and response header extraction.
struct CloudRequestPipeline: Sendable {

    // MARK: - Standard (Non-Streaming) Request

    /// Executes a standard HTTP request through the cloud pipeline.
    /// - Parameters:
    ///   - request: The fully constructed URLRequest (body, headers, URL already set by the provider).
    ///   - provider: The rate limit category for pre-request throttling and 429 penalty.
    ///   - session: The URLSession to use (defaults to `.shared`).
    /// - Returns: The response `Data` and `HTTPURLResponse` on success.
    /// - Throws: `CloudProviderError` on non-2xx responses, or `LLMProviderError` for non-HTTP responses.
    static func execute(
        request: URLRequest,
        provider: RateLimitCategory,
        rateLimitKey: String? = nil,
        session: URLSession = .shared
    ) async throws -> (Data, HTTPURLResponse) {
        // 1. Pre-request: respect rate limits (profile-scoped when key provided)
        let key = rateLimitKey ?? provider.rawValue
        await GlobalRateLimiter.shared.wait(forKey: key, category: provider)

        // 2. Execute the request
        let (data, response) = try await session.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw LLMProviderError.invalidResponse("Not an HTTP response")
        }

        // 3. Log request-id on all responses for debugging
        let requestId = extractRequestId(from: httpResponse)
        if let requestId {
            logger.info("[\(String(describing: provider))] request-id: \(requestId) | status: \(httpResponse.statusCode)")
        }

        // 4. Validate response status
        guard (200...299).contains(httpResponse.statusCode) else {
            let body = String(data: data, encoding: .utf8) ?? "Unknown error"
            let retryAfter = extractRetryAfter(from: httpResponse)

            // On 429: drain the rate limiter bucket to prevent further requests
            if httpResponse.statusCode == 429 {
                let penalty = retryAfter ?? 10.0
                await GlobalRateLimiter.shared.drainAndPenalize(key: key, category: provider, penaltySeconds: penalty)
                logger.warning("[\(key)] 429 Rate Limited. Retry-After: \(retryAfter ?? -1)s. Penalty applied: \(penalty)s.")
            }

            throw CloudProviderError(
                statusCode: httpResponse.statusCode,
                retryAfterSeconds: retryAfter,
                requestId: requestId,
                rawBody: body,
                provider: provider
            )
        }

        return (data, httpResponse)
    }

    // MARK: - Streaming Request

    /// Executes a streaming HTTP request through the cloud pipeline.
    /// Validates the initial HTTP response before returning the byte stream.
    static func executeStream(
        request: URLRequest,
        provider: RateLimitCategory,
        rateLimitKey: String? = nil,
        session: URLSession = .shared
    ) async throws -> (URLSession.AsyncBytes, HTTPURLResponse) {
        // 1. Pre-request: respect rate limits (profile-scoped when key provided)
        let key = rateLimitKey ?? provider.rawValue
        await GlobalRateLimiter.shared.wait(forKey: key, category: provider)

        // 2. Execute the streaming request
        let (bytes, response) = try await session.bytes(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw LLMProviderError.invalidResponse("Not an HTTP response")
        }

        // 3. Log request-id
        let requestId = extractRequestId(from: httpResponse)
        if let requestId {
            logger.info("[\(String(describing: provider))] stream request-id: \(requestId) | status: \(httpResponse.statusCode)")
        }

        // 4. Validate initial response status
        // Note: For streaming, we can only validate the initial response headers.
        // Stream-level errors (e.g., mid-stream disconnects) are handled by the provider.
        guard (200...299).contains(httpResponse.statusCode) else {
            // Attempt to collect error body from the stream
            var errorBody = ""
            for try await line in bytes.lines {
                errorBody += line
                if errorBody.count > 2000 { break } // Cap error body collection
            }

            let retryAfter = extractRetryAfter(from: httpResponse)

            if httpResponse.statusCode == 429 {
                let penalty = retryAfter ?? 10.0
                await GlobalRateLimiter.shared.drainAndPenalize(key: key, category: provider, penaltySeconds: penalty)
                logger.warning("[\(key)] 429 on stream. Penalty: \(penalty)s.")
            }

            throw CloudProviderError(
                statusCode: httpResponse.statusCode,
                retryAfterSeconds: retryAfter,
                requestId: requestId,
                rawBody: errorBody,
                provider: provider
            )
        }

        return (bytes, httpResponse)
    }

    // MARK: - Header Extraction Helpers

    /// Extracts the provider-assigned request ID from response headers.
    private static func extractRequestId(from response: HTTPURLResponse) -> String? {
        response.value(forHTTPHeaderField: "request-id")
            ?? response.value(forHTTPHeaderField: "x-request-id")
    }

    /// Extracts the retry-after interval from response headers.
    /// Supports both seconds (integer) and HTTP-date formats.
    private static func extractRetryAfter(from response: HTTPURLResponse) -> TimeInterval? {
        guard let value = response.value(forHTTPHeaderField: "retry-after")
                ?? response.value(forHTTPHeaderField: "Retry-After") else {
            return nil
        }

        // Try parsing as seconds first (most common)
        if let seconds = TimeInterval(value) {
            return seconds
        }

        // Try parsing as HTTP-date (e.g., "Thu, 01 Dec 2025 16:00:00 GMT")
        let formatter = DateFormatter()
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        if let date = formatter.date(from: value) {
            let interval = date.timeIntervalSinceNow
            return interval > 0 ? interval : nil
        }

        return nil
    }
}
