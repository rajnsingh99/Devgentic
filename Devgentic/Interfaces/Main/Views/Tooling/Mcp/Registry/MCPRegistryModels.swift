// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2026 Raj Singh
//
//  MCPRegistryModels.swift
//  Devgentic
//
//  Created 2026-08-01 — decoding for the official MCP Registry
//  (https://registry.modelcontextprotocol.io, API frozen at v0.1).
//
//  The registry is a DIRECTORY, not a host or a proxy: it stores metadata and pointers to
//  where servers are published (npm, PyPI, OCI) or hosted (a vendor URL). Nothing here ever
//  routes a tool call. An entry becomes either:
//
//    • a `packages` entry  → a local stdio server we launch as a child process, and whose
//                            package the RUNTIME downloads into its own cache on first run
//    • a `remotes` entry   → a URL we talk to over HTTPS; nothing is downloaded
//
//  That distinction decides whether code runs on the user's machine or their data leaves it,
//  so it is surfaced as the first thing on every row rather than buried in a detail view.
//
//  Decoding is DELIBERATELY LENIENT throughout. Registry entries are third-party data with
//  wide variation, and a strict decoder would silently drop servers from the list — the
//  exact failure mode that made `ToolParameters` swallow MCP tools before it was fixed.
//

import Foundation

// MARK: - Response envelope

/// `GET /v0/servers` → `{ "servers": [ { "server": {...}, "_meta": {...} } ], "metadata": {...} }`
struct MCPRegistryResponse: Decodable {
    let servers: [MCPRegistryEnvelope]
    let metadata: Metadata?

    struct Metadata: Decodable {
        let nextCursor: String?
        let count: Int?
    }
}

struct MCPRegistryEnvelope: Decodable {
    let server: MCPRegistryServer
    /// Registry-side status. `isLatest` is the only reliable way to pick one row per server:
    /// the API returns EVERY published version, so an unfiltered list contains the same
    /// server several times.
    let isLatest: Bool

    private enum CodingKeys: String, CodingKey {
        case server
        case meta = "_meta"
    }

    /// `_meta` is keyed by an extension namespace rather than being a flat object, so the
    /// flag has to be dug out: `_meta["io.modelcontextprotocol.registry/official"].isLatest`.
    private enum MetaKeys: String, CodingKey {
        case official = "io.modelcontextprotocol.registry/official"
    }

    private struct OfficialMeta: Decodable {
        let isLatest: Bool?
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.server = try container.decode(MCPRegistryServer.self, forKey: .server)

        // Absent means "assume latest": better to show a server once too often than to
        // filter every row out because the metadata shape moved.
        let meta = try? container.nestedContainer(keyedBy: MetaKeys.self, forKey: .meta)
        let official = try? meta?.decode(OfficialMeta.self, forKey: .official)
        self.isLatest = official?.isLatest ?? true
    }
}

// MARK: - Server entry

struct MCPRegistryServer: Decodable, Identifiable, Hashable {

    /// Reverse-DNS identity, e.g. `io.github.owner/repo`. Unique per server in the registry.
    let name: String
    /// Human-readable name. Often absent — fall back to the last path component of `name`.
    let title: String?
    let description: String
    let version: String?

    let packages: [MCPRegistryPackage]
    let remotes: [MCPRegistryRemote]

    var id: String { name }

    /// What the user sees. Registry names are reverse-DNS and unreadable as labels.
    var displayName: String {
        if let title, !title.isEmpty { return title }
        let tail = name.split(separator: "/").last.map(String.init) ?? name
        return tail
            .replacingOccurrences(of: "-", with: " ")
            .replacingOccurrences(of: "_", with: " ")
            .capitalized
    }

    /// The publishing namespace, shown under the name so the user can judge provenance.
    var publisher: String {
        name.split(separator: "/").first.map(String.init) ?? name
    }

    /// The package we would actually launch, if any. First wins — the registry lists them in
    /// the publisher's preferred order.
    var primaryPackage: MCPRegistryPackage? { packages.first }
    var primaryRemote: MCPRegistryRemote? { remotes.first }

    /// A local entry runs code on this machine; a remote one does not. Local is checked
    /// first: an entry offering both is safer to run locally than to send data to.
    var isLocal: Bool { primaryPackage != nil }
    var isRemote: Bool { packages.isEmpty && primaryRemote != nil }

    /// Entries with neither are metadata-only (documentation stubs, unpublished drafts).
    /// They are filtered out of the browse list — there is nothing to connect to.
    var isConnectable: Bool { primaryPackage != nil || primaryRemote != nil }

    private enum CodingKeys: String, CodingKey {
        case name, title, description, version, packages, remotes
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.name = (try? container.decode(String.self, forKey: .name)) ?? ""
        self.title = try? container.decode(String.self, forKey: .title)
        self.description = (try? container.decode(String.self, forKey: .description)) ?? ""
        self.version = try? container.decode(String.self, forKey: .version)
        // Per-element leniency: one malformed package must not discard the whole server.
        self.packages = (try? container.decode([MCPRegistryPackage].self, forKey: .packages)) ?? []
        self.remotes = (try? container.decode([MCPRegistryRemote].self, forKey: .remotes)) ?? []
    }
}

// MARK: - Package (local stdio server)

struct MCPRegistryPackage: Decodable, Hashable {

