// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
//
//  SSEStreamParser.swift
//  Devgentic
//
//  Created by Raj Singh.
//

import Foundation

/// The decision a provider's per-line decoder returns for each streamed line. The shared transport owns reading
/// lines, cancellation, stall timeout and SSE `event:` framing; the provider owns only the semantics of one line.
enum SSELineDirective {
    /// Yield this text chunk to the consumer and keep reading.
    case emit(String)
    /// Yield this text chunk, then end the stream cleanly (one line that both
    /// carries content and signals completion — e.g. Ollama's `done: true`).
    case emitThenFinish(String)
    /// Ignore this line (keep-alive, unrelated event, unparseable delta).
    case skip
    /// Clean end-of-stream sentinel (e.g. OpenAI `[DONE]`, Anthropic `message_stop`).
    case finish
    /// Protocol-level error event — finish the stream throwing this error.
    case fail(Error)
}

/// Shared transport for line-delimited streaming responses (SSE and NDJSON), and the single owner of streaming
/// resilience. Cancellation: Stop tears down the underlying network read. Stall timeout: a watchdog bounds the gap
/// between lines (`URLError(.timedOut)`). Providers supply `openBytes` and a pure `handleLine`.
enum SSEStreamParser {

    /// Max seconds to wait for the next line before failing the stream. Guards gaps between lines only: opening the
    /// request is bounded by `timeoutInterval`, and the watchdog is paused for it.
    static let defaultStallTimeout: TimeInterval = 60

    /// Builds a cancellable, stall-guarded text stream from a line-delimited source. `beforeOpen` is an admission wait
    /// during which the stall watchdog is paused; `onClose` runs exactly once when the reader ends. `openBytes` runs
    /// inside the managed task; `handleLine` maps a line (with the latest SSE `event:`) to a directive.
    static func stream(
        stallTimeout: TimeInterval = defaultStallTimeout,
        beforeOpen: (@Sendable () async throws -> Void)? = nil,
        onClose: (@Sendable () -> Void)? = nil,
        openBytes: @escaping @Sendable () async throws -> URLSession.AsyncBytes,
        onUsage: (@Sendable (TokenUsage) -> Void)? = nil,
        extractUsage: (@Sendable (_ line: String, _ event: String) -> TokenUsage?)? = nil,
        handleLine: @escaping @Sendable (_ line: String, _ event: String) -> SSELineDirective
    ) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            let heartbeat = StreamHeartbeat()

            let reader = Task {
                defer { onClose?() }
                do {
                    if let beforeOpen {
                        await heartbeat.pause()
                        try await beforeOpen()
                        await heartbeat.resume()
                    }
                    // Paused while the request is opened too: the rate limiter's wait or a cold model load can exceed `stallTimeout`
                    // before anything is connected, and that phase is bounded by `timeoutInterval`.
                    await heartbeat.pause()
                    let bytes = try await openBytes()
                    await heartbeat.resume()

                    var currentEvent = ""
                    var accumulatedUsage: TokenUsage?
                    // Reports the accumulated usage exactly once, on a clean end of stream (never on error or cancel); accumulation lets
                    // a provider emit usage as partials that sum to the full count.
                    func reportUsageIfNeeded() {
                        if let onUsage, let accumulatedUsage { onUsage(accumulatedUsage) }
                    }

                    for try await line in bytes.lines {
                        try Task.checkCancellation()
                        await heartbeat.tick()

                        // SSE event framing is handled centrally; harmless for NDJSON
                        // providers, which never emit `event:` lines.
                        if line.hasPrefix("event: ") {
                            currentEvent = String(line.dropFirst(7))
                                .trimmingCharacters(in: .whitespacesAndNewlines)
                            continue
                        }

                        if let extractUsage, let lineUsage = extractUsage(line, currentEvent) {
                            accumulatedUsage = (accumulatedUsage ?? TokenUsage()).accumulated(with: lineUsage)
                        }

                        switch handleLine(line, currentEvent) {
                        case .emit(let text):
                            continuation.yield(text)
                        case .emitThenFinish(let text):
                            continuation.yield(text)
                            reportUsageIfNeeded()
                            continuation.finish()
                            return
                        case .skip:
                            continue
                        case .finish:
                            reportUsageIfNeeded()
                            continuation.finish()
                            return
                        case .fail(let error):
                            continuation.finish(throwing: error)
                            return
                        }
                    }
                    reportUsageIfNeeded()
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }

            // Watchdog: fails the stream and tears down the reader if no line arrives within `stallTimeout`; checks often enough
            // to react promptly without busy-waiting.
            let checkInterval = min(stallTimeout, 5)
            let watchdog = Task {
                while true {
                    do {
                        try await Task.sleep(for: .seconds(checkInterval))
                    } catch {
                        return // cancelled
                    }
                    if Task.isCancelled { return }
                    if await heartbeat.isStalled(threshold: .seconds(stallTimeout)) {
                        continuation.finish(throwing: URLError(.timedOut))
                        reader.cancel()
                        return
                    }
                }
            }

            continuation.onTermination = { @Sendable _ in
                reader.cancel()
                watchdog.cancel()
            }
        }
    }
}

/// Records the time of the last streamed line so the watchdog can detect a silent
/// connection. Actor-isolated because the reader writes it and the watchdog reads it.
private actor StreamHeartbeat {
    private let clock = ContinuousClock()
    private var last: ContinuousClock.Instant

    init() {
        last = clock.now
    }

    /// True while the stream waits for its turn (`beforeOpen`): nothing is connected, so nothing
    /// can stall.
    private var paused = false

    func tick() {
        last = clock.now
    }

    func pause() {
        paused = true
    }

    /// The stall clock starts again from now.
    func resume() {
        paused = false
        last = clock.now
    }

    func isStalled(threshold: Duration) -> Bool {
        !paused && clock.now - last >= threshold
    }
}
