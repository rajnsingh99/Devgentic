// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
//
//  RemoteChunkedSend.swift
//  Devgentic
//
//  Created by Raj Singh.
//

import Foundation

// MARK: - Rate-limit reporting

/// An error that carries the platform's own wait-this-long instruction.
/// Each client's error enum conforms by answering `retryAfterSeconds`, the only thing the send driver needs.
protocol RemoteRateLimitedError: Error {
    /// Seconds the platform asked us to wait, or nil when this error is not a rate limit.
    /// A rate limit the platform did not quantify answers with a value, not nil, so the driver can tell them apart.
    var retryAfterSeconds: TimeInterval? { get }
}

// MARK: - The driver

enum RemoteChunkedSend {

    /// Raised when some chunks landed and the rest did not.
    /// Carries `delivered`, so a caller can resume from it instead of restarting.
    struct PartialDelivery: LocalizedError {
        let delivered: Int
        let total: Int
        let underlying: Error

        var errorDescription: String? {
            "Delivered \(delivered) of \(total) message part(s); the rest failed: "
            + underlying.localizedDescription
        }
    }

    // Why: the bound must exist: retrying forever makes a throttled channel an invisible loop; never retrying loses
    // the reply's tail.
    /// How many times one chunk is retried after a rate limit before the send gives up.
    static let rateLimitRetries = 3

    /// The longest this will honour a platform's `Retry-After`; a longer wait is clamped and the send fails instead of
    /// parking.
    static let maxRetryAfter: TimeInterval = 30

    /// Sends `chunks` in order, pausing when the platform asks and reporting how far it got.
    /// - Parameters: `chunks` are pre-fitted by `RemoteTextBudget.chunk`; `startingAt` resumes after a `PartialDelivery`.
    /// - Throws: `PartialDelivery` once a chunk landed, else the first failure's error.
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
                    // Only a rate limit is retried: retrying a 400 re-sends a message the platform already refused on its merits.
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
