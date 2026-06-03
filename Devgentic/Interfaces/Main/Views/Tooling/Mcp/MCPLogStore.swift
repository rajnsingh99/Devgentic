//
//  MCPLogStore.swift
//  Devgentic
//
//  Structured, per-source ring buffer of MCP log entries. Two roles:
//
//   1. Backs the bug-report bundle (Phase 8) — when the user clicks "Report
//      Issue" we want the last N events scoped to that one MCP server, not
//      the whole app's `os.log` firehose.
//
//   2. Powers the per-server logs panel (future) — same query path.
//
//  This lives alongside `DGLogger`; calls to `MCPLog.*` write to both. The
//  ring buffer is in-memory (cap 200/source) so we don't need SQL migrations
//  or retention sweeps. Lost on app restart, which is fine — bug reports are
//  raised live, while the user is reproducing.
//
//  Secret-handling: helpers run inputs through `MCPRedaction` before writing
//  here. Never log token bodies; only "shape" (issuer, scopes, expiry).
//

import Foundation
import os

private let logger = DGLogger(category: "MCP")

/// One entry in the per-source ring buffer. Encodable so the Phase 8 bundler
/// can write the buffer out as JSON in the report ZIP.
struct MCPLogEntry: Codable, Hashable, Sendable {

    /// Wall-clock time the event happened. ISO8601 strings in JSON for
    /// human-readability of the bundle.
    let timestamp: Date

    /// Coarse stage in the MCP lifecycle. Lets the bundler / future logs UI
    /// group entries by phase.
    let phase: Phase

    /// Severity. `.info` for happy-path beats, `.warn` for retryable issues,
    /// `.error` for terminal failures or impacted user flows.
    let level: Level

    /// Free-form short message. Caller-redacted before passing in.
    let message: String

    /// Optional latency for this step in milliseconds. Useful for finding
    /// "why is this server slow" in reports without scrolling through the
    /// whole bundle.
    let latencyMS: Int?

    /// Optional supplementary key/value fields. Caller-redacted.
    let fields: [String: String]?

    enum Phase: String, Codable, Hashable, Sendable {
        case connect          // initial handshake / handshake retry
        case listTools        // tools/list call
        case callTool         // tools/call call
        case listChanged      // tools/list_changed handling
        case oauthDiscover    // .well-known fetch
        case oauthRegister    // dynamic client registration
        case oauthAuthorize   // browser flow + redirect capture
        case oauthExchange    // code → token POST
        case oauthRefresh     // refresh token POST
        case transport        // stdio / HTTP transport-layer events
        case lifecycle        // session lifecycle (disconnect, health monitor)
    }

    enum Level: String, Codable, Hashable, Sendable {
        case info, warn, error
    }
}

/// Per-source ring buffer + helper API. Singleton; main-actor only because
/// it interacts with `@Observable` UI state in the future logs panel.
@MainActor
final class MCPLogStore {

    static let shared = MCPLogStore()

    /// Cap per source. 200 entries × ~300 bytes ≈ 60 KB/source — small
    /// enough to keep many servers in memory without churn.
    static let perSourceLimit = 200

    private var buffers: [UUID: [MCPLogEntry]] = [:]

    private init() {}

    // MARK: - Public API

    /// Append one entry, scoped to a source. Trims to the per-source cap.
    /// Pass a nil `sourceID` for events that don't belong to a specific
    /// server (e.g. a global discovery probe before the source exists);
    /// those are stored under a sentinel UUID.
    func append(_ entry: MCPLogEntry, sourceID: UUID?) {
        let key = sourceID ?? Self.unscopedSourceID
        var buffer = buffers[key] ?? []
        buffer.append(entry)
        if buffer.count > Self.perSourceLimit {
            buffer.removeFirst(buffer.count - Self.perSourceLimit)
        }
        buffers[key] = buffer
    }

    /// All entries for one source, oldest first. Used by the bug-report
    /// bundler in Phase 8.
    func entries(forSourceID sourceID: UUID) -> [MCPLogEntry] {
        return buffers[sourceID] ?? []
    }

    /// All buffered entries across every source. Reserved for the future
    /// global logs panel.
    func allEntries() -> [(sourceID: UUID, entries: [MCPLogEntry])] {
        return buffers.map { ($0.key, $0.value) }
    }

