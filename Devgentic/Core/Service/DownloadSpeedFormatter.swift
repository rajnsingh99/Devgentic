//
//  DownloadSpeedFormatter.swift
//  Devgentic
//
//  Created 2026-04-21.
//
//  Tiny formatting helpers for the live download speed + ETA display.
//  Centralized here so the sidebar row, detail view card, and the
//  shared `ModelDownloadStatusView` all use the same vocabulary
//  ("12.4 MB/s · 3 min left" / "— · calculating…").
//

import Foundation

enum DownloadSpeedFormatter {

    /// Localized bytes-per-second string ("12.4 MB/s", "844 KB/s").
    /// Uses `.file` counting style to match what every backend's
    /// installer UI shows (disk-space convention, powers of 1024).
    static func formatBytesPerSecond(_ bytesPerSecond: Double) -> String {
        let bytes = Int64(bytesPerSecond.rounded())
        let formatter = ByteCountFormatter()
        formatter.allowedUnits = [.useMB, .useKB, .useGB]
        formatter.countStyle = .file
        formatter.includesUnit = true
        let label = formatter.string(fromByteCount: max(0, bytes))
        return "\(label)/s"
    }

    /// Human-readable ETA ("3 min left", "45 sec left", "~2 hr left").
    /// Buckets the output to whole units so the number doesn't flicker
    /// second-by-second while watching a multi-minute download.
    static func formatETA(_ seconds: TimeInterval) -> String {
        guard seconds.isFinite, seconds >= 0 else { return "—" }
        if seconds < 5 {
            return "< 5 sec left"
        }
        if seconds < 60 {
            return "\(Int(seconds.rounded())) sec left"
        }
        if seconds < 3600 {
            let minutes = Int((seconds / 60).rounded())
            return "\(minutes) min left"
        }
        let hours = seconds / 3600
        if hours < 10 {
            return String(format: "%.1f hr left", hours)
        }
        return "\(Int(hours.rounded())) hr left"
    }

    /// Combined "speed · eta" string, or just speed when ETA is unknown,
    /// or "calculating…" until the sampler warms up.
    static func compactLine(snapshot: DownloadSpeedSnapshot?) -> String {
        guard let snapshot else { return "calculating…" }
        let speed = formatBytesPerSecond(snapshot.bytesPerSecond)
        if let eta = snapshot.etaSeconds {
            return "\(speed) · \(formatETA(eta))"
        }
        return speed
    }
}
