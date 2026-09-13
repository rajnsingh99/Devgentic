// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2026 Raj Singh
//
//  RemoteChunkedSend.swift
//  Devgentic
//
//  Delivering a reply that does not fit one message.
//
//  ⚠️⚠️ WHAT THIS REPLACES, AND WHY IT WAS THE WORST BUG IN THE SEND PATH. All three API clients
//  spelled a chunked send the same way:
//
//      for chunk in chunks { try await sendMessage(chunk) }
//
//  Three defects live in that line. (1) There is no pacing and no honouring of `Retry-After`: all
//  three clients PARSE the header — `SlackAPIClient` and `DiscordAPIClient` even carry the value in
//  `rateLimited(retryAfter:)` — and every one of them then throws it away, because the only readers
//  of that case anywhere in the tree are `errorDescription` switches. Nothing sleeps and nothing
//  retries. (2) A throw on chunk k abandons chunks k+1…n, so the user gets an answer that stops
//  mid-sentence with no indication that more was written. (3) The caller's retry re-sends from chunk
//  ONE, because nothing records how far the send actually got — so the mirror's retry duplicates
//  every chunk that already arrived.
//
//  ⚠️ THE RESUME POINT IS THE POINT. `PartialDelivery.delivered` is what makes (3) fixable: a caller
//  holding it can resume rather than restart. A boolean "it failed" cannot express the difference
//  between "nothing arrived" and "the first four paragraphs arrived twice".
//

import Foundation

// MARK: - Rate-limit reporting

/// An error that carries the platform's own "wait this long" instruction.
///
/// ⚠️ A PROTOCOL RATHER THAN A SHARED ERROR TYPE, because the three clients' error enums are public
/// surface used elsewhere and re-typing them would be a much larger change than this fix deserves.
/// Each conforms by answering one question, which is the only thing the send driver needs to know.
protocol RemoteRateLimitedError: Error {
    /// Seconds the platform asked us to wait, or nil when this error is not a rate limit.
    ///
    /// ⚠️ `nil` for a NON-rate-limit error; a rate limit the platform did not quantify answers with
    /// a value, not with nil — the driver cannot tell those apart otherwise.
    var retryAfterSeconds: TimeInterval? { get }
}

// MARK: - The driver

enum RemoteChunkedSend {

    /// Raised when some chunks landed and the rest did not.
    ///
    /// ⚠️ CARRIES THE COUNT, so a caller can resume from `delivered` instead of restarting. Nothing
    /// could express that before, which is why the mirror's retry re-posted arrived chunks.
    struct PartialDelivery: LocalizedError {
        let delivered: Int
        let total: Int
        let underlying: Error

        var errorDescription: String? {
            "Delivered \(delivered) of \(total) message part(s); the rest failed: "
            + underlying.localizedDescription
        }
    }

    /// How many times one chunk is retried after a rate limit before the send gives up.
    ///
    /// ⚠️ THREE, and the number matters less than the bound existing. Retrying forever turns a
    /// throttled channel into an unbounded background loop the user cannot see or stop; not
    /// retrying at all is what shipped, and it loses the tail of every throttled reply.
    static let rateLimitRetries = 3

    /// The longest this will honour a platform's `Retry-After`.
    ///
    /// ⚠️ A HOSTILE OR ABSURD VALUE IS STILL A NUMBER THE PLATFORM SENT. Sleeping for a header-
    /// supplied hour inside a send would look exactly like a hang, so the wait is clamped and the
    /// send fails honestly instead of parking.
    static let maxRetryAfter: TimeInterval = 30

    /// Sends `chunks` in order, pausing when the platform asks and reporting how far it got.
    ///
    /// - Parameters:
    ///   - chunks: the pieces, already fitted to the platform's budget by `RemoteTextBudget.chunk`.
    ///   - startingAt: the first index to send. A caller resuming a `PartialDelivery` passes its
    ///     `delivered` count here so already-arrived chunks are not posted twice.
    ///   - send: posts one chunk.
    /// - Throws: `PartialDelivery` when at least one chunk landed, or the underlying error when the
    ///   very first one failed (nothing arrived, so there is no partial state to describe).
    static func send(
        _ chunks: [String],
        startingAt startIndex: Int = 0,
        sleep: @Sendable (TimeInterval) async throws -> Void = { try await Task.sleep(nanoseconds: UInt64($0 * 1_000_000_000)) },
        _ send: (String) async throws -> Void
    ) async throws {
        guard startIndex < chunks.count else { return }

        var delivered = startIndex

        for index in startIndex..<chunks.count {
            var attempt = 0
            while true {
                do {
                    try await send(chunks[index])
                    delivered = index + 1
                    break
                } catch {
                    // ⚠️ ONLY a rate limit is retried. Retrying a 400 re-sends a message the
                    // platform has already refused on its merits, which cannot start working.
                    guard let wait = (error as? RemoteRateLimitedError)?.retryAfterSeconds,
                          attempt < rateLimitRetries else {
                        guard delivered > startIndex else { throw error }
                        throw PartialDelivery(delivered: delivered, total: chunks.count, underlying: error)
                    }
                    attempt += 1
                    try await sleep(min(wait, maxRetryAfter))
                }
            }
        }
    }
}
