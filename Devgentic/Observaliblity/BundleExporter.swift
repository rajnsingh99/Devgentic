// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
//
//  BundleExporter.swift
//  Devgentic
//
//  Produces the Phase F diagnostic export — a zip archive with structured
//  contents assembled from Trace, Config, Logs, Metrics, Environment, and
//  Preferences surfaces. All text fields pass through `TelemetrySanitizer`
//  at the caller-specified level before being written to disk.
//
//  Entry point: `BundleExporter.export(scope:includes:feedback:sanitizationLevel:)`
//  → returns `DiagnosticBundle.Result` with the zip URL + manifest.
//
//  Zip assembly uses `/usr/bin/ditto` (native, always present on macOS) to avoid
//  a third-party compression dependency. Staging directory is always cleaned up,
//  even on error.
//

import Foundation
import os

enum BundleExporter {

    // MARK: - Errors

    enum BundleError: Error {
        case storeUnavailable
        case encodingFailed(String)
        case writeFailed(String)
        case zipFailed(String)
        case invalidScope(String)
    }

    private static let logger = Logger(subsystem: DGLogger.subsystem,
                                        category: "BundleExporter")

    // MARK: - Public entry point

    /// Assembles a diagnostic bundle for the given scope + includes. The result
    /// is a zip at a stable location in the system temp directory; callers should
    /// reveal it in Finder or move it to user-chosen destination immediately
    /// (the temp dir is cleaned up on system reboot).
    ///
    /// All text content is sanitized before writing. Even with `.minimal`, home
    /// paths, IPs, and emails are redacted. `.standard` adds API keys, bearer
    /// tokens, and common secret JSON keys. `.strict` further redacts hostnames
    /// and usernames.
    static func export(
        scope: DiagnosticBundle.Scope,
        includes: DiagnosticBundle.Includes,
        feedback: UserFeedback? = nil,
        sanitizationLevel: TelemetrySanitizer.Level = .standard
    ) async throws -> DiagnosticBundle.Result {

        let bundleID = UUID().uuidString
        let traceIDPrefix = {
            if case .trace(let tid) = scope { return String(tid.prefix(8)) }
            return "bundle"
        }()
        let stageName = "devgentic-bug-report-\(traceIDPrefix)-\(Self.shortTimestamp())"
        let stagingDir = FileManager.default.temporaryDirectory.appendingPathComponent(stageName)

        // Always clean up staging on exit (success or failure).
        defer {
            try? FileManager.default.removeItem(at: stagingDir)
        }

        try FileManager.default.createDirectory(at: stagingDir, withIntermediateDirectories: true)
        logger.info("Bundle staging at: \(stagingDir.path)")

        // --- Manifest first so it's at the root of the zip ---
        let manifest = try buildManifest(
            scope: scope,
            includes: includes,
            sanitizationLevel: sanitizationLevel,
            bundleID: bundleID
        )
        try writeJSON(manifest, to: stagingDir.appendingPathComponent("manifest.json"), sanitize: false)

        // For a single-trace scope, anchor the logs/metrics lookback to when the run
        // actually started (not export time), so a report filed hours later still
        // contains the run's logs (Gap #18). nil for conversation/recent scopes.
        let traceWindowAnchor = resolveTraceAnchor(for: scope)

        // --- Each section is gated on the Includes set ---
        if includes.contains(.trace) {
            try await writeTrace(scope: scope, to: stagingDir, level: sanitizationLevel)
        }
        if includes.contains(.configSnapshot) {
            try await writeConfigSnapshot(scope: scope, to: stagingDir, level: sanitizationLevel)
        }
        if includes.contains(.logs) {
            try await writeLogs(scope: scope, anchor: traceWindowAnchor, to: stagingDir, level: sanitizationLevel)
        }
        if includes.contains(.metrics) {
            try writeMetrics(scope: scope, anchor: traceWindowAnchor, to: stagingDir, level: sanitizationLevel)
        }
        if includes.contains(.environment) {
            try writeEnvironment(to: stagingDir, level: sanitizationLevel)
        }
        if includes.contains(.preferences) {
            try writePreferences(to: stagingDir, level: sanitizationLevel)
        }
        if includes.contains(.userFeedback), let feedback {
            try writeUserFeedback(
                feedback: feedback,
                includeScreenshot: includes.contains(.screenshot),
                to: stagingDir,
                level: sanitizationLevel
            )
        }
        if includes.contains(.crashes) {
            writeCrashes(scope: scope, anchor: traceWindowAnchor, to: stagingDir, level: sanitizationLevel)
        }

        // --- Human-readable sanitization notice ---
        try writeSanitizationNotice(to: stagingDir, level: sanitizationLevel, includes: includes)

        // --- Zip via ditto ---
        let outputZip = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(stageName).zip")
        // If a stale zip with the same timestamp somehow exists, remove it first.
        try? FileManager.default.removeItem(at: outputZip)
        try zipDirectory(stagingDir, to: outputZip)

        let zipSize = (try? FileManager.default.attributesOfItem(atPath: outputZip.path)[.size] as? Int64) ?? 0

        logger.info("Bundle created: \(outputZip.path) (\(zipSize) bytes)")

        return DiagnosticBundle.Result(
            zipURL: outputZip,
            manifest: manifest,
            zipSizeBytes: zipSize
        )
    }

