// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
//
//  MCPToolSD.swift
//  Devgentic
//
//  Created by Raj Singh.
//

import Foundation
import SwiftData
import os

private let logger = DGLogger(category: "MCPToolSD")

// MARK: - MCP Tool Item (parent)

/// SwiftData `@Model` classes for MCP tool persistence.
@Model
final class MCPToolItem {

    @Attribute(.unique)
    var id: UUID

    var serverName: String

    /// JSON-encoded `ServerDefinition`.
    var mcpConfigData: Data?

    /// Whether Devgentic may connect to this server.
    /// A disabled server keeps its full configuration and Keychain secrets but is never connected and contributes no tools.
    /// Defaults to `true`, so servers persisted before the flag existed keep working.
    var isEnabled: Bool = true

    /// Child tool definitions — cascade-deleted when the item is removed.
    @Relationship(deleteRule: .cascade, inverse: \MCPToolDefinitionModel.toolItem)
    var tools: [MCPToolDefinitionModel]

    // Why: bump when `ServerDefinition`'s persisted shape changes: a dropped field silently loses a server's command, args
    // or auth configuration.
    /// Current persisted shape of `mcpConfigData` (`ServerDefinition` as an object root, inline key).
    static let configBlobVersion = 1

    init(
        id: UUID = UUID(),
        serverName: String,
        mcpConfigData: Data? = nil,
        isEnabled: Bool = true,
        tools: [MCPToolDefinitionModel] = []
    ) {
        self.id = id
        self.serverName = serverName
        self.mcpConfigData = mcpConfigData
        self.isEnabled = isEnabled
        self.tools = tools
    }
}

// MARK: - MCP Tool Definition (child)

@Model
final class MCPToolDefinitionModel {

    var name: String
    var toolDescription: String
    var requiresConfirmation: Bool

    /// JSON-encoded `ToolParameters`.
    var parametersData: Data?

    // MCP v0.11.0 fields
    var title: String?
    /// JSON-encoded `[ToolIcon]`.
    var iconsData: Data?
    /// JSON-encoded `ToolAnnotations`.
    var annotationsData: Data?

    var toolItem: MCPToolItem?

    /// Current persisted shape of `parametersData` (`ToolParameters` → object root, inline key).
    static let parametersBlobVersion = 1

    /// What a tool's schema reads as when `parametersData` is absent or cannot be decoded.
    static let placeholderParameters = ToolParameters(type: "object", properties: [:], required: [])

    // Why: an unreadable blob loads as a placeholder (empty schema); 'Save unverified' feeds those back to `updateTool`,
    // which would overwrite the stored schemas for good.
    /// The stored blobs to keep when this tool is rebuilt from `incoming`; nil for a field encoded from `incoming` as usual.
    /// A blob is kept only when it could not be read AND the incoming value is the placeholder that failed read produced.
    /// A real incoming value always wins.
    func blobsToPreserve(whenRebuiltFrom incoming: ToolDefinition) -> (parameters: Data?, icons: Data?, annotations: Data?) {
        let parameters: Data? = parametersData.flatMap { data in
            (try? JSONDecoder().decode(ToolParameters.self, from: data)) == nil
                && incoming.parameters == Self.placeholderParameters ? data : nil
        }
        let icons: Data? = iconsData.flatMap { data in
            (try? JSONDecoder().decode([ToolIcon].self, from: data)) == nil && incoming.icons == nil ? data : nil
        }
        let annotations: Data? = annotationsData.flatMap { data in
            (try? JSONDecoder().decode(ToolAnnotations.self, from: data)) == nil && incoming.annotations == nil ? data : nil
        }
        return (parameters, icons, annotations)
    }

    init(
        name: String,
        toolDescription: String,
        requiresConfirmation: Bool = true,
        parametersData: Data? = nil,
        title: String? = nil,
        iconsData: Data? = nil,
        annotationsData: Data? = nil
    ) {
        self.name = name
        self.toolDescription = toolDescription
        self.requiresConfirmation = requiresConfirmation
        self.parametersData = parametersData
        self.title = title
        self.iconsData = iconsData
        self.annotationsData = annotationsData
    }
}

