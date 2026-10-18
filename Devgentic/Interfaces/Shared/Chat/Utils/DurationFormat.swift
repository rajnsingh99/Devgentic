// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
//
//  DurationFormat.swift
//  Devgentic
//
//  Created by Raj Singh.
//

import Foundation

/// App-wide duration rendering. One vocabulary for every ms → label conversion.
enum DurationFormat {
    /// The Run Report's ms formatter; an alias of `milliseconds(_:)`.
    static func format(ms: Int) -> String {
        milliseconds(ms)
    }
}

extension DurationFormat {

    /// The one minute/hour rendering every helper in this file delegates to.
    /// Changing a case here changes every caller at once.
    private static func clock(wholeSeconds: Int) -> String {
        if wholeSeconds < 60 { return "\(wholeSeconds)s" }

        let hours = wholeSeconds / 3600
        let minutes = (wholeSeconds % 3600) / 60
        let seconds = wholeSeconds % 60

        if hours > 0 {
            // Seconds are dropped past an hour: at that scale they are noise, and
            // "1h 2m 3s" is harder to scan than "1h 2m".
            return minutes == 0 ? "\(hours)h" : "\(hours)h \(minutes)m"
        }
        return seconds == 0 ? "\(minutes)m" : "\(minutes)m \(seconds)s"
    }

    /// Integer **milliseconds** → "820ms" / "3.4s" / "1m 5s" / "1h 2m".
    /// Used by capability cards, the agent timeline and the Run Report (via `format(ms:)`).
    /// Clamped to >= 0 like `elapsed`, since a negative duration is a clock artefact.
    static func milliseconds(_ ms: Int) -> String {
        let ms = max(0, ms)
        if ms < 1000 { return "\(ms)ms" }
        let s = Double(ms) / 1000.0
        // Bucket on the rounded value the format prints (so "60.0s" cannot appear), but truncate the whole seconds
        // so `clock` agrees with `elapsed`; `max(60, …)` only matters in the [59.95, 60) band.
        let tenths = (s * 10).rounded()
        if tenths < 600 { return String(format: "%.1fs", s) }
        return clock(wholeSeconds: max(60, Int(s)))
    }

    /// Wall-clock **elapsed** between two dates → "0s" / "45s" / "1m 5s" / "1h 2m". Clamped ≥0.
    /// Used by the live streaming footer and capability-card headers.
    static func elapsed(from start: Date, to now: Date) -> String {
        clock(wholeSeconds: max(0, Int(now.timeIntervalSince(start))))
    }

    /// A **seconds** interval → "" (≤0) / "<1s" / "3.4s" / "2m 5s" / "1h 2m".
    /// Used by the workflow run views, whose durations are `TimeInterval` seconds.
    static func seconds(_ d: TimeInterval) -> String {
        if d <= 0 { return "" }
        if d < 1 { return "<1s" }
        // [mm-8] Same rounding-vs-bucket rule as `milliseconds`, truncation included — see its note.
        let tenths = (d * 10).rounded()
        if tenths < 600 { return "\(String(format: "%.1f", d))s" }
        return clock(wholeSeconds: max(60, Int(d)))
    }
}