    /// Drop the buffer for a deleted source. Called from `MCPToolStore.deleteTool`
    /// so the bug-report bundle doesn't keep showing entries for servers
    /// that no longer exist.
    func purge(sourceID: UUID) {
        buffers.removeValue(forKey: sourceID)
    }

    /// Sentinel for events that aren't tied to a specific source — e.g. an
    /// auto-detect probe during the Add MCP form before the source ID exists.
    /// Encoded as the all-zeroes UUID so it sorts to the start of the bundle.
    static let unscopedSourceID: UUID = UUID(uuid: (0,0,0,0, 0,0,0,0, 0,0,0,0, 0,0,0,0))
}

// MARK: - MCPLog helpers

/// Thin façade: every call writes to `DGLogger` (so Console.app sees it) AND
/// `MCPLogStore` (so the bug bundle and future logs UI see it).
enum MCPLog {

    static func info(
        _ phase: MCPLogEntry.Phase,
        _ message: String,
        sourceID: UUID? = nil,
        latencyMS: Int? = nil,
        fields: [String: String]? = nil
    ) {
        let safeMessage = redact(message: message, fields: fields)
        logger.info("[\(phase.rawValue)] \(safeMessage)")
        Task { @MainActor in
            MCPLogStore.shared.append(
                MCPLogEntry(
                    timestamp: Date(),
                    phase: phase,
                    level: .info,
                    message: safeMessage,
                    latencyMS: latencyMS,
                    fields: fields
                ),
                sourceID: sourceID
            )
        }
    }

    static func warn(
        _ phase: MCPLogEntry.Phase,
        _ message: String,
        sourceID: UUID? = nil,
        latencyMS: Int? = nil,
        fields: [String: String]? = nil
    ) {
        let safeMessage = redact(message: message, fields: fields)
        logger.warning("[\(phase.rawValue)] \(safeMessage)")
        Task { @MainActor in
            MCPLogStore.shared.append(
                MCPLogEntry(
                    timestamp: Date(),
                    phase: phase,
                    level: .warn,
                    message: safeMessage,
                    latencyMS: latencyMS,
                    fields: fields
                ),
                sourceID: sourceID
            )
        }
    }

    static func error(
        _ phase: MCPLogEntry.Phase,
        _ message: String,
        sourceID: UUID? = nil,
        latencyMS: Int? = nil,
        fields: [String: String]? = nil
    ) {
        let safeMessage = redact(message: message, fields: fields)
        logger.error("[\(phase.rawValue)] \(safeMessage)")
        Task { @MainActor in
            MCPLogStore.shared.append(
                MCPLogEntry(
                    timestamp: Date(),
                    phase: phase,
                    level: .error,
                    message: safeMessage,
                    latencyMS: latencyMS,
                    fields: fields
                ),
                sourceID: sourceID
            )
        }
    }

    // MARK: - Redaction guard

    /// Defensive redaction. Even though every call site is supposed to feed
    /// us pre-redacted strings, the stakes are too high to rely on that —
    /// run the message through known secret patterns just in case. Field
    /// values aren't redacted because they're caller-typed (caller must
    /// promise they're safe).
    private static func redact(message: String, fields: [String: String]?) -> String {
        // Strip obvious "token=..." / "Authorization: Bearer ..." patterns.
        var msg = message

        // Bearer token bodies (32+ alphanum/-/_/. chars)
        if let regex = try? NSRegularExpression(pattern: "Bearer\\s+[A-Za-z0-9\\-_\\.]{20,}") {
            let range = NSRange(msg.startIndex..<msg.endIndex, in: msg)
            msg = regex.stringByReplacingMatches(
                in: msg, options: [], range: range, withTemplate: "Bearer <REDACTED>"
            )
        }
        // ?token=… / &api_key=… in URLs
        if let regex = try? NSRegularExpression(
            pattern: "([?&](?:token|api[_-]?key|access[_-]?token|refresh[_-]?token|secret|password)=)[^&\\s]+",
            options: [.caseInsensitive]
        ) {
            let range = NSRange(msg.startIndex..<msg.endIndex, in: msg)
            msg = regex.stringByReplacingMatches(
                in: msg, options: [], range: range, withTemplate: "$1<REDACTED>"
            )
        }
        return msg
    }
}
