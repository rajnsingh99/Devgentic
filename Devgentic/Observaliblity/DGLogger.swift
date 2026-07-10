//
//  DGLogger.swift
//  Devgentic
//
//  Structured logging facade. Drop-in replacement for `os.Logger` that also
//  writes to `LogRecorder`'s ring buffer when developer mode is on, so logs
//  survive export to a bug-report bundle instead of living only in the OS log.
//
//  Design:
//    - Same ergonomic surface as `os.Logger`: `debug/info/notice/warning/error`.
//    - Every call writes to OS log (always — preserves existing developer workflow
//      of watching Console.app during builds).
//    - Above-floor calls (info+) additionally write to `LogRecorder` IFF developer
//      mode is on. Per the product decision, debug is NOT buffered — too noisy.
//    - Optional `metadata: [String: String]` parameter for structured attributes
//      that get JSON-encoded and attached to the LogEntry.
//    - Optional `error: AgentErrorCategory?` on warning/error calls — stamps the
//      canonical category so the Report Inspector can filter log entries by
//      the same taxonomy as SpanEvents.
//
//  Migration path:
//    - Existing `private let logger = Logger(subsystem:..., category:...)` call
//      sites keep working. No forced migration.
//    - New/updated code creates `private let logger = DGLogger(category: ...)` and
//      uses the same API — no call-site changes needed.
//    - Hot-path loggers (executor, provider, tool mediator) should be migrated
//      in a follow-up so their info/warning/error entries land in bug reports.
//

import Foundation
import os

/// Ergonomic logging facade that writes to both `os.Logger` and the in-app ring buffer.
/// Create one per logical subsystem/category (mirrors the `os.Logger` pattern).
struct DGLogger: Sendable {

    // MARK: - Identity

    /// Log subsystem — typically the app bundle ID. Inherited from `Bundle.main` by default.
    let subsystem: String

    /// Log category — the "what layer" label (e.g. "ReActAgentExecutor", "ToolMediator").
    let category: String

    /// Underlying `os.Logger` — OS-log writes always go here, never gated.
    private let osLogger: os.Logger

    // MARK: - Init

    init(subsystem: String = Bundle.main.bundleIdentifier ?? "com.devgentic.app",
         category: String) {
        self.subsystem = subsystem
        self.category = category
        self.osLogger = Logger(subsystem: subsystem, category: category)
    }

    // MARK: - Log Methods
    //
    // Each accepts an optional `metadata: [String: String]`. Values should be short
    // strings — JSON-stringify complex structures before passing in. Metadata is
    // sanitized at buffer-write time via TelemetrySanitizer.sanitizeFull(.standard).
    //
    // [M6] Privacy: DGLogger forces `privacy: .public` so os_log stays readable in Console
    // (its default would redact every dynamic value as `<private>`, defeating the
    // watch-Console-during-builds workflow). To keep that readability WITHOUT leaking secrets
    // into the unified log store / sysdiagnose, persisted levels (info and above) route their
    // message through TelemetrySanitizer BEFORE the os_log write — the same scrub the ring
    // buffer applies — so paths/emails/keys/tokens are stripped from both sinks, matching the
    // sanitization guarantee in PRIVACY.md. debug/trace stay raw: they are never persisted to
    // the log store, are the highest-frequency levels (regex cost matters), and are dev-only.
    // NOTE: the sanitizer is a PII/secret redactor, not a content redactor — free-form user or
    // model text still reaches the log if a call site interpolates it, so DON'T log message
    // bodies (log lengths/ids instead).

    /// Sanitize a message for egress (OS log + ring buffer) — applied to persisted levels only.
    private func sanitizedForEgress(_ message: String) -> String {
        TelemetrySanitizer.sanitizeFull(message, level: .standard)
    }

    /// Debug-level log. Goes to OS log ONLY — never buffered (per product decision:
    /// info-floor for the diagnostic ring). Raw (see the privacy note above).
    func debug(_ message: String, metadata: [String: String] = [:]) {
        osLogger.debug("\(message, privacy: .public)")
        // Intentionally NOT buffered.
    }

    /// Trace-level log — Apple's lowest level, below debug. Never buffered. Raw.
    /// Treated as an alias for debug at call sites; the OS log still sees .trace.
    func trace(_ message: String, metadata: [String: String] = [:]) {
        osLogger.trace("\(message, privacy: .public)")
        // Intentionally NOT buffered.
    }

    /// Generic bare log — os.Logger's `log(_:)` calls default to .default severity.
    /// We map to .notice which is Swift's closest equivalent (between info and warning).
    func log(_ message: String, metadata: [String: String] = [:]) {
        let sanitized = sanitizedForEgress(message)
        osLogger.log("\(sanitized, privacy: .public)")
        route(level: .notice, sanitizedMessage: sanitized, metadata: metadata)
    }

    /// Info-level log. Buffered if developer mode is on.
    func info(_ message: String, metadata: [String: String] = [:]) {
        let sanitized = sanitizedForEgress(message)
        osLogger.info("\(sanitized, privacy: .public)")
        route(level: .info, sanitizedMessage: sanitized, metadata: metadata)
    }

