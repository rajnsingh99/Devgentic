// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2026 Raj Singh
//
//  MCPBugReportBundler.swift
//  Devgentic
//
//  Builds the JSON bundle a user attaches when reporting an MCP issue.
//  Pulls the per-source log buffer from `MCPLogStore`, the (already-secret-
//  free) server definition, the live connection state, and lightweight
//  system info. URL/args fields are run through `MCPRedaction` once more
//  on the way out as a defensive belt-and-braces measure.
//
//  No secret material is ever included — env values, tokens, OAuth bundles
//  all live in Keychain and are never read here.
//

import Foundation
import os

private let logger = DGLogger(category: "MCPBugReportBundler")

/// Top-level bundle payload — one JSON document the user can attach to an
/// email / GitHub issue / Discord message.
struct MCPBugReport: Codable {
    let schemaVersion: Int        // bump when we change the shape
    let generatedAt: Date
    let app: AppInfo
    let system: SystemInfo
    let server: ServerSnapshot
    let userDescription: String?
    let logEntries: [MCPLogEntry]
}

extension MCPBugReport {

    struct AppInfo: Codable {
        let name: String
        let version: String           // CFBundleShortVersionString
        let build: String             // CFBundleVersion
    }

    struct SystemInfo: Codable {
        let macOSVersion: String
        let arch: String              // arm64 / x86_64
        let locale: String
    }

    /// Snapshot of the offending source. `serverDefinitionJSON` is the same
    /// JSON we persist in SwiftData, post-redaction. We include it as an
    /// embedded JSON string rather than nested object so it round-trips
    /// through diff tools cleanly.
    struct ServerSnapshot: Codable {
        let sourceID: String
        let serverName: String
        let connectionState: String
        let auth: String
        let serverDefinitionJSON: String
        let toolNames: [String]
    }
}

@MainActor
struct MCPBugReportBundler {

    /// Build a bug report for one source. Synchronous — all inputs are
    /// already in memory.
    static func build(
        for source: ToolSource,
        connectionState: MCPConnectionState,
        userDescription: String?
    ) -> MCPBugReport {
        let app = MCPBugReport.AppInfo(
            name: Bundle.main.object(forInfoDictionaryKey: "CFBundleName") as? String ?? "Devgentic",
            version: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?",
            build: Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "?"
        )

        let processInfo = ProcessInfo.processInfo
        let macOSVersion = processInfo.operatingSystemVersion
        let arch: String = {
            #if arch(arm64)
            return "arm64"
            #elseif arch(x86_64)
            return "x86_64"
            #else
            return "unknown"
            #endif
        }()

        let system = MCPBugReport.SystemInfo(
            macOSVersion: "\(macOSVersion.majorVersion).\(macOSVersion.minorVersion).\(macOSVersion.patchVersion)",
            arch: arch,
            locale: Locale.current.identifier
        )

        // Re-encode the persisted server definition. Even though it's
        // already secret-free by construction, redact URL fields one more
        // time just in case the user pasted something with userinfo or
        // ?api_key= in it before saving.
        let redactedDefinition = redact(definition: source.serverDefinition)
        let definitionJSON: String = {
            guard let def = redactedDefinition else { return "null" }
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            guard let data = try? encoder.encode(def),
                  let str = String(data: data, encoding: .utf8) else { return "null" }
            return str
        }()

        let serverSnapshot = MCPBugReport.ServerSnapshot(
            sourceID: source.id.uuidString,
            serverName: source.serverName,
            connectionState: describe(connectionState),
            auth: redactedDefinition?.auth.displayLabel ?? "—",
            serverDefinitionJSON: definitionJSON,
            toolNames: source.tools.map(\.name)
        )

        let entries = MCPLogStore.shared.entries(forSourceID: source.id)

        return MCPBugReport(
            schemaVersion: 1,
            generatedAt: Date(),
            app: app,
            system: system,
            server: serverSnapshot,
            userDescription: userDescription?.isEmpty == false ? userDescription : nil,
            logEntries: entries
        )
    }

    /// Encode the report to pretty-printed JSON. Used both by the preview
    /// view and the save-to-disk path.
    static func encode(_ report: MCPBugReport) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        return try encoder.encode(report)
    }

    // MARK: - Defensive redaction pass

    /// Re-emit a `ServerDefinition` with its URL field redacted via the same
    /// helper used for log lines. Args/command stay as-is — they're already
    /// args (no env values) and the user typed them.
    private static func redact(definition: ServerDefinition?) -> ServerDefinition? {
        guard let def = definition else { return nil }
        let url: String? = def.url.map { MCPRedaction.redact(url: $0) }
        return ServerDefinition(
            command: def.command,
            args: def.args.map { MCPRedaction.redact(arguments: $0) },
            envKeys: def.envKeys,
            url: url,
            auth: def.auth
        )
    }

    private static func describe(_ state: MCPConnectionState) -> String {
        switch state {
        case .disconnected:                return "disconnected"
        case .connecting:                   return "connecting"
        case .connected:                    return "connected"
        case .reconnecting(let attempt):    return "reconnecting(attempt=\(attempt))"
        // `msg` is arbitrary free text — usually the server's own stderr, which commonly
        // echoes its configuration on a failed start. `redact(url:)` was the wrong tool:
        // it parses as a URL, fails on prose, and returned the string untouched.
        case .error(let msg):               return "error(\(MCPRedaction.redact(text: msg)))"
        }
    }
}