    // MARK: - Manifest

    private static func buildManifest(
        scope: DiagnosticBundle.Scope,
        includes: DiagnosticBundle.Includes,
        sanitizationLevel: TelemetrySanitizer.Level,
        bundleID: String
    ) throws -> DiagnosticBundle.Manifest {
        let info = Bundle.main.infoDictionary ?? [:]
        let appVersion = (info["CFBundleShortVersionString"] as? String) ?? "unknown"
        let appBuild = (info["CFBundleVersion"] as? String) ?? "unknown"

        let primaryTraceID: String? = {
            if case .trace(let tid) = scope { return tid }
            return nil
        }()

        return DiagnosticBundle.Manifest(
            version: "2.0",
            exportedAt: Date(),
            scope: scope.describe,
            includes: includes.describe,
            sanitizationLevel: describeLevel(sanitizationLevel),
            appVersion: appVersion,
            appBuildNumber: appBuild,
            osVersion: ProcessInfo.processInfo.operatingSystemVersionString,
            primaryTraceID: primaryTraceID,
            bundleID: bundleID
        )
    }

    // MARK: - Trace section

    private static func writeTrace(
        scope: DiagnosticBundle.Scope,
        to dir: URL,
        level: TelemetrySanitizer.Level
    ) async throws {
        let traceRecords = try await fetchTraces(for: scope)
        guard !traceRecords.isEmpty else {
            // Not an error — scope just matched no traces. Write an empty file
            // so the bundle layout is predictable.
            try "[]".write(to: dir.appendingPathComponent("trace.json"), atomically: true, encoding: .utf8)
            return
        }

        let payload = TraceExportPayload(traces: traceRecords)
        try writeJSON(payload, to: dir.appendingPathComponent("trace.json"), sanitize: true, level: level)
    }

    /// Internal (not private) so the hydration contract is testable: EVERY scope must
    /// return traces with their span/event tree attached. The conversation and recent
    /// arms used to return the row-only fetches — so those bundles shipped a trace.json
    /// with `"rootSpans": []` on every trace, silently reintroducing the hollow-export
    /// defect (Gap #2) that `TraceExportDTO` was written to fix.
    static func fetchTraces(for scope: DiagnosticBundle.Scope) async throws -> [TraceRecord] {
        switch scope {
        case .trace(let traceID):
            if let record = await TraceRecorder.shared.fetchFullTrace(traceID: traceID) {
                return [record]
            }
            return []
        case .conversation(let conversationID):
            let rows = await TraceRecorder.shared.fetchTraces(forConversationID: conversationID.uuidString)
            return await hydrate(rows)
        case .recent(let hours):
            // Row fetch within the window, then hydrate. For a 30-day purge window
            // this is bounded and cheap.
            guard let store = TraceStore.shared else { return [] }
            let since = Date().addingTimeInterval(-Double(hours) * 3600)
            let rows = (try? store.fetchTracesSince(since)) ?? []
            return await hydrate(rows)
        }
    }

    /// Replaces each header row with its fully-hydrated trace; a row whose tree cannot
    /// be fetched (purged mid-export) keeps the header rather than vanishing.
    private static func hydrate(_ rows: [TraceRecord]) async -> [TraceRecord] {
        var result: [TraceRecord] = []
        result.reserveCapacity(rows.count)
        for row in rows {
            result.append(await TraceRecorder.shared.fetchFullTrace(traceID: row.traceID) ?? row)
        }
        return result
    }

