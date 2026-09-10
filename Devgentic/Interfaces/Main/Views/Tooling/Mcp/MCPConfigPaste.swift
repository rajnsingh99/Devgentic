// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2026 Raj Singh
//
//  MCPConfigPaste.swift
//  Devgentic
//
//  Created 2026-08-02 — parsing a pasted `mcpServers` block.
//
//  Pasting the JSON block from a server's README is how most servers actually get added, and
//  it is the path where a whole configuration can be silently altered: `ServerDefinition`
//  deliberately carries no secrets, so it models env as `envKeys` (names only), while every
//  README in the wild ships `"env": { "API_KEY": "sk-…" }` — a key→VALUE map. `Codable`
//  ignores an unknown key, so a working config used to produce a server with its credentials
//  quietly stripped, which then failed to authenticate with no hint as to why.
//
//  Extracted from `AddMCPServerView` on 2026-08-02, unchanged in behaviour except where
//  noted below. It lived inside the view as two private methods, which meant the one parse
//  in the subsystem that can silently discard credentials was the one thing no test could
//  reach. `MCPHarness/ConfigMatrixTests` now drives it directly.
//

import Foundation

private let logger = DGLogger(category: "MCPConfigPaste")

/// Everything a pasted `mcpServers` block contains, including the parts `ServerDefinition`
/// does not model.
struct MCPPastedConfiguration: Sendable {

    /// The key the server was filed under in the `mcpServers` object.
    let serverName: String

    /// The typed definition — command/args/url/auth/transport.
    let definition: ServerDefinition

    /// `env` as key→VALUE, read straight off the raw JSON. `definition.envKeys` holds only
    /// the names, by design; these are the values that would otherwise be lost.
    let envValues: [String: String]

    /// The raw `headers` map, if any.
    let headers: [String: String]

    /// A bearer token lifted from an `Authorization: Bearer …` header when the block declared
    /// no `auth` of its own. The other common README shape.
    let inferredBearerToken: String?

    /// Header names Devgentic cannot represent and therefore will NOT send. Reported rather
    /// than dropped in silence — a server that needs one of these will fail to authenticate,
    /// and the user has no other way to find out why.
    let unrepresentableHeaders: [String]

    /// Other server keys in the same block, ignored because the form configures one server.
    let ignoredServerNames: [String]
}

enum MCPConfigPaste {

    enum ParseError: LocalizedError {
        case notUTF8
        case malformedJSON(String)
        case noServers

        var errorDescription: String? {
            switch self {
            case .notUTF8:
                return "The pasted configuration is not valid UTF-8 text."
            case .malformedJSON(let detail):
                return "The pasted configuration is not a valid `mcpServers` block. \(detail)"
            case .noServers:
                return "The pasted configuration contains no servers."
            }
        }
    }

    /// Parses a pasted `mcpServers` block.
    ///
    /// - Parameter preferredServerName: which entry to take when the block holds several.
    ///   Nil selects the alphabetically first — **deterministically**. `mcpServers.first` on
    ///   a Dictionary was previously used, and Swift's Dictionary ordering is seeded per
    ///   process, so pasting a two-server block configured a *different* server on different
    ///   launches with nothing to indicate a choice had been made.
    static func parse(
        _ text: String,
        preferredServerName: String? = nil
    ) throws -> MCPPastedConfiguration {

        guard let data = text.data(using: .utf8) else { throw ParseError.notUTF8 }

        let configuration: MCPConfiguration
        do {
            configuration = try JSONDecoder().decode(MCPConfiguration.self, from: data)
        } catch {
            throw ParseError.malformedJSON(error.localizedDescription)
        }

        guard !configuration.mcpServers.isEmpty else { throw ParseError.noServers }

        let names = configuration.mcpServers.keys.sorted()
        let chosen = preferredServerName.flatMap { configuration.mcpServers[$0] != nil ? $0 : nil }
            ?? names[0]
        guard let definition = configuration.mcpServers[chosen] else { throw ParseError.noServers }

        let ignored = names.filter { $0 != chosen }
        if !ignored.isEmpty {
            logger.warning("""
                [MCP-CONFIG] The pasted block defines \(names.count) servers; configuring \
                '\(chosen)' and IGNORING \(ignored.joined(separator: ", ")). Those servers are \
                not added — paste them one at a time to configure each.
                """)
        }

        let sidecar = parseSidecarFields(rawJSON: data, serverName: chosen)

        var inferredBearer: String? = nil
        if case .none = definition.auth,
           let authorization = sidecar.headers.first(where: { $0.key.lowercased() == "authorization" }),
           authorization.value.lowercased().hasPrefix("bearer ") {
            inferredBearer = String(authorization.value.dropFirst("bearer ".count))
        }

        let unrepresentable = sidecar.headers.keys
            .filter { $0.lowercased() != "authorization" }
            .sorted()

        if !unrepresentable.isEmpty {
            logger.warning("""
                [MCP-CONFIG] Pasted config for '\(chosen)' carries \(unrepresentable.count) \
                header(s) Devgentic cannot represent (\(unrepresentable.joined(separator: ", "))) \
                — they will NOT be sent, and a server that requires one will fail to \
                authenticate. Only Authorization/bearer and a single API-key header are \
                supported.
                """)
        }

        logger.info("""
            [MCP-CONFIG] Parsed pasted config for '\(chosen)': \
            \(definition.command.map { "command '\($0)' with \(definition.args?.count ?? 0) arg(s)" } ?? "remote URL") \
            · \(sidecar.env.count) env value(s) · \(sidecar.headers.count) header(s) \
            · bearer inferred: \(inferredBearer != nil).
            """)

        return MCPPastedConfiguration(
            serverName: chosen,
            definition: definition,
            envValues: sidecar.env,
            headers: sidecar.headers,
            inferredBearerToken: inferredBearer,
            unrepresentableHeaders: unrepresentable,
            ignoredServerNames: ignored
        )
    }

    /// Fields the standard `mcpServers` block carries that `ServerDefinition` deliberately
    /// does not model (it holds no secrets). Read straight off the raw JSON so a pasted
    /// config keeps its credentials instead of losing them to Codable's unknown-key handling.
    private static func parseSidecarFields(
        rawJSON: Data,
        serverName: String
    ) -> (env: [String: String], headers: [String: String]) {
        guard let root = try? JSONSerialization.jsonObject(with: rawJSON) as? [String: Any],
              let servers = root["mcpServers"] as? [String: Any],
              let server = servers[serverName] as? [String: Any] else {
            return ([:], [:])
        }
        let env = (server["env"] as? [String: Any])?.compactMapValues { $0 as? String } ?? [:]
        let headers = (server["headers"] as? [String: Any])?.compactMapValues { $0 as? String } ?? [:]
        return (env, headers)
    }
}
