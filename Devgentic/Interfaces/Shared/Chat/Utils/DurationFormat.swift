//
//  DurationFormat.swift
//  Devgentic
//
//  Chat + workflow duration helpers, added to the app-wide `DurationFormat`
//  (declared in Report/SpanTreeView.swift). Previously this logic was copy-pasted
//  ~7 times across the chat/workflow views and had drifted — some guarded ≤0, some
//  didn't, and the timeline's ms formatter lacked minute rollover ("90.0s" instead
//  of "1m 30s"). These live as an extension so every caller shares one vocabulary.
//

import Foundation

extension DurationFormat {

    /// The ONE minute/hour rendering all three helpers delegate to.
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
    /// Used by capability cards and the agent timeline (tool durations are ms).
    /// Distinct from `format(ms:)` (Report spans) only in that a whole-minute value
    /// renders "1m" rather than "1m 0s".
    ///
    /// Clamped ≥0 like `elapsed`: a negative duration is a clock artefact, and "-42ms" in a
    /// tool row reads as a real measurement.
    static func milliseconds(_ ms: Int) -> String {
        let ms = max(0, ms)
        if ms < 1000 { return "\(ms)ms" }
        let s = Double(ms) / 1000.0
        if s < 60 { return String(format: "%.1fs", s) }
        return clock(wholeSeconds: Int(s))
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
        if d < 60 { return "\(String(format: "%.1f", d))s" }
        return clock(wholeSeconds: Int(d))
    }
}