    /// Nested struct so the exported JSON has an object root (versioned, extensible)
    /// rather than a bare array — analysts can add sibling keys later without breaking
    /// consumers.
    private struct TraceExportPayload: Codable {
        let schemaVersion: String
        let traces: [TraceExportDTO]

        init(traces: [TraceRecord]) {
            // Bumped to "2": the payload now carries the full rootSpans → spans → events
            // tree via `TraceExportDTO`, instead of a hollow row-only `TraceRecord` whose
            // CodingKeys dropped every span/event at encode time (Gap #2).
            self.schemaVersion = "2"
            self.traces = traces.map(TraceExportDTO.init)
        }
    }

    // MARK: - Config snapshot section

    private static func writeConfigSnapshot(
        scope: DiagnosticBundle.Scope,
        to dir: URL,
        level: TelemetrySanitizer.Level
    ) async throws {
        let snapshots = try await fetchConfigSnapshots(for: scope)
        try writeJSON(
            ConfigSnapshotPayload(snapshots: snapshots),
            to: dir.appendingPathComponent("config_snapshot.json"),
            sanitize: true,
            level: level
        )
    }

    private static func fetchConfigSnapshots(for scope: DiagnosticBundle.Scope) async throws -> [TraceConfigRow] {
        guard let store = TraceStore.shared else { return [] }
        switch scope {
        case .trace(let traceID):
            if let row = try? store.fetchConfigSnapshot(traceID: traceID) { return [row] }
            return []
        case .conversation(let conversationID):
            let traces = await TraceRecorder.shared.fetchTraces(forConversationID: conversationID.uuidString)
            return traces.compactMap { try? store.fetchConfigSnapshot(traceID: $0.traceID) }
        case .recent(let hours):
            let since = Date().addingTimeInterval(-Double(hours) * 3600)
            let traces = (try? store.fetchTracesSince(since)) ?? []
            return traces.compactMap { try? store.fetchConfigSnapshot(traceID: $0.traceID) }
        }
    }

    private struct ConfigSnapshotPayload: Codable {
        let schemaVersion: String
        let snapshots: [TraceConfigRow]

        init(snapshots: [TraceConfigRow]) {
            self.schemaVersion = "1"
            self.snapshots = snapshots
        }
    }

    // MARK: - Logs section

    private static func writeLogs(
        scope: DiagnosticBundle.Scope,
        anchor: Date?,
        to dir: URL,
        level: TelemetrySanitizer.Level
    ) async throws {
        let since = exportWindowStart(scope: scope, anchor: anchor)
        // Pull full export (persisted + buffer, deduped).
        let entries = await LogRecorder.shared.export(since: since, minLevel: .info)

        // JSON Lines format: one entry per line. Easier to stream-parse for large
        // log dumps than a single JSON array.
        let logDir = dir.appendingPathComponent("logs")
        try FileManager.default.createDirectory(at: logDir, withIntermediateDirectories: true)

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601

        var output = ""
        for entry in entries {
            guard let data = try? encoder.encode(entry),
                  let json = String(data: data, encoding: .utf8) else { continue }
            output += TelemetrySanitizer.sanitizeFull(json, level: level) + "\n"
        }

        try output.write(to: logDir.appendingPathComponent("recent.jsonl"), atomically: true, encoding: .utf8)
    }

    /// The lookback anchor for logs/metrics: the trace's actual start time for a
    /// single-trace scope (so the window follows the run, not the export moment),
    /// nil otherwise (conversation/recent keep their own export-time-relative windows).
    private static func resolveTraceAnchor(for scope: DiagnosticBundle.Scope) -> Date? {
        guard case .trace(let traceID) = scope, let store = TraceStore.shared else { return nil }
        return try? store.fetchTrace(traceID: traceID)?.startedAt
    }

    /// How far back to look when a `.trace` bundle's anchor cannot be resolved.
    ///
    /// Deliberately generous. A support bundle that is quietly EMPTY is worse than one that is large:
    /// the user has already hit send, and a missing log section is discovered only by whoever reads
    /// the report, days later, with no way to ask for another.
    static let unanchoredTraceLookbackDays = 7

