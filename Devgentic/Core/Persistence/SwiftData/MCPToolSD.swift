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

    /// Child tool definitions — cascade-deleted when the item is removed.
    @Relationship(deleteRule: .cascade, inverse: \MCPToolDefinitionModel.toolItem)
    var tools: [MCPToolDefinitionModel]

    init(id: UUID = UUID(), serverName: String, mcpConfigData: Data? = nil, tools: [MCPToolDefinitionModel] = []) {
        self.id = id
        self.serverName = serverName
        self.mcpConfigData = mcpConfigData
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

        var serverDefinition: ServerDefinition?
        if let data = mcpConfigData {
            serverDefinition = try? JSONDecoder().decode(ServerDefinition.self, from: data)
        }

        return ToolSource(
            id: id,
            type: .mcp,
            serverName: serverName,
            tools: mappedTools,
            serverDefinition: serverDefinition
        )
    }
}
