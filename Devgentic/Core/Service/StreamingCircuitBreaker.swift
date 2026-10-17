// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
//
//  StreamingCircuitBreaker.swift
//  Devgentic
//
//  Safety mechanism for MLX on-device generation.
//  Monitors the token stream in real-time and terminates generation early
//  when it detects pathological repetition loops — preventing runaway
//  generation that wastes compute and produces garbage output.
//
//  Created by Devgentic Architect.
//

import Foundation
import OSLog

private let logger = DGLogger(category: "CircuitBreaker")

/// Monitors a token stream for repetitive loops and signals when generation
/// should be terminated early.
///
/// ## How It Works
///
/// The breaker accumulates generated text and periodically scans for repeating
/// blocks. It uses a **sliding window** approach: it checks whether a block of
/// `N` characters at the end of the accumulated text also appears earlier,
/// repeated consecutively. If the same block appears `repetitionThreshold`
/// times in a row, the breaker trips.
///
/// Multiple window sizes are checked (small → large) to catch both short loops
/// ("}\n{" repeated) and long loops (entire tool call blocks repeated).
///
/// ## Performance
///
/// Repetition checks are only performed every `checkInterval` characters of
/// accumulated text, so the overhead per token is negligible.
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

    /// Creates a new circuit breaker for a single generation session.
    ///
    /// - Parameters:
    ///   - repetitionThreshold: Consecutive repetitions before tripping. Default: 3.
    ///   - checkInterval: Characters between checks. Default: 100.
    ///   - windowSizes: Block sizes to scan. Default: [40, 80, 150, 300].
    ///   - repeatedCallLimit: Copies of one tool call that trip the breaker. Default: 3.
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

    /// Feeds a new chunk of generated text into the breaker.
    ///
    /// Call this for every `.chunk(text)` received from the generation stream.
    /// Returns `.tripped` if a repetition loop is detected, `.healthy` otherwise.
    ///
    /// - Parameter chunk: The newly generated text chunk.
    /// - Returns: The breaker status after incorporating this chunk.
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

    /// Feeds one tool call the model wrote this turn. Returns `.tripped` when the same call has now
    /// appeared `repeatedCallLimit` times; the caller must then NOT forward that copy and must stop
    /// generating.
    ///
    /// ⚠️ WHY `feed(_:)` NEVER SAW THESE LOOPS. Calls the framework already decoded arrive as
    /// `.toolCall` events, not text, so they bypassed the text check entirely. And a text check could
    /// not have caught them anyway: it compares the last 40-300 characters with the block before,
    /// which only matches when the loop's length is a multiple of the window. The device loops were
    /// ~190 and ~350 characters per call. Qwen2.5-3B wrote the same `read_file` 46 times and the same
    /// edit 17 times, each running to the 2,048-token limit (~50s of decode, 2026-10-06).
    ///
    /// Counted per turn, not only back to back, so an alternating A, B, A, B, A loop is caught too.
    /// The executor already collapses duplicate calls before running them, so the copies withheld
    /// here would never have run: stopping loses nothing but the wasted generation.
    ///
    /// - Parameters:
    ///   - signature: the call's exact serialized form (name + arguments, keys sorted), or the raw
    ///     text of a call the framework rejected.
    ///   - name: the tool name, for the diagnostic only.
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

    /// Checks whether the last `windowSize` characters of accumulated text
    /// appear repeated `repetitionThreshold` times consecutively.
    ///
    /// Example with windowSize=50, threshold=3:
    /// If the last 150 characters consist of the same 50-char block repeated 3 times,
    /// the check returns a reason string.
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

    /// Returns the accumulated text with the repetitive tail removed.
    ///
    /// When the breaker trips, the last `(repetitionThreshold - 1) * windowSize`
    /// characters are likely garbage repetition. This method strips them,
    /// returning only the first occurrence of the repeated block plus
    /// everything before it.
    ///
    /// Call this after `.tripped` to get the clean output.
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
