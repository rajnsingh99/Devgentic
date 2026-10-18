// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
//
//  DGLogger.swift
//  Devgentic
//
//  Created by Raj Singh.
//

import Foundation
import os

/// Ergonomic logging facade that writes to both `os.Logger` and the in-app ring buffer.
/// Create one per logical subsystem/category (mirrors the `os.Logger` pattern).
struct DGLogger: Sendable {

    // MARK: - Identity

    // Why: retyped literals drift from the bundle identifier, so Console and `log stream` filters would miss those logs.
    /// The subsystem the whole app logs under; the one place the string is decided.
    static let subsystem: String = Bundle.main.bundleIdentifier ?? "app.devgentic.macos"

    // MARK: - Identity (instance)

    /// Log subsystem — typically the app bundle ID. Inherited from `Bundle.main` by default.
    let subsystem: String

    /// Log category — the "what layer" label (e.g. "ReActAgentExecutor", "ToolMediator").
    let category: String

    /// Underlying `os.Logger` — OS-log writes always go here, never gated.
    private let osLogger: os.Logger

    // MARK: - Init

    init(subsystem: String = DGLogger.subsystem,
         category: String) {
        self.subsystem = subsystem
        self.category = category
        self.osLogger = Logger(subsystem: subsystem, category: category)
    }

    // MARK: - Log Methods
    // Why: the sanitizer redacts PII and secrets, not content: do not log message bodies (log lengths and ids instead).
    // Each method takes optional `metadata: [String: String]` (short strings; sanitized when written to the buffer).
    // `privacy: .public` keeps os_log readable; info and above are scrubbed by TelemetrySanitizer, debug/trace stay raw.

    /// Sanitize a message for egress (OS log + ring buffer) — applied to persisted levels only.
    private func sanitizedForEgress(_ message: String) -> String {
        TelemetrySanitizer.sanitizeFull(message, level: .standard)
    }

    /// Debug-level log. Goes to OS log ONLY — never buffered (per product decision:
    /// info-floor for the diagnostic ring). Raw (see the privacy note above).
    func debug(_ message: String, metadata: [String: String] = [:]) {
        osLogger.debug("\(message, privacy: .public)")
        // Not buffered.
    }

    /// Trace-level log — Apple's lowest level, below debug. Never buffered. Raw.
    /// Treated as an alias for debug at call sites; the OS log still sees .trace.
    func trace(_ message: String, metadata: [String: String] = [:]) {
        osLogger.trace("\(message, privacy: .public)")
        // Not buffered.
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

    /// Fault-level log: os.Logger's `.fault()` marks system-fault severity. The ring buffer maps it to the `.error` bucket
    /// (`LogLevel` has no separate fault tier); the OS log still sees fault severity.
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

    // Why: one consent switch and one floor: developer mode must not override the diagnostics opt-out or lower the floor.
    /// Whether a log at `level` is persisted to the ring buffer: warning and above, while diagnostics recording is enabled.
    /// Pure and static so the policy is unit-testable without touching UserDefaults.
    static func shouldPersist(level: LogLevel, diagnosticsEnabled: Bool) -> Bool {
        level >= .warning && diagnosticsEnabled
    }

    // MARK: - Full-content dumps (developer mode only)

    /// Whether verbatim-content dumps are permitted right now (developer mode).
    /// Callers must check this before building the payload: constructing a large string the logger then discards wastes work.
    static var contentDumpsEnabled: Bool {
        UserDefaults.standard.bool(forKey: AppSettings.developerModeKey)
    }

    // Why: an exception to "do not log message bodies": safe only because developer-mode `.debug` output is never persisted.
    /// Emits a multi-line block of verbatim content, chunked so the unified log does not truncate it.
    /// Gated on developer mode and routed through `.debug`, which is never written to the ring buffer.
    /// The content is raw (unsanitized) on purpose; chunks split on Characters, never UTF-8 bytes.
    func dumpBlock(_ tag: String, title: String, body: String, chunkSize: Int = 800) {
        guard Self.contentDumpsEnabled else { return }

        let parts = Self.chunk(body, size: chunkSize)
        debug("\(tag) ===== BEGIN \(title) — \(body.count) chars, \(parts.count) chunk(s) =====")
        for (offset, part) in parts.enumerated() {
            debug("\(tag) [\(offset + 1)/\(parts.count)] \(part)")
        }
        debug("\(tag) ===== END \(title) =====")
    }

    // Why: split on Characters, never UTF-8 bytes: byte slicing tears multi-byte characters apart at chunk seams.
    /// Splits `body` into log-sized pieces. Pure and `static` so the chunking contract is testable.
    /// Always returns at least one element, so callers can render "1/1" and an empty prompt is visibly empty.
    static func chunk(_ body: String, size: Int) -> [String] {
        // A zero or negative size from a call site would divide by zero / loop forever.
        let size = max(1, size)
        let chars = Array(body)
        guard !chars.isEmpty else { return ["<empty>"] }

        var parts: [String] = []
        var index = 0
        while index < chars.count {
            let end = min(index + size, chars.count)
            parts.append(String(chars[index..<end]))
            index = end
        }
        return parts
    }

    private func route(level: LogLevel, sanitizedMessage: String, metadata: [String: String]) {
        // One UserDefaults read per persisted log call instead of two — this runs on every
        // warning/error, so the removed developer-mode lookup is a small hot-path win as well.
        guard Self.shouldPersist(level: level,
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
