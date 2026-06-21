//
//  DiagnosticBundle.swift
//  Devgentic
//
//  Data types for the Phase F diagnostic export. The user-facing output is a
//  zip archive with a structured layout — one JSON per concern, all sanitized.
//  This file defines the manifest + scope + includes enums; actual assembly
//  lives in `BundleExporter`.
//
//  Layout of a produced bundle:
//
//      devgentic-bug-report-{traceID8}-{iso8601}.zip
//      └── devgentic-bug-report-{...}/         (ditto --keepParent adds this)
//          ├── manifest.json                    (version, scope, includes, sanitization)
//          ├── trace.json                       (fully-hydrated TraceRecord + spans + events)
//          ├── config_snapshot.json             (TraceConfigSnapshot)
//          ├── logs/
//          │   └── recent.jsonl                 (one LogEntry per line, sanitized)
//          ├── metrics/
//          │   ├── tool_reliability.json
//          │   ├── category_frequency.json
//          │   ├── model_reliability.json
//          │   └── circuit_breaker.json
//          ├── environment/
//          │   ├── hardware.json
//          │   ├── app_version.json
//          │   └── feature_flags.json
//          ├── preferences/
//          │   └── app_settings.json            (non-secret UserDefaults)
//          ├── user_feedback/                   (only if includes.userFeedback)
//          │   ├── message.txt
//          │   ├── rating.json
//          │   └── screenshot.png               (only if includes.screenshot)
//          ├── crashes/                         (only if includes.crashes AND reports exist)
//          │   ├── <ProcessName>-<date>.ips     (sanitized system crash reports)
//          │   └── metrickit-<date>.json        (sanitized MetricKit diagnostic payloads)
//          └── SANITIZATION_NOTICE.txt          (plain-text statement of redactions)
//
//  Extensibility: adding a new section is two lines — an `Includes` case and a
//  corresponding `BundleExporter` writer method. The manifest automatically
//  records which sections were included.
//

import Foundation

enum DiagnosticBundle {

    // MARK: - Manifest

    /// Top-level manifest — written as `manifest.json` at the bundle root.
    /// Analysts read this first to understand what the bundle contains and how
    /// it was sanitized.
    struct Manifest: Codable, Sendable {
        let version: String                 // schema version: "2.0"
        let exportedAt: Date
        let scope: String                   // Scope description (human-readable)
        let includes: [String]              // Includes.rawValue names that were populated
        let sanitizationLevel: String       // "minimal" / "standard" / "strict"
        let appVersion: String
        let appBuildNumber: String
        let osVersion: String

        /// Short traceID prefix if the scope is trace-bound. Nil for recent/conversation.
        let primaryTraceID: String?
        /// UUID for the bundle itself — so analysts can reference a specific
        /// user's report without ambiguity when multiple arrive close together.
        let bundleID: String
    }

    // MARK: - Scope

    /// What slice of the diagnostic data to export. Controls which traces,
    /// logs, and metrics get included.
    enum Scope: Sendable, Equatable {
        /// Single trace by ID — the default invocation from ReportInspector's
        /// "Export Bundle" button.
        case trace(traceID: String)

        /// All traces in a conversation. Useful for multi-turn bug reports
        /// ("things broke after message 5").
        case conversation(id: UUID)

        /// Recent activity across all conversations. `hours` defines the window.
        /// Logs and metrics pulled for the same window. Used when the user
        /// reports a general "things have been weird" issue without a specific
        /// failed message.
        case recent(hours: Int)

        /// Human-readable description used in the manifest.
        var describe: String {
            switch self {
            case .trace(let id): return "trace:\(id.prefix(8))"
            case .conversation(let id): return "conversation:\(id.uuidString.prefix(8))"
            case .recent(let hours): return "recent:\(hours)h"
            }
        }

        /// Lower bound for timestamp-range queries (logs, metrics). For `.trace`
        /// and `.conversation` scopes, we default to 1 hour before the earliest
        /// trace's start; if that can't be determined we use the configured window.
        var defaultLookbackHours: Int {
            switch self {
            case .trace: return 1
            case .conversation: return 24
            case .recent(let h): return h
            }
        }
    }

    // MARK: - Includes

    /// Bitmask of which bundle sections to populate. The UI presents these as
    /// checkboxes; presets (`.full`, `.minimal`) cover common selections.
    struct Includes: OptionSet, Sendable {
        let rawValue: Int

        /// Trace record + spans + events (the existing trace.json content).
        static let trace          = Includes(rawValue: 1 << 0)

        /// Request configuration snapshot captured at trace start (Phase B).
        static let configSnapshot = Includes(rawValue: 1 << 1)

        /// In-app log ring buffer entries (Phase C). Filtered to info-and-above.
        static let logs           = Includes(rawValue: 1 << 2)

        /// Aggregated metrics snapshot (Phase E) — per-tool/per-category/per-model.
        static let metrics        = Includes(rawValue: 1 << 3)

        /// Hardware profile + OS + app version.
        static let environment    = Includes(rawValue: 1 << 4)

        /// Non-secret UserDefaults (feature flags, preferences).
        static let preferences    = Includes(rawValue: 1 << 5)

        /// User-typed feedback text + positive/negative rating.
        static let userFeedback   = Includes(rawValue: 1 << 6)

        /// Screenshot PNG (requires userFeedback).
        static let screenshot     = Includes(rawValue: 1 << 7)

        /// Crash & hang reports (§12.1): the app's `.ips`/`.hang` files from
        /// ~/Library/Logs/DiagnosticReports + persisted MetricKit payloads, sanitized.
        static let crashes        = Includes(rawValue: 1 << 8)

        // MARK: Presets

        /// Everything available — maximum diagnostic value. What developers should
        /// pick when investigating their own issues.
        static let full: Includes = [
            .trace, .configSnapshot, .logs, .metrics,
            .environment, .preferences, .crashes
        ]

        /// Bare minimum for a reproducible bug — no behavioral metrics, no logs.
        /// For cases where the user wants minimal data leakage.
        static let minimal: Includes = [.trace, .configSnapshot, .environment]

        /// Presets for the user-feedback flow — trace + config + logs + environment,
        /// plus the feedback/rating if available. No metrics dashboard data since
        /// that's dev-oriented. Crashes included: "it crashed" is the report this
        /// flow most needs to answer.
        static let userReport: Includes = [
            .trace, .configSnapshot, .logs, .environment, .userFeedback, .crashes
        ]

        /// Human-readable rawValue names — used to populate `Manifest.includes`.
        var describe: [String] {
            var names: [String] = []
            if contains(.trace)          { names.append("trace") }
            if contains(.configSnapshot) { names.append("config_snapshot") }
            if contains(.logs)           { names.append("logs") }
            if contains(.metrics)        { names.append("metrics") }
            if contains(.environment)    { names.append("environment") }
            if contains(.preferences)    { names.append("preferences") }
            if contains(.userFeedback)   { names.append("user_feedback") }
            if contains(.screenshot)     { names.append("screenshot") }
            if contains(.crashes)        { names.append("crashes") }
            return names
        }
    }

    // MARK: - Result

    /// What the exporter returns to the caller after a successful export.
    struct Result: Sendable {
        /// Location of the produced zip archive.
        let zipURL: URL

        /// The manifest that was written inside. Handy for the UI to show a
        /// "bundle contents" summary without re-reading the zip.
        let manifest: Manifest

        /// Total bytes of the zip file.
        let zipSizeBytes: Int64
    }
}
