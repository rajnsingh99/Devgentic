//
//  ProgressThrottler.swift
//  Devgentic
//
//  Created 2026-04-21.
//
//  Tiny value-type helper used by the DownloadManager bridges to throttle
//  how often progress snapshots are written to the SwiftData history store.
//  Ollama's pull stream can fire progress callbacks dozens of times per
//  second; writing every single update to disk would thrash the store and
//  trigger excess SwiftUI invalidation for no user-visible gain.
//
//  Rule: write only when `abs(progress - lastWritten) >= minimumDelta`.
//  Bookends (0.0 and 1.0) are always allowed through so the first and
//  last states are never dropped — that guarantees "just started" and
//  "just finished" UI transitions remain snappy even if the delta window
//  hasn't elapsed yet.
//

import Foundation

struct ProgressThrottler {

    /// Minimum absolute change required before a new write is allowed.
    /// Default 0.01 = 1%.
    private let minimumDelta: Double

    /// Last progress value we allowed through. Nil until the first write.
    private var lastWritten: Double?

    init(minimumDelta: Double = 0.01) {
        self.minimumDelta = max(0, minimumDelta)
    }

    /// Returns `true` if the caller should persist this progress value.
    /// Updates internal state on `true`. Idempotent on `false`.
    mutating func shouldWrite(progress: Double) -> Bool {
        // Always let the bookends through — first progress (0.0) seeds the
        // starting state, final progress (>= 1.0) closes out the record.
        if progress <= 0 || progress >= 1 {
            lastWritten = progress
            return true
        }
        if let last = lastWritten, abs(progress - last) < minimumDelta {
            return false
        }
        lastWritten = progress
        return true
    }

    /// Clears last-written state. Call when starting a fresh download so
    /// the first progress callback still passes through the bookend check.
    mutating func reset() {
        lastWritten = nil
    }
}
