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

    /// Integer **milliseconds** → "820ms" / "3.4s" / "1m 5s".
    /// Used by capability cards and the agent timeline (tool durations are ms).
    /// Distinct from `format(ms:)` (Report spans) only in that a whole-minute value
    /// renders "1m" rather than "1m 0s".
    static func milliseconds(_ ms: Int) -> String {
        if ms < 1000 { return "\(ms)ms" }
        let s = Double(ms) / 1000.0
        if s < 60 { return String(format: "%.1fs", s) }
        let minutes = Int(s) / 60
        let remaining = Int(s) % 60
        return remaining == 0 ? "\(minutes)m" : "\(minutes)m \(remaining)s"
    }

    /// Wall-clock **elapsed** between two dates → "0s" / "45s" / "1m 5s". Clamped ≥0.
    /// Used by the live streaming footer and capability-card headers.
    static func elapsed(from start: Date, to now: Date) -> String {
        let seconds = max(0, Int(now.timeIntervalSince(start)))
        if seconds < 60 { return "\(seconds)s" }
        let minutes = seconds / 60
        let remaining = seconds % 60
        return remaining == 0 ? "\(minutes)m" : "\(minutes)m \(remaining)s"
    }

    /// A **seconds** interval → "" (≤0) / "<1s" / "3.4s" / "2m 5s".
    /// Used by the workflow run views, whose durations are `TimeInterval` seconds.
    static func seconds(_ d: TimeInterval) -> String {
        if d <= 0 { return "" }
        if d < 1 { return "<1s" }
        if d < 60 { return "\(String(format: "%.1f", d))s" }
        return "\(Int(d / 60))m \(Int(d.truncatingRemainder(dividingBy: 60)))s"
    }
}
