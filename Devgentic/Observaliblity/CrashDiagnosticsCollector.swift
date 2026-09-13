// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2026 Raj Singh
//
//  CrashDiagnosticsCollector.swift
//  Devgentic
//
//  Crash & hang capture (observability §12.1). Before this, a crash was the one
//  scenario where the trace stack recorded NOTHING — the event buffer died with the
//  process and the trace stayed `running` with no cause. Three mechanisms close that:
//
//  1. **MetricKit subscriber** — macOS delivers `MXDiagnosticPayload`s (crash, hang,
//     CPU-exception, disk-write-exception diagnostics) on the launch after the incident.
//     We persist each payload's JSON to Application Support/Devgentic/CrashDiagnostics/
//     and emit an error-level log entry (always recorded post-B3) for correlation.
//     Persisted as files, not DB rows, deliberately: no schema migration, and the
//     diagnostic bundle ships them verbatim.
//
//  2. **`.ips` harvest** — macOS writes full crash reports to
//     ~/Library/Logs/DiagnosticReports/<ProcessName>-<date>.ips. Reading that directory
//     is only possible UN-sandboxed — which the website-distribution decision locked in.
//     `BundleExporter` calls `harvestCrashReports` to fold them (sanitized) into the
//     bundle's crashes/ section.
//
//  3. **Clean-exit sentinel** — a UserDefaults flag set false at launch and true in
//     `applicationWillTerminate`. If a launch reads false, the previous session crashed
//     or was force-killed; the orphan-trace reconciliation reason says so instead of
//     the generic "interrupted".
//

import Foundation
import MetricKit

private let logger = DGLogger(category: "CrashDiagnostics")

final class CrashDiagnosticsCollector: NSObject, MXMetricManagerSubscriber {

    static let shared = CrashDiagnosticsCollector()
    private override init() { super.init() }

    // MARK: - Lifecycle

    /// Registers for MetricKit diagnostics. Call once, early at launch — payloads for a
    /// previous session's crash are delivered shortly after registration.
    func start() {
        MXMetricManager.shared.add(self)
    }

    func stop() {
        MXMetricManager.shared.remove(self)
    }

    // MARK: - MXMetricManagerSubscriber

    func didReceive(_ payloads: [MXDiagnosticPayload]) {
        // Respect the diagnostics opt-out (B3) — same consent gate as every other recorder.
        guard AppSettings.diagnosticsRecordingEnabled else { return }

        let dir = Self.diagnosticsDirectory
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        let stamp = ISO8601DateFormatter().string(from: Date())
            .replacingOccurrences(of: ":", with: "-")

        for (index, payload) in payloads.enumerated() {
            let crashes = payload.crashDiagnostics?.count ?? 0
            let hangs = payload.hangDiagnostics?.count ?? 0
            let cpuExceptions = payload.cpuExceptionDiagnostics?.count ?? 0
            let diskWrites = payload.diskWriteExceptionDiagnostics?.count ?? 0
            guard crashes + hangs + cpuExceptions + diskWrites > 0 else { continue }

            // UUID suffix: the stamp is second-resolution, so two deliveries within the
            // same second must not overwrite each other.
            let url = dir.appendingPathComponent("metrickit-\(stamp)-\(index)-\(UUID().uuidString.prefix(8)).json")
            do {
                try payload.jsonRepresentation().write(to: url)
            } catch {
                logger.error("Failed to persist MetricKit diagnostic payload: \(error.localizedDescription)")
                continue
            }

            logger.error(
                "MetricKit diagnostics received for a previous session",
                metadata: [
                    "crashes": "\(crashes)",
                    "hangs": "\(hangs)",
                    "cpu_exceptions": "\(cpuExceptions)",
                    "disk_write_exceptions": "\(diskWrites)",
                    "file": url.lastPathComponent
                ]
            )
        }
    }

    // MARK: - Storage