    /// Start of the export window — one definition, used by both the logs and crashes sections.
    ///
    /// ⚠️ The anchored path (1 h before the RUN) is correct and unchanged. The bug was the FALLBACK:
    /// `logsSince(.trace)` is 1 h before NOW, so a bundle exported for an incident that happened days
    /// ago pulled an empty window and produced a bundle with no logs and no crashes in it, silently
    /// (G49). Both sections had their own copy of the same expression, so both were wrong.
    private static func exportWindowStart(scope: DiagnosticBundle.Scope, anchor: Date?) -> Date {
        if let anchor { return anchor.addingTimeInterval(-3600) }
        if case .trace(let traceID) = scope {
            logger.warning(
                """
                [BUNDLE] Trace \(traceID) could not be located, so its start time is unknown — \
                widening to \(unanchoredTraceLookbackDays) days instead of the 1-hour default. \
                CONSEQUENCE: this bundle is larger and less focused, but it still CONTAINS the \
                incident; the 1-hour default would have exported empty log and crash sections for \
                anything older than an hour.
                """
            )
            return Date().addingTimeInterval(-Double(unanchoredTraceLookbackDays) * 24 * 3600)
        }
        return logsSince(for: scope)
    }

    private static func logsSince(for scope: DiagnosticBundle.Scope) -> Date {
        switch scope {
        case .trace:
            // Single trace: pull 1 hour before now (covers the run plus recent context).
            return Date().addingTimeInterval(-3600)
        case .conversation:
            return Date().addingTimeInterval(-24 * 3600)
        case .recent(let hours):
            return Date().addingTimeInterval(-Double(hours) * 3600)
        }
    }

    // MARK: - Metrics section

    private static func writeMetrics(
        scope: DiagnosticBundle.Scope,
        anchor: Date?,
        to dir: URL,
        level: TelemetrySanitizer.Level
    ) throws {
        let since: Date
        if let anchor {
            since = anchor.addingTimeInterval(-3600)
        } else {
            switch scope {
            case .trace: since = Date().addingTimeInterval(-24 * 3600)
            case .conversation: since = Date().addingTimeInterval(-7 * 24 * 3600)
            case .recent(let hours): since = Date().addingTimeInterval(-Double(hours) * 3600)
            }
        }
        let snapshot = MetricsAggregator.shared.snapshot(since: since)

        let metricsDir = dir.appendingPathComponent("metrics")
        try FileManager.default.createDirectory(at: metricsDir, withIntermediateDirectories: true)

        try writeJSON(
            EncodableToolStats(stats: snapshot.toolStats),
            to: metricsDir.appendingPathComponent("tool_reliability.json"),
            sanitize: true,
            level: level
        )
        try writeJSON(
            EncodableCategoryStats(stats: snapshot.categoryStats),
            to: metricsDir.appendingPathComponent("category_frequency.json"),
            sanitize: false  // pure counts, no user content
        )
        try writeJSON(
            EncodableModelStats(stats: snapshot.modelStats),
            to: metricsDir.appendingPathComponent("model_reliability.json"),
            sanitize: false
        )
        try writeJSON(
            EncodableCBStats(stats: snapshot.circuitBreakerStats),
            to: metricsDir.appendingPathComponent("circuit_breaker.json"),
            sanitize: true,
            level: level
        )
    }

    // MARK: - Environment section

    private static func writeEnvironment(
        to dir: URL,
        level: TelemetrySanitizer.Level
    ) throws {
        let envDir = dir.appendingPathComponent("environment")
        try FileManager.default.createDirectory(at: envDir, withIntermediateDirectories: true)

        // Hardware — from SystemHardwareProfiler.
        let hw = SystemHardwareProfiler.shared.profile
        let hardware = EncodableHardware(
            totalRAMBytes: hw.totalRAM,
            availableRAMBytes: hw.availableRAM,
            chipFamily: hw.chipFamily.rawValue,
            gpuCoreCount: hw.gpuCoreCount,
            effectiveBudgetBytes: hw.effectiveBudget,
            formattedTotalRAM: hw.formattedTotalRAM,
            formattedAvailableRAM: hw.formattedAvailableRAM
        )
        try writeJSON(hardware, to: envDir.appendingPathComponent("hardware.json"), sanitize: false)

        // App version.
        let info = Bundle.main.infoDictionary ?? [:]
        let app = EncodableAppVersion(
            shortVersion: info["CFBundleShortVersionString"] as? String ?? "unknown",
            buildNumber: info["CFBundleVersion"] as? String ?? "unknown",
            bundleIdentifier: Bundle.main.bundleIdentifier ?? "unknown",
            osVersion: ProcessInfo.processInfo.operatingSystemVersionString,
            osName: "macOS"
        )
        try writeJSON(app, to: envDir.appendingPathComponent("app_version.json"), sanitize: false)

        // Feature flags — curated list of ciFeature* + structural flags.
        let flags = collectFeatureFlags()
        try writeJSON(flags, to: envDir.appendingPathComponent("feature_flags.json"), sanitize: false)
    }

