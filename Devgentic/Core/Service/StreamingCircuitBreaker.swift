// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
//
//  StreamingCircuitBreaker.swift
//  Devgentic
//
//  Created by Raj Singh.
//

import Foundation
import OSLog

private let logger = DGLogger(category: "CircuitBreaker")

/// Monitors a token stream for repetitive loops and signals when generation should stop early. Scans every
/// `checkInterval` characters for a block of `N` characters repeated `repetitionThreshold` times in a row, across
/// several window sizes.
struct StreamingCircuitBreaker {

    /// Result of feeding a chunk into the circuit breaker.
    enum Status {
        /// Generation is healthy — continue streaming.
        case healthy
        /// Repetition loop detected — terminate generation immediately.
        /// Associated value is a diagnostic message for logging.
        case tripped(reason: String)
    }

    // MARK: - Configuration

    /// How many consecutive repetitions of the same block trigger a trip.
    /// Default: 3 (the same block appearing 3 times in a row).
    let repetitionThreshold: Int

    /// How often (in characters of accumulated text) to run the repetition check.
    /// Lower = more responsive but more CPU. Default: 100 characters.
    let checkInterval: Int

    /// The window sizes to scan for repeating blocks (in characters).
    /// Multiple sizes catch both short loops (e.g. 30-char JSON fragments)
    /// and long loops (e.g. 200-char complete tool call blocks).
    let windowSizes: [Int]

    /// How many times one tool call (same name, same arguments) may appear in a single turn before
    /// the breaker trips. Default: 3, so one accidental duplicate passes and the third copy stops it.
    let repeatedCallLimit: Int

    // MARK: - State

    /// Copies of each call seen this turn, keyed by its exact serialized form.
    private var callCounts: [String: Int] = [:]

    /// All text generated so far in this streaming session.
    private(set) var accumulatedText: String = ""

    /// Character count at which the next check will run.
    private var nextCheckAt: Int

    /// Whether the breaker has already tripped (sticky — once tripped, stays tripped).
    private(set) var hasTripped: Bool = false

    // MARK: - Init

    /// Creates a circuit breaker for a single generation session. Defaults: three repetitions trip it, checked every
    /// 100 characters over windows of 40, 80, 150 and 300; `repeatedCallLimit` copies of one tool call trip it (default
    /// 3).
    init(
        repetitionThreshold: Int = 3,
        checkInterval: Int = 100,
        windowSizes: [Int] = [40, 80, 150, 300],
        repeatedCallLimit: Int = 3
    ) {
        self.repetitionThreshold = repetitionThreshold
        self.checkInterval = checkInterval
        self.windowSizes = windowSizes
        self.repeatedCallLimit = repeatedCallLimit
        self.nextCheckAt = checkInterval
    }

    // MARK: - Feed

    /// Feeds a chunk of generated text into the breaker; call it for every `.chunk(text)`. Returns `.tripped` when a
    /// repetition loop is detected, `.healthy` otherwise.
    mutating func feed(_ chunk: String) -> Status {
        guard !hasTripped else {
            return .tripped(reason: "Circuit breaker already tripped")
        }

        accumulatedText += chunk

        // Only check at intervals to avoid per-token overhead
        guard accumulatedText.count >= nextCheckAt else {
            return .healthy
        }

        // Advance the next check point
        nextCheckAt = accumulatedText.count + checkInterval

        // Scan for repeating blocks at each configured window size
        for windowSize in windowSizes {
            if let reason = checkRepetition(windowSize: windowSize) {
                hasTripped = true
                logger.warning("🔴 Circuit breaker TRIPPED: \(reason)")
                return .tripped(reason: reason)
            }
        }

        return .healthy
    }

    // MARK: - Repeated Tool Calls

