// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
//
//  DurationFormat.swift
//  Devgentic
//
//  Chat + workflow duration helpers on the app-wide `DurationFormat`. The base enum
//  moved HERE 2026-08-22 when its former host (Report/SpanTreeView.swift) was deleted
//  with the old report fork. Previously this logic was copy-pasted ~7 times across
//  the chat/workflow views and had drifted — some guarded ≤0, some didn't, and the
//  timeline's ms formatter lacked minute rollover ("90.0s" instead of "1m 30s").
//  These live together so every caller shares one vocabulary.
//

import Foundation

/// App-wide duration rendering. One vocabulary for every ms → label conversion.
enum DurationFormat {
    /// The Run Report's ms formatter. Now literally `milliseconds(_:)` — it is kept only
    /// because eleven Run Report call sites spell it this way.
    ///
    /// [CF-52] It never joined the consolidation below: it carried its own
    /// `"\(minutes)m \(remainingSeconds)s"` with no zero-remainder collapse and no hour
    /// bucket, so the same 60 s value read "1m" in the timeline and "1m 0s" in the Run
    /// Report, and a two-hour run read "120m 0s". That is verbatim the drift the
    /// consolidation exists to remove, so it delegates like everything else.
    static func format(ms: Int) -> String {
        milliseconds(ms)
    }
}

extension DurationFormat {

    /// The ONE minute/hour rendering every helper in this file delegates to — `milliseconds`,
    /// `elapsed`, `seconds`, and (since CF-52) `format(ms:)`.
    ///
    /// The file header records that these were consolidated because the copies "had drifted";
    /// the drift survived INSIDE the consolidated version — two helpers collapsed a zero
    /// remainder to "1m" while the third printed "1m 0s", and none rolled over to hours, so a
    /// long run read "90m 0s". Adding a case here now changes every caller at once, which is
    /// the point of having it.
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
    /// Used by capability cards, the agent timeline and — through `format(ms:)`, which is now
    /// a thin alias — the Run Report. One vocabulary for every ms duration in the app.
    ///
    /// Clamped ≥0 like `elapsed`: a negative duration is a clock artefact, and "-42ms" in a
    /// tool row reads as a real measurement.
    static func milliseconds(_ ms: Int) -> String {
        let ms = max(0, ms)
        if ms < 1000 { return "\(ms)ms" }
        let s = Double(ms) / 1000.0
        // ⚠️ [mm-8] Bucket on the value the FORMAT will print, not the raw one. `s < 60` was
        // tested against the unrounded value while the string came from `%.1f`, which rounds —
        // so 59,950–59,999 ms chose the seconds bucket and then printed "60.0s", the exact
        // unit-drift this consolidated helper exists to remove.
        //
        // ⚠️ And do NOT "fix" it by rounding the input: that changes 500 ms of behaviour to
        // correct 50 ms, and hands `clock` a ROUNDED count while `elapsed` hands it a TRUNCATED
        // one, so the same run reads differently in an export and in the live footer.
        //
        // ⚠️⚠️ Deriving the whole seconds from `tenths` has the SAME defect and a wider blast
        // radius — I shipped that first and a cold read caught it. `Int(tenths/10)` rounds at the
        // tenth, so EVERY duration in an `[n.95, n+1)` band disagreed with `elapsed`: measured
        // 700 disagreements across 60–200 s, i.e. ~5% of all values, versus the 50 ms this row
        // was filed for.
        //
        // The bucket is chosen from the ROUNDED value (so "60.0s" is unrepresentable) while the
        // whole seconds are TRUNCATED (so `clock` matches `elapsed` exactly). `max(60, …)` is
        // needed only for the `[59.95, 60)` band, where the two disagree by construction — above
        // 60 s it is a no-op. Measured: zero disagreements with `elapsed` at or above 60 s.
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
