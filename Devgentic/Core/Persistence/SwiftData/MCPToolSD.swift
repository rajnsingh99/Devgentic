// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
//
//  MCPToolSD.swift
//  Devgentic
//
//  Created on 26/03/26.
//
//  SwiftData @Model classes for MCP tool persistence.
//  Replaces ToolItemEntity and MCPToolEntity.
//

import Foundation
import SwiftData
import os

private let logger = DGLogger(category: "MCPToolSD")

// MARK: - MCP Tool Item (parent)

@Model
final class MCPToolItem {

    @Attribute(.unique)
    var id: UUID

    var serverName: String

    /// JSON-encoded `ServerDefinition`.
    var mcpConfigData: Data?

    /// Whether Devgentic may connect to this server.
    ///
    /// A disabled server keeps its full configuration and Keychain secrets but is never
    /// connected and contributes no tools. Before this existed the only way to stop using a
    /// server was to DELETE it — which purged its credentials and revoked its OAuth grant,
    /// so "pause this for a bit" meant setting the whole thing up again afterwards.
    ///
    /// Defaults to `true` so every server persisted before the flag existed keeps working
    /// exactly as it did (SwiftData lightweight migration fills the default).
    var isEnabled: Bool = true

    /// Child tool definitions — cascade-deleted when the item is removed.
    @Relationship(deleteRule: .cascade, inverse: \MCPToolDefinitionModel.toolItem)
    var tools: [MCPToolDefinitionModel]

    /// Current persisted shape of `mcpConfigData` (`ServerDefinition` → object root, inline key).
    /// ⚠️ Bump when `ServerDefinition`'s persisted shape changes — a dropped field here means a
    /// server silently loses its command/args/auth configuration (G19).
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
                    logger.warning("Failed to decode parameters for tool \(model.name): \(error). Using default.")
                    parameters = ToolParameters(type: "object", properties: [:], required: [])
                }
            } else {
                parameters = ToolParameters(type: "object", properties: [:], required: [])
            }

            var icons: [ToolIcon]? = nil
            if let data = model.iconsData {
                icons = try? JSONDecoder().decode([ToolIcon].self, from: data)
            }

            var annotations: ToolAnnotations? = nil
            if let data = model.annotationsData {
                annotations = try? JSONDecoder().decode(ToolAnnotations.self, from: data)
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

        // ⚠️ A bare `try?` here made an unreadable configuration indistinguishable from an absent
        // one: both produced `serverDefinition == nil`, the server then failed to connect with no
        // command/args/url, and NOTHING in the log said the stored config was the problem rather
        // than the server (G22). The two cases need different responses, so they get different logs.
        var serverDefinition: ServerDefinition?
        var configurationUnreadable = false
        if let data = mcpConfigData {
            do {
                let decoded = try JSONDecoder().decode(ServerDefinition.self, from: data)
                serverDefinition = decoded

                // ⚠️ EVERY property of `ServerDefinition` is optional or defaulted, so JSON of an
                // entirely wrong shape decodes CLEANLY into an all-nil definition. The decode guard
                // above cannot catch that — there is no error to catch. Such a server has neither a
                // command nor a URL, so `MCPClientService.connect` throws
                // `.invalidJSONConfiguration` (MCPClientService.swift:214) the moment it is used.
                //
                // That error is only reached when the user tries to connect. Naming it here means
                // the condition is in the log from load, alongside the row it belongs to, instead of
                // surfacing later as a connect failure with no history.
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
