import Foundation

/// Decision a provider's per-line decoder returns for each streamed line.
///
/// The shared transport owns the *mechanics* (reading lines, cancellation, stall
/// timeout, SSE `event:` framing); the provider owns only the *semantics* of one
/// `data:`/JSON line via a pure function that returns one of these directives.
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

/// Shared transport for line-delimited streaming responses (SSE and NDJSON).
///
/// This consolidates the read loop that used to be copy-pasted across the cloud
/// providers (audit #14) and is the single place that owns streaming resilience
/// (audit #13):
///   1. **Cancellation** — the read runs in a task that `onTermination` cancels, and
///      every iteration re-checks `Task.checkCancellation()`. Tapping Stop therefore
///      tears down the underlying network read instead of leaking it (stops remote
///      token billing / frees the local GPU) rather than only halting the UI.
///   2. **Stall timeout** — a watchdog bounds the gap *between* lines. The request's
///      own `timeoutInterval` only covers the initial response; a server that accepts
///      the request then goes silent used to hang the turn forever. A stall surfaces as
///      `URLError(.timedOut)` so the existing `ProviderErrorClassifier` handles it.
///   3. **The `for try await line in bytes.lines` loop + SSE `event:` framing.**
///
/// Providers supply `openBytes` (build the request and return the validated byte
/// stream) and a pure `handleLine` decoder.
enum SSEStreamParser {

    /// Max seconds to wait for the *next* line before failing the stream. Guards the
    /// gaps between chunks only — the initial connection is bounded by the request's
    /// `timeoutInterval`. 60s between tokens is already pathological, so this will not
    /// false-trip on a slow-but-alive stream.
    static let defaultStallTimeout: TimeInterval = 60

    /// Builds a cancellable, stall-guarded text stream from a line-delimited source.
    ///
    /// - Parameters:
    ///   - stallTimeout: bound on the wait between lines (see ``defaultStallTimeout``).
    ///   - openBytes: builds the request and returns the validated byte stream. Runs
    ///     inside the managed task so request-build and connect errors flow through the
    ///     same teardown path as mid-stream errors.
    ///   - handleLine: maps one raw line to a directive. `event` carries the most recent
    ///     SSE `event:` value; for NDJSON providers it is always "".
    static func stream(
        stallTimeout: TimeInterval = defaultStallTimeout,
        openBytes: @escaping @Sendable () async throws -> URLSession.AsyncBytes,
        onUsage: (@Sendable (TokenUsage) -> Void)? = nil,
        extractUsage: (@Sendable (_ line: String, _ event: String) -> TokenUsage?)? = nil,
        handleLine: @escaping @Sendable (_ line: String, _ event: String) -> SSELineDirective
    ) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            let heartbeat = StreamHeartbeat()

            let reader = Task {
                do {
                    let bytes = try await openBytes()
                    await heartbeat.tick()

                    var currentEvent = ""
                    var accumulatedUsage: TokenUsage?
                    // Reports the accumulated usage exactly once, on a clean end of stream
                    // (never on error/cancel). Accumulation lets a provider emit usage as
                    // partials — e.g. Claude's input on `message_start` + output on
                    // `message_delta` — that sum to the full count.
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

            // Watchdog: fails the stream (and tears down the reader) if no line has
            // arrived within `stallTimeout`. Checks frequently enough to react promptly
            // without busy-waiting.
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

    func tick() {
        last = clock.now
    }

    func isStalled(threshold: Duration) -> Bool {
        clock.now - last >= threshold
    }
}