    // Why: decoded tool calls arrive as `.toolCall` events, not text, so the text check in `feed(_:)` never sees them.
    /// Feeds one tool call the model wrote this turn. Returns `.tripped` once the same call has appeared
    /// `repeatedCallLimit` times. The caller must then drop that copy and stop generating. `signature` is the call's
    /// serialized form; `name` is for diagnostics.
    mutating func feedToolCall(_ signature: String, name: String) -> Status {
        guard !hasTripped else {
            return .tripped(reason: "Circuit breaker already tripped")
        }
        let count = (callCounts[signature] ?? 0) + 1
        callCounts[signature] = count
        guard count >= repeatedCallLimit else { return .healthy }

        hasTripped = true
        let reason = "the model wrote the same call to '\(name)' \(count) times in one turn"
        logger.warning("🔴 Circuit breaker TRIPPED: \(reason)")
        return .tripped(reason: reason)
    }

    // MARK: - Repetition Detection

    /// Checks whether the last `windowSize` characters of accumulated text repeat `repetitionThreshold` times
    /// consecutively. Returns a reason string when they do, nil otherwise.
    private func checkRepetition(windowSize: Int) -> String? {
        let text = accumulatedText

        // Need at least (threshold * windowSize) characters to detect repetition
        let requiredLength = repetitionThreshold * windowSize
        guard text.count >= requiredLength else { return nil }

        // Extract the candidate block from the tail of the text
        let endIndex = text.endIndex
        let blockStart = text.index(endIndex, offsetBy: -windowSize)
        let candidateBlock = String(text[blockStart..<endIndex])

        // Check if the candidate block is trivially empty/whitespace
        let trimmed = candidateBlock.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count > 5 else { return nil }

        // Walk backward and check if the preceding blocks match
        var matchCount = 1 // The candidate itself counts as 1
        var cursor = blockStart

        for _ in 1..<repetitionThreshold {
            // Can we go back another windowSize?
            guard cursor >= text.index(text.startIndex, offsetBy: windowSize) else { return nil }

            let prevStart = text.index(cursor, offsetBy: -windowSize)
            let prevBlock = String(text[prevStart..<cursor])

            if prevBlock == candidateBlock {
                matchCount += 1
                cursor = prevStart
            } else {
                break
            }
        }

        if matchCount >= repetitionThreshold {
            let preview = candidateBlock.prefix(60).replacingOccurrences(of: "\n", with: "\\n")
            return "Detected \(matchCount)x repetition of \(windowSize)-char block: \"\(preview)...\""
        }

        return nil
    }

    // MARK: - Trim Output

    /// Returns the accumulated text with the repetitive tail removed, keeping the first occurrence of the repeated
    /// block. Call after `.tripped` to get clean output.
    func trimmedOutput() -> String {
        guard hasTripped else { return accumulatedText }

        // Find the longest window that triggered the trip
        // and remove the repeated tails
        for windowSize in windowSizes.sorted(by: >) {
            let requiredLength = repetitionThreshold * windowSize
            guard accumulatedText.count >= requiredLength else { continue }

            let endIndex = accumulatedText.endIndex
            let blockStart = accumulatedText.index(endIndex, offsetBy: -windowSize)
            let candidateBlock = String(accumulatedText[blockStart..<endIndex])

            // Verify this window actually has repetition
            var matchCount = 1
            var cursor = blockStart

            for _ in 1..<repetitionThreshold {
                guard cursor >= accumulatedText.index(accumulatedText.startIndex, offsetBy: windowSize) else { break }
                let prevStart = accumulatedText.index(cursor, offsetBy: -windowSize)
                let prevBlock = String(accumulatedText[prevStart..<cursor])
                if prevBlock == candidateBlock {
                    matchCount += 1
                    cursor = prevStart
                } else {
                    break
                }
            }

            if matchCount >= repetitionThreshold {
                // Keep everything up to and including the FIRST occurrence of the repeated block
                let firstRepeatEnd = accumulatedText.index(cursor, offsetBy: windowSize)
                return String(accumulatedText[accumulatedText.startIndex..<firstRepeatEnd])
            }
        }

        // Fallback: couldn't isolate the repetition point, return as-is
        return accumulatedText
    }
}