    private static func collectFeatureFlags() -> [String: Bool] {
        let d = UserDefaults.standard
        return [
            "developerMode":         d.bool(forKey: AppSettings.developerModeKey),
            "intelligenceCore":      d.bool(forKey: AppSettings.isIntelligenceCoreEnabledKey),
            "historyCompaction":     d.object(forKey: AppSettings.ciFeatureHistoryCompactionKey) as? Bool ?? true,
            // Per-family Response Synthesis opt-in (default false — never automatic).
            "responseSynthesisMLX":    d.bool(forKey: AppSettings.ciFeatureResponseSynthesisMLXKey),
            "responseSynthesisOllama": d.bool(forKey: AppSettings.ciFeatureResponseSynthesisOllamaKey),
            "responseSynthesisRemote": d.bool(forKey: AppSettings.ciFeatureResponseSynthesisRemoteKey),
            "userPersonal":          d.bool(forKey: AppSettings.ciFeatureUserPersonalKey),
            "ragRewriting":          d.bool(forKey: AppSettings.ciFeatureRAGRewritingKey),
            "suggestion":            d.bool(forKey: AppSettings.ciFeatureSuggestionKey)
        ]
    }

    // MARK: - Preferences section

    /// Writes a carefully curated subset of UserDefaults. API keys, bot tokens,
    /// and anything that could be user content or PII is omitted at the source —
    /// we don't just "sanitize them" after the fact. Allowlist-based extraction.
    private static func writePreferences(
        to dir: URL,
        level: TelemetrySanitizer.Level
    ) throws {
        let prefsDir = dir.appendingPathComponent("preferences")
        try FileManager.default.createDirectory(at: prefsDir, withIntermediateDirectories: true)

        let snapshot = exportablePreferenceSnapshot(from: UserDefaults.standard)
        try writeJSON(snapshot, to: prefsDir.appendingPathComponent("app_settings.json"), sanitize: true, level: level)
    }

    /// The keys that may leave the user's machine in a diagnostic bundle.
    ///
    /// ⚠️ ALLOWLIST, never a denylist: anything not named here does NOT appear in the bundle, so
    /// a new UserDefaults key added anywhere in the app is private by default. Exposed `static`
    /// (it was a local `let` inside the writer) for one reason — this is the control that decides
    /// what leaves the machine, and it had NO TEST. A privacy boundary that cannot be asserted is
    /// one refactor away from silently widening.
    static let exportablePreferenceKeys: [String] = [
            AppSettings.developerModeKey,
            AppSettings.useStreamingResponseKey,
            AppSettings.speechModelKey,
            AppSettings.speechLanguageKey,
            AppSettings.speechAutoStopOnSilenceKey,
            AppSettings.isIntelligenceCoreEnabledKey,
            AppSettings.coreIntelligenceModelKey,
            AppSettings.ciFeatureRAGRewritingKey,
            AppSettings.ciFeatureSuggestionKey,
            AppSettings.ciFeatureMorningBriefKey,
            AppSettings.ciFeatureUserPersonalKey,
            AppSettings.ciFeatureResponseSynthesisKey,
            AppSettings.ciFeatureResponseSynthesisMLXKey,
            AppSettings.ciFeatureResponseSynthesisOllamaKey,
            AppSettings.ciFeatureResponseSynthesisRemoteKey,
            AppSettings.ciFeatureHistoryCompactionKey,
            AppSettings.notificationsEnabledKey,
            // Whether macOS system delivery is on. Absent means ON. Exported because "I stopped
            // getting notifications" is otherwise undebuggable from a bundle: the master switch,
            // this per-channel switch and the OS permission are three independent gates and a
            // report that names only the first cannot distinguish them.
            AppSettings.localNotificationsEnabledKey,
            AppSettings.chatOpsNotificationsEnabledKey,
            AppSettings.chatFontSizeKey,
            AppSettings.chatLineSpacingKey,
            AppSettings.speechPlaybackRateKey,
            AppSettings.speechPlaybackVoiceKey,
            AppSettings.speechPauseOnCodeKey,
        AppSettings.morningBriefIncludeAISummaryKey,
            // Orb. Exported because a voice bug report is undebuggable without knowing how the
            // user had activation and endpointing configured — none of these carry user content.
            AppSettings.orbEnabledKey,
            AppSettings.orbActivationModeKey,
            AppSettings.orbEndpointingKey,
            AppSettings.orbSpokenResponsesKey,
            AppSettings.orbFollowUpKey,
            AppSettings.orbEarconsKey,
            AppSettings.orbToolApprovalsKey,
            AppSettings.orbDuplexAudioKey,
            AppSettings.orbRecognizerKey,
            AppSettings.orbAmbientAnnouncementsKey,
            AppSettings.orbAmbientThresholdKey,
            AppSettings.orbVoiceApprovalsKey,
            AppSettings.orbSpeechLocaleKey,
            AppSettings.orbNarratorVoiceKey,
            AppSettings.orbNarratorRateKey
    ]