    /// `npm`, `pypi`, `oci`, `nuget`, …
    let registryType: String
    /// The package name as published, e.g. `@modelcontextprotocol/server-filesystem`.
    let identifier: String
    let version: String?
    /// The launcher the publisher expects: `npx`, `uvx`, `docker`, …
    let runtimeHint: String?
    /// Arguments for the RUNTIME (e.g. `-y` for npx), before the package name.
    let runtimeArguments: [MCPRegistryArgument]
    /// Arguments for the PACKAGE itself, after the package name.
    let packageArguments: [MCPRegistryArgument]
    let environmentVariables: [MCPRegistryEnvironmentVariable]

    /// The runtime we must find on PATH before this entry can be offered at all.
    /// Falls back to the conventional launcher for the registry when unstated.
    var effectiveRuntime: String {
        if let runtimeHint, !runtimeHint.isEmpty { return runtimeHint }
        switch registryType.lowercased() {
        case "npm":    return "npx"
        case "pypi":   return "uvx"
        case "oci":    return "docker"
        default:       return ""
        }
    }

    /// Pinned package spec. Pinning matters: `npx -y pkg` re-resolves "latest" on every
    /// launch, so without the version the code the user reviewed is not necessarily the
    /// code that runs a week later.
    var pinnedIdentifier: String {
        guard let version, !version.isEmpty else { return identifier }
        switch registryType.lowercased() {
        case "npm":  return "\(identifier)@\(version)"
        case "pypi": return "\(identifier)==\(version)"
        case "oci":  return "\(identifier):\(version)"
        default:     return identifier
        }
    }

    private enum CodingKeys: String, CodingKey {
        case registryType, identifier, version, runtimeHint
        case runtimeArguments, packageArguments, environmentVariables
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.registryType = (try? container.decode(String.self, forKey: .registryType)) ?? ""
        self.identifier = (try? container.decode(String.self, forKey: .identifier)) ?? ""
        self.version = try? container.decode(String.self, forKey: .version)
        self.runtimeHint = try? container.decode(String.self, forKey: .runtimeHint)
        self.runtimeArguments = (try? container.decode([MCPRegistryArgument].self, forKey: .runtimeArguments)) ?? []
        self.packageArguments = (try? container.decode([MCPRegistryArgument].self, forKey: .packageArguments)) ?? []
        self.environmentVariables = (try? container.decode([MCPRegistryEnvironmentVariable].self, forKey: .environmentVariables)) ?? []
    }
}

/// One argv entry. `positional` contributes its value; `named` contributes `name` and then
/// its value, when it has one.
struct MCPRegistryArgument: Decodable, Hashable {
    let type: String?
    let name: String?
    let value: String?
    let isRequired: Bool?
    let description: String?

    /// Flattens to argv. Empty when the argument carries nothing concrete — a
    /// user-supplied placeholder with no default belongs in the form, not the command.
    var argvComponents: [String] {
        if type?.lowercased() == "named", let name, !name.isEmpty {
            guard let value, !value.isEmpty else { return [name] }
            return [name, value]
        }
        guard let value, !value.isEmpty else { return [] }
        return [value]
    }

    private enum CodingKeys: String, CodingKey {
        case type, name, value, isRequired, description
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.type = try? container.decode(String.self, forKey: .type)
        self.name = try? container.decode(String.self, forKey: .name)
        self.value = try? container.decode(String.self, forKey: .value)
        self.isRequired = try? container.decode(Bool.self, forKey: .isRequired)
        self.description = try? container.decode(String.self, forKey: .description)
    }
}

/// A value the user must supply. `isRequired` and `isSecret` drive form validation and
/// whether the field is masked — the registry telling us this is the main reason a
/// registry-prefilled form beats typing a command by hand.
struct MCPRegistryEnvironmentVariable: Decodable, Hashable, Identifiable {
    let name: String
    let description: String?
    let isRequired: Bool
    let isSecret: Bool
    let defaultValue: String?

    var id: String { name }

    private enum CodingKeys: String, CodingKey {
        case name, description, isRequired, isSecret
        case defaultValue = "default"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.name = (try? container.decode(String.self, forKey: .name)) ?? ""
        self.description = try? container.decode(String.self, forKey: .description)
        self.isRequired = (try? container.decode(Bool.self, forKey: .isRequired)) ?? false
        self.isSecret = (try? container.decode(Bool.self, forKey: .isSecret)) ?? false
        self.defaultValue = try? container.decode(String.self, forKey: .defaultValue)
    }
}

// MARK: - Remote (hosted server)

struct MCPRegistryRemote: Decodable, Hashable {
    /// `streamable-http` or the deprecated `sse`.
    let type: String?
    let url: String

    /// Maps the registry's transport name onto our own setting. Anything that is not
    /// explicitly non-streaming gets the standard, which is the safe default: a server that
    /// supports streaming works either way, one that needs it only works this way.
    var transportMode: MCPTransportMode {
        switch (type ?? "").lowercased() {
        case "sse", "http", "rest": return .httpNoStreaming
        default:                    return .streamableHTTP
        }
    }

    private enum CodingKeys: String, CodingKey { case type, url }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.type = try? container.decode(String.self, forKey: .type)
        self.url = (try? container.decode(String.self, forKey: .url)) ?? ""
    }
}