    /// Notice-level log (between info and warning). Buffered if developer mode is on.
    func notice(_ message: String, metadata: [String: String] = [:]) {
        let sanitized = sanitizedForEgress(message)
        osLogger.notice("\(sanitized, privacy: .public)")
        route(level: .notice, sanitizedMessage: sanitized, metadata: metadata)
    }

    /// Warning-level log. Optional canonical category stamps the entry so downstream
    /// filters/dashboards can aggregate by taxonomy.
    func warning(_ message: String,
                 category errorCategory: AgentErrorCategory? = nil,
                 metadata: [String: String] = [:]) {
        let sanitized = sanitizedForEgress(message)
        osLogger.warning("\(sanitized, privacy: .public)")
        var meta = metadata
        if let errorCategory {
            meta["agent_error_category"] = errorCategory.rawValue
            meta["agent_error_phase"] = errorCategory.phase.rawValue
        }
        route(level: .warning, sanitizedMessage: sanitized, metadata: meta)
    }

    /// Error-level log. Accepts an optional underlying Error (for error-type
    /// introspection) and an optional canonical category.
    func error(_ message: String,
               error: (any Error)? = nil,
               category errorCategory: AgentErrorCategory? = nil,
               metadata: [String: String] = [:]) {
        let sanitized = sanitizedForEgress(message)
        osLogger.error("\(sanitized, privacy: .public)")
        var meta = metadata
        if let errorCategory {
            meta["agent_error_category"] = errorCategory.rawValue
            meta["agent_error_phase"] = errorCategory.phase.rawValue
        }
        if let error {
            meta["error_type"] = String(describing: type(of: error))
            // NSError domain/code are useful forensic signals. localizedDescription
            // is already usually in `message`, so don't duplicate here.
            let nsError = error as NSError
            if !nsError.domain.isEmpty { meta["ns_domain"] = nsError.domain }
            if nsError.code != 0       { meta["ns_code"] = "\(nsError.code)" }
        }
        route(level: .error, sanitizedMessage: sanitized, metadata: meta)
    }

    /// Fault-level log. os.Logger's .fault() marks system-fault-level severity
    /// (process-crash-adjacent). In our ring buffer we map to the same .error
    /// bucket since there's no separate "fault" tier in LogLevel — but the OS
    /// log still sees it at fault severity.
    func fault(_ message: String, metadata: [String: String] = [:]) {
        let sanitized = sanitizedForEgress(message)
        osLogger.fault("\(sanitized, privacy: .public)")
        var meta = metadata
        meta["severity_override"] = "fault"
        route(level: .error, sanitizedMessage: sanitized, metadata: meta)
    }

    /// Critical-level log — severity between .error and .fault. Used for
    /// conditions that shouldn't happen in production but aren't quite fatal.
    /// Ring buffer uses .error bucket; OS log sees .critical.
    func critical(_ message: String, metadata: [String: String] = [:]) {
        let sanitized = sanitizedForEgress(message)
        osLogger.critical("\(sanitized, privacy: .public)")
        var meta = metadata
        meta["severity_override"] = "critical"
        route(level: .error, sanitizedMessage: sanitized, metadata: meta)
    }

    // MARK: - Ring-buffer routing

    /// Gated buffer write. Warning/error are always persisted (unless the user opted out
    /// of diagnostics), so a default-config user's incident is actually recorded; the
    /// verbose info/notice/debug stream stays gated behind developer mode (Gap #4). Both
    /// paths sanitize message + metadata, snapshot the current LogContext task-locals, and
    /// hand to LogRecorder.
    /// Whether a log at `level` should be persisted to the ring buffer: warning/error
    /// whenever diagnostics are enabled (default-on), everything in developer mode. Pure +
    /// static so the un-gating policy is unit-testable without touching UserDefaults (Gap #4).
    static func shouldPersist(level: LogLevel, developerMode: Bool, diagnosticsEnabled: Bool) -> Bool {
        developerMode || (level >= .warning && diagnosticsEnabled)
    }

    private func route(level: LogLevel, sanitizedMessage: String, metadata: [String: String]) {
        let devMode = UserDefaults.standard.bool(forKey: AppSettings.developerModeKey)
        guard Self.shouldPersist(level: level,
                                 developerMode: devMode,
                                 diagnosticsEnabled: AppSettings.diagnosticsRecordingEnabled) else { return }

        // `sanitizedMessage` is already scrubbed by the caller (same TelemetrySanitizer pass
        // applied to the os_log egress), so the buffer and the OS log stay consistent.

        // Sanitize metadata values individually (key names trusted — they come from
        // DGLogger call sites, not user input).
        let metadataJSON: String? = {
            guard !metadata.isEmpty else { return nil }
            var sanitized: [String: String] = [:]
            for (k, v) in metadata {
                sanitized[k] = TelemetrySanitizer.sanitizeFull(v, level: .standard)
            }
            guard let data = try? JSONSerialization.data(withJSONObject: sanitized, options: [.sortedKeys]) else {
                return nil
            }
            return String(data: data, encoding: .utf8)
        }()

        let entry = LogEntry(
            timestamp: Date(),
            level: level,
            subsystem: subsystem,
            category: category,
            message: sanitizedMessage,
            traceID: LogContext.traceID,
            spanID: LogContext.spanID,
            phase: LogContext.phase,
            metadataJSON: metadataJSON
        )

        Task {
            await LogRecorder.shared.record(entry)
        }
    }
}