    /// Where persisted MetricKit payload JSONs live. Sibling of traces.sqlite.
    static var diagnosticsDirectory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Devgentic", isDirectory: true)
            .appendingPathComponent("CrashDiagnostics", isDirectory: true)
    }

    /// Deletes persisted MetricKit JSONs older than `date` (same 30-day policy as traces).
    static func purgeDiagnostics(olderThan date: Date) {
        // ⚠️ DELETES REAL FILES FROM THE DEVELOPER'S `Application Support/Devgentic/CrashDiagnostics`.
        // The store redirect does not cover this directory, so a test run silently ages out the
        // developer's own crash payloads — the ones a diagnostic bundle would have carried.
        guard TestHost.permits("purge crash-diagnostic payloads", logger: logger) else { return }

        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(
            at: diagnosticsDirectory, includingPropertiesForKeys: [.contentModificationDateKey]
        ) else { return }
        for file in files {
            let modified = (try? file.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
            if let modified, modified < date {
                try? fm.removeItem(at: file)
            }
        }
    }

    // MARK: - .ips harvest (for BundleExporter)

    /// macOS's per-user crash-report directory. Readable only because the app is
    /// un-sandboxed (website distribution, no App Store).
    static var systemDiagnosticReportsDirectory: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Logs/DiagnosticReports", isDirectory: true)
    }

    /// Whether a DiagnosticReports filename is a crash/hang report for THIS app.
    /// Apple names them `<ProcessName>-<date>.ips` (crashes) / `.hang` (hangs).
    /// Pure + static so the matching rule is unit-testable.
    static func matchesCrashReport(filename: String, processName: String) -> Bool {
        let lower = filename.lowercased()
        let proc = processName.lowercased()
        guard lower.hasPrefix(proc + "-") else { return false }
        return lower.hasSuffix(".ips") || lower.hasSuffix(".hang")
    }

    /// Crash/hang reports relevant to a diagnostic bundle: this app's `.ips`/`.hang`
    /// files from the system DiagnosticReports directory PLUS our persisted MetricKit
    /// JSONs, modified at/after `since`, newest first, capped at `limit` (the raw
    /// reports can be a few hundred KB each).
    static func harvestCrashReports(since: Date, limit: Int = 10) -> [URL] {
        let fm = FileManager.default
        let processName = ProcessInfo.processInfo.processName
        var candidates: [(url: URL, modified: Date)] = []

        let systemFiles = (try? fm.contentsOfDirectory(
            at: systemDiagnosticReportsDirectory, includingPropertiesForKeys: [.contentModificationDateKey]
        )) ?? []
        for file in systemFiles where matchesCrashReport(filename: file.lastPathComponent, processName: processName) {
            if let modified = (try? file.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate,
               modified >= since {
                candidates.append((file, modified))
            }
        }

        let metricKitFiles = (try? fm.contentsOfDirectory(
            at: diagnosticsDirectory, includingPropertiesForKeys: [.contentModificationDateKey]
        )) ?? []
        for file in metricKitFiles where file.pathExtension == "json" {
            if let modified = (try? file.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate,
               modified >= since {
                candidates.append((file, modified))
            }
        }

        return candidates
            .sorted { $0.modified > $1.modified }
            .prefix(limit)
            .map(\.url)
    }

    // MARK: - Clean-exit sentinel

    private static let sentinelKey = "diagnosticsCleanExitSentinel"

    /// Reads whether the PREVIOUS session exited cleanly, then marks the current
    /// session dirty (it stays dirty until `markCleanExit` runs at termination).
    /// A missing value (first launch / pre-feature install) counts as clean — never
    /// report a phantom crash. Call exactly once, first thing at launch.
    @discardableResult
    static func consumeLaunchSentinel(defaults: UserDefaults = .standard) -> Bool {
        let wasClean = (defaults.object(forKey: sentinelKey) as? Bool) ?? true
        defaults.set(false, forKey: sentinelKey)
        return wasClean
    }

    /// Marks this session as cleanly exited. Call from `applicationWillTerminate`.
    /// Force-quit (kill -9) and crashes never reach it — which is exactly the signal.
    static func markCleanExit(defaults: UserDefaults = .standard) {
        defaults.set(true, forKey: sentinelKey)
    }
}