    /// Extracts exactly the allowlisted preferences from a defaults store.
    ///
    /// Pure and injectable so the allowlist can be tested against a store deliberately seeded
    /// with secrets — the only way to assert "anything not in this set does NOT appear" rather
    /// than merely reading the list and hoping the writer honours it.
    static func exportablePreferenceSnapshot(from defaults: UserDefaults) -> [String: AnyCodable] {
        var snapshot: [String: AnyCodable] = [:]
        for key in exportablePreferenceKeys {
            // Read raw Any then coerce to a codable. Bool/Int/Double/String pass through;
            // anything else we stringify defensively.
            if let value = defaults.object(forKey: key) {
                snapshot[key] = AnyCodable(value: value)
            }
        }
        return snapshot
    }

    // MARK: - User feedback section

    private static func writeUserFeedback(
        feedback: UserFeedback,
        includeScreenshot: Bool,
        to dir: URL,
        level: TelemetrySanitizer.Level
    ) throws {
        let fbDir = dir.appendingPathComponent("user_feedback")
        try FileManager.default.createDirectory(at: fbDir, withIntermediateDirectories: true)

        // Message — plain text for readability.
        let sanitizedMessage = TelemetrySanitizer.sanitizeFull(feedback.messageText, level: level)
        try sanitizedMessage.write(to: fbDir.appendingPathComponent("message.txt"), atomically: true, encoding: .utf8)

        // Rating — small JSON for structured consumption. Rating is optional; we still
        // write the file (with null) so the bundle layout is predictable.
        let rating = EncodableRating(rating: feedback.rating?.rawValue)
        try writeJSON(rating, to: fbDir.appendingPathComponent("rating.json"), sanitize: false)

        // Screenshot — raw Data from the feedback view. Written verbatim; we don't
        // attempt to re-encode or sanitize pixel content. Users who include it accept
        // that the screenshot may contain UI content including conversation text.
        if includeScreenshot, let imgData = feedback.screenshotData {
            try imgData.write(to: fbDir.appendingPathComponent("screenshot.png"))
        }
    }

    // MARK: - Crashes section (§12.1)

    /// Folds the app's crash/hang reports into the bundle: this app's `.ips`/`.hang`
    /// files from ~/Library/Logs/DiagnosticReports (readable because un-sandboxed) plus
    /// persisted MetricKit payloads. Window matches the logs section (trace start − 1h
    /// when trace-scoped). Reports are text; each passes the sanitizer before writing —
    /// `.ips` files are full of user paths. Best-effort: an unreadable report is skipped,
    /// never fails the export. No crashes → no crashes/ directory (predictable layout
    /// matters less than not implying a crash where there was none).
    private static func writeCrashes(
        scope: DiagnosticBundle.Scope,
        anchor: Date?,
        to dir: URL,
        level: TelemetrySanitizer.Level
    ) {
        let since = exportWindowStart(scope: scope, anchor: anchor)
        let reports = CrashDiagnosticsCollector.harvestCrashReports(since: since)
        guard !reports.isEmpty else { return }

        let crashDir = dir.appendingPathComponent("crashes")
        guard (try? FileManager.default.createDirectory(at: crashDir, withIntermediateDirectories: true)) != nil else { return }

        var written = 0
        for report in reports {
            guard let raw = try? String(contentsOf: report, encoding: .utf8) else { continue }
            let sanitized = TelemetrySanitizer.sanitizeFull(raw, level: level)
            if (try? sanitized.write(to: crashDir.appendingPathComponent(report.lastPathComponent),
                                     atomically: true, encoding: .utf8)) != nil {
                written += 1
            }
        }
        logger.info("Bundle crashes section: \(written)/\(reports.count) report(s) included (since \(since)).")
    }

