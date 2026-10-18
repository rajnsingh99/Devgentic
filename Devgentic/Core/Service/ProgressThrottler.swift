// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
//
//  ProgressThrottler.swift
//  Devgentic
//
//  Created by Raj Singh.
//

import Foundation

/// Value-type helper that throttles how often download progress snapshots are written to the history store.
/// Writes only when `abs(progress - lastWritten) >= minimumDelta`; 0.0 and 1.0 always pass so first and last states land.
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
