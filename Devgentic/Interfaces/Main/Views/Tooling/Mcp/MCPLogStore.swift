// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
//
//  MCPLogStore.swift
//  Devgentic
//
//  Created by Raj Singh.
//

import Foundation
import os

private let logger = DGLogger(category: "MCP")

/// One entry in the per-source ring buffer; Encodable so the bug-report bundler can write the buffer out as JSON.
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

    /// Appends one entry scoped to a source, trimming to the per-source cap.
    /// A nil `sourceID` is for events that belong to no specific server (e.g. a discovery probe before the source
    /// exists); those are stored under a sentinel UUID.
    func append(_ entry: MCPLogEntry, sourceID: UUID?) {
        let key = sourceID ?? Self.unscopedSourceID
        var buffer = buffers[key] ?? []
        buffer.append(entry)
        if buffer.count > Self.perSourceLimit {
            buffer.removeFirst(buffer.count - Self.perSourceLimit)
        }
        buffers[key] = buffer
    }

    /// All entries for one source, oldest first; used by the bug-report bundler.
    func entries(forSourceID sourceID: UUID) -> [MCPLogEntry] {
        return buffers[sourceID] ?? []
    }

    /// All buffered entries across every source. Reserved for the future
    /// global logs panel.
    func allEntries() -> [(sourceID: UUID, entries: [MCPLogEntry])] {
        return buffers.map { ($0.key, $0.value) }
    }

    /// Drops the buffer for a deleted source. Called from `MCPToolStore.deleteTool` so the bug-report bundle
    /// doesn't keep showing entries for deleted servers.
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

    /// Defensive redaction: runs the message through known secret patterns even though call sites should pass
    /// pre-redacted strings. Field values aren't redacted: they're caller-typed and the caller promises they're safe.
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