// MARK: - Conversion to ToolSource

extension MCPToolItem {

    /// Converts to the UI-layer `ToolSource` struct.
    func toToolSource() -> ToolSource {
        let mappedTools = tools.map { model -> ToolDefinition in
            var parameters: ToolParameters
            if let data = model.parametersData {
                do {
                    parameters = try JSONDecoder().decode(ToolParameters.self, from: data)
                } catch {
                    logger.error("[PERSISTENCE] MCP tool '\(model.name)' on '\(serverName)': parametersData UNDECODABLE (\(data.count) bytes) — \(error.localizedDescription). CONSEQUENCE: the tool is offered with an EMPTY schema on this load, so a model calling it gets no argument guidance; the stored bytes are kept by every rebuild that hands this placeholder back (CR-64).")
                    parameters = MCPToolDefinitionModel.placeholderParameters
                }
            } else {
                parameters = MCPToolDefinitionModel.placeholderParameters
            }

            var icons: [ToolIcon]? = nil
            if let data = model.iconsData {
                do {
                    icons = try JSONDecoder().decode([ToolIcon].self, from: data)
                } catch {
                    logger.warning("[PERSISTENCE] MCP tool '\(model.name)' on '\(serverName)': iconsData UNDECODABLE (\(data.count) bytes). CONSEQUENCE: the tool shows no icon on this load; the stored bytes are kept (CR-64).")
                }
            }

            var annotations: ToolAnnotations? = nil
            if let data = model.annotationsData {
                do {
                    annotations = try JSONDecoder().decode(ToolAnnotations.self, from: data)
                } catch {
                    logger.warning("[PERSISTENCE] MCP tool '\(model.name)' on '\(serverName)': annotationsData UNDECODABLE (\(data.count) bytes). CONSEQUENCE: its read-only/destructive hints are missing on this load; the stored bytes are kept (CR-64).")
                }
            }

            return ToolDefinition(
                name: model.name,
                description: model.toolDescription,
                category: serverName,
                parameters: parameters,
                requiresConfirmation: model.requiresConfirmation,
                title: model.title,
                icons: icons,
                annotations: annotations
            )
        }.sorted { $0.name < $1.name }

        // A bare `try?` would make an unreadable configuration indistinguishable from an absent one (both give nil), so the
        // server fails to connect with nothing in the log blaming the stored config; the two cases get different logs.
        var serverDefinition: ServerDefinition?
        var configurationUnreadable = false
        if let data = mcpConfigData {
            do {
                let decoded = try JSONDecoder().decode(ServerDefinition.self, from: data)
                serverDefinition = decoded

                // Every property of `ServerDefinition` is optional or defaulted, so JSON of the wrong shape decodes cleanly into an
                // all-nil definition (no command or URL); name it here so it is in the log from load, not only at connect time.
                if decoded.command == nil && decoded.url == nil {
                    logger.warning(
                        "[PERSISTENCE] MCP source '\(serverName)' (\(id)): mcpConfigData decoded but "
                        + "specifies NEITHER a command nor a url (\(data.count) bytes) — the stored "
                        + "shape does not match ServerDefinition, or the entry was never finished. "
                        + "CONSEQUENCE: no transport can be built, so connecting fails with "
                        + "invalidJSONConfiguration and this server contributes no tools."
                    )
                }
            } catch {
                configurationUnreadable = true
                logger.error(
                    "[PERSISTENCE] MCP source '\(serverName)' (\(id)): mcpConfigData UNDECODABLE "
                    + "(\(data.count) bytes) — \(error). CONSEQUENCE: this server has no command, URL "
                    + "or auth scheme, so it cannot connect and its tools will not resolve; the stored "
                    + "bytes are untouched and stay readable by a build that understands them. "
                    + "⚠️ Do NOT delete this source to 'fix' it — its Keychain secrets are keyed off "
                    + "envKeys inside this blob and would be orphaned."
                )
            }
        }

        return ToolSource(
            id: id,
            type: .mcp,
            serverName: serverName,
            tools: mappedTools,
            serverDefinition: serverDefinition,
            isEnabled: isEnabled,
            isConfigurationUnreadable: configurationUnreadable
        )
    }
}