    // MARK: - Sanitization notice

    private static func writeSanitizationNotice(
        to dir: URL,
        level: TelemetrySanitizer.Level,
        includes: DiagnosticBundle.Includes
    ) throws {
        let levelDesc = describeLevel(level)
        let notice = """
        Devgentic Diagnostic Bundle — Sanitization Notice
        ===================================================

        Sanitization level: \(levelDesc)

        All text content in this bundle has been passed through
        TelemetrySanitizer.sanitizeFull(level: .\(levelDesc)) before
        being written. The following patterns are redacted:

          - Home paths (/Users/*, /home/*) → [USER_PATH]
          - IPv4 addresses → [IP_ADDR]
          - Email addresses → [EMAIL]
        \(level == .standard || level == .strict ? """
          - API keys (sk-, sk-ant-, ghp_, xoxb-, AIza, 40+ char hex) → [API_KEY]
          - Bearer tokens → [TOKEN]
          - URL basic-auth credentials (user:pass@) → [CREDS]
          - JSON values for keys: apiKey, token, secret, password,
            clientSecret, botToken, sessionToken, privateKey → [REDACTED]
          - Shell env-var assignments containing TOKEN/KEY/SECRET/PASSWORD → [REDACTED]
        """ : "")
        \(level == .strict ? """
          - (strict) JSON values for keys: email, username, userID,
            chatID, channelID, guildID, webhookURL → [REDACTED]
        """ : "")

        Sections included in this bundle: \(includes.describe.joined(separator: ", "))

        If you discover sensitive data that slipped through the sanitizer,
        please report it — it indicates a missing pattern that should be
        added to TelemetrySanitizer.swift.

        Bundle manifest: see manifest.json at bundle root.
        """

        try notice.write(to: dir.appendingPathComponent("SANITIZATION_NOTICE.txt"),
                         atomically: true, encoding: .utf8)
    }

    // MARK: - Shared helpers

    /// JSON-encodes `value`, optionally sanitizes the resulting string, and writes to URL.
    private static func writeJSON<T: Encodable>(
        _ value: T,
        to url: URL,
        sanitize: Bool,
        level: TelemetrySanitizer.Level = .standard
    ) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        do {
            let data = try encoder.encode(value)
            if sanitize, var str = String(data: data, encoding: .utf8) {
                str = TelemetrySanitizer.sanitizeFull(str, level: level)
                try str.write(to: url, atomically: true, encoding: .utf8)
            } else {
                try data.write(to: url)
            }
        } catch {
            throw BundleError.writeFailed("\(url.lastPathComponent): \(error.localizedDescription)")
        }
    }

    private static func zipDirectory(_ source: URL, to output: URL) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        // -c create, -k keep (zip format), --sequesterRsrc handle macOS metadata,
        // --keepParent preserves the bundle directory name inside the zip root.
        process.arguments = [
            "-c", "-k", "--sequesterRsrc", "--keepParent",
            source.path, output.path
        ]

        do {
            try process.run()
        } catch {
            throw BundleError.zipFailed("ditto launch failed: \(error.localizedDescription)")
        }
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw BundleError.zipFailed("ditto exit code \(process.terminationStatus)")
        }
    }

    private static func describeLevel(_ level: TelemetrySanitizer.Level) -> String {
        switch level {
        case .minimal:  return "minimal"
        case .standard: return "standard"
        case .strict:   return "strict"
        }
    }

    private static func shortTimestamp() -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        formatter.timeZone = TimeZone(identifier: "UTC")
        return formatter.string(from: Date())
    }
}

// MARK: - Encodable wrappers
//
// The metrics and preferences sections need Codable-compatible wrappers because
// the source types either don't conform (tuples in CircuitBreakerStats.topOffendingTools)
// or contain heterogenous `Any` values (UserDefaults).

private struct EncodableToolStats: Codable {
    let schemaVersion: String
    let stats: [Wrapper]

    struct Wrapper: Codable {
        let toolName: String
        let totalCalls: Int
        let successCount: Int
        let failureCount: Int
        let successRate: Double
        let avgDurationMs: Int?
        let p50DurationMs: Int?
        let p95DurationMs: Int?
        let failureBreakdown: [String: Int]  // rawValue: count
    }

    init(stats: [ToolReliabilityStats]) {
        self.schemaVersion = "1"
        self.stats = stats.map {
            Wrapper(
                toolName: $0.toolName,
                totalCalls: $0.totalCalls,
                successCount: $0.successCount,
                failureCount: $0.failureCount,
                successRate: $0.successRate,
                avgDurationMs: $0.avgDurationMs,
                p50DurationMs: $0.p50DurationMs,
                p95DurationMs: $0.p95DurationMs,
                failureBreakdown: Dictionary(uniqueKeysWithValues:
                    $0.failureBreakdown.map { ($0.key.rawValue, $0.value) })
            )
        }
    }
}

private struct EncodableCategoryStats: Codable {
    let schemaVersion: String
    let stats: [Wrapper]

    struct Wrapper: Codable {
        let category: String
        let phase: String
        let severity: String
        let count: Int
    }

    init(stats: [CategoryFrequencyStats]) {
        self.schemaVersion = "1"
        self.stats = stats.map {
            Wrapper(
                category: $0.category.rawValue,
                phase: $0.phase.rawValue,
                severity: $0.severity.rawValue,
                count: $0.count
            )
        }
    }
}

private struct EncodableModelStats: Codable {
    let schemaVersion: String
    let stats: [Wrapper]

    struct Wrapper: Codable {
        let provider: String
        let modelName: String
        let totalRuns: Int
        let completedCount: Int
        let failedCount: Int
        let cancelledCount: Int
        let interruptedCount: Int
        let successRate: Double
        let avgDurationMs: Int?
    }

    init(stats: [ModelReliabilityStats]) {
        self.schemaVersion = "1"
        self.stats = stats.map {
            Wrapper(
                provider: $0.provider,
                modelName: $0.modelName,
                totalRuns: $0.totalRuns,
                completedCount: $0.completedCount,
                failedCount: $0.failedCount,
                cancelledCount: $0.cancelledCount,
                interruptedCount: $0.interruptedCount,
                successRate: $0.successRate,
                avgDurationMs: $0.avgDurationMs
            )
        }
    }
}

private struct EncodableCBStats: Codable {
    let schemaVersion: String
    let totalTrips: Int
    let tripsByCategory: [String: Int]
    let topOffendingTools: [ToolCount]
    let windowStart: Date
    let windowEnd: Date

    struct ToolCount: Codable {
        let tool: String
        let count: Int
    }

    init(stats: CircuitBreakerStats) {
        self.schemaVersion = "1"
        self.totalTrips = stats.totalTrips
        self.tripsByCategory = Dictionary(uniqueKeysWithValues:
            stats.tripsByCategory.map { ($0.key.rawValue, $0.value) })
        self.topOffendingTools = stats.topOffendingTools.map {
            ToolCount(tool: $0.tool, count: $0.count)
        }
        self.windowStart = stats.windowStart
        self.windowEnd = stats.windowEnd
    }
}

private struct EncodableHardware: Codable {
    let totalRAMBytes: UInt64
    let availableRAMBytes: UInt64
    let chipFamily: String
    let gpuCoreCount: Int
    let effectiveBudgetBytes: UInt64
    let formattedTotalRAM: String
    let formattedAvailableRAM: String
}

private struct EncodableAppVersion: Codable {
    let shortVersion: String
    let buildNumber: String
    let bundleIdentifier: String
    let osVersion: String
    let osName: String
}

private struct EncodableRating: Codable {
    let rating: String?
}

/// Type-erased wrapper for UserDefaults values. Handles Bool/Int/Double/String
/// natively; anything else gets stringified via `String(describing:)` so the
/// JSON encoder doesn't throw on unknown types.
/// Internal (was `private`) so the export allowlist's extraction seam can return it and be
/// tested. An inert Codable box — widening its visibility carries no privacy meaning.
struct AnyCodable: Codable {
    let value: Any

    init(value: Any) { self.value = value }

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let b = try? container.decode(Bool.self) { self.value = b; return }
        if let i = try? container.decode(Int.self) { self.value = i; return }
        if let d = try? container.decode(Double.self) { self.value = d; return }
        if let s = try? container.decode(String.self) { self.value = s; return }
        self.value = "null"
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch value {
        case let b as Bool:    try container.encode(b)
        case let i as Int:     try container.encode(i)
        case let d as Double:  try container.encode(d)
        case let s as String:  try container.encode(s)
        default:               try container.encode(String(describing: value))
        }
    }
}

