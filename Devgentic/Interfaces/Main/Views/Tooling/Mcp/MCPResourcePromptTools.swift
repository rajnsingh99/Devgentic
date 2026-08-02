//
//  MCPResourcePromptTools.swift
//  Devgentic
//
//  Created 2026-08-01 — agent-facing access to MCP resources and prompts.
//
//  Resources and prompts are the two largest MCP server surfaces after tools, and neither
//  was reachable: a database-schema browser, a docs/wiki connector or a Drive-style server
//  appeared in Devgentic as an empty server with zero tools, looking broken.
//
//  Rather than inventing a new UI, these are surfaced as SYNTHETIC TOOLS appended to the
//  server's own tool list. That buys the whole existing pipeline for free — they persist
//  like any other tool, appear in the Tool Library, honour per-tool `requiresConfirmation`,
//  resolve by `sourceId`, and are counted by the context-window gauge. The agent discovers
//  them the same way it discovers everything else.
//
//  ⚠️ These names are RESERVED. `AgentConnect.resolveMCPTool` routes them to this file
//  instead of `DynamicMCPTool`, because there is no server-side tool behind them.
//

import Foundation
import MCP

enum MCPSyntheticTool: String, CaseIterable {
    case listResources = "mcp_list_resources"
    case readResource  = "mcp_read_resource"
    case listPrompts   = "mcp_list_prompts"
    case getPrompt     = "mcp_get_prompt"

    /// Per-server tool name. Servers choose their own tool names and a user may connect
    /// several servers at once, so these are qualified — two connected servers would
    /// otherwise both want `mcp_list_resources` and the duplicate-name guard in
    /// `AgentConnect` would drop one of them.
    func qualifiedName(serverName: String) -> String {
        "\(rawValue)__\(Self.slug(serverName))"
    }

    /// Recovers the synthetic kind from a qualified name, or nil for a real server tool.
    static func kind(fromQualified name: String) -> MCPSyntheticTool? {
        allCases.first { name == $0.rawValue || name.hasPrefix("\($0.rawValue)__") }
    }

    static func slug(_ serverName: String) -> String {
        let allowed = serverName.lowercased().map { character -> Character in
            character.isLetter || character.isNumber ? character : "_"
        }
        let collapsed = String(allowed).split(separator: "_", omittingEmptySubsequences: true).joined(separator: "_")
        return collapsed.isEmpty ? "server" : String(collapsed.prefix(32))
    }

    var toolDescription: String {
        switch self {
        case .listResources:
            return "List the readable resources this MCP server exposes (documents, schemas, records). Returns each resource's URI, name and description. Call this before mcp_read_resource to discover what is available."
        case .readResource:
            return "Read one resource from this MCP server by its exact URI, as returned by mcp_list_resources. Returns the resource's text contents."
        case .listPrompts:
            return "List the prompt templates this MCP server provides — the server author's own tested instructions for using it. Returns each prompt's name, description and arguments."
        case .getPrompt:
            return "Expand one of this MCP server's prompt templates by name, supplying any required arguments. Returns the expanded prompt text to act on."
        }
    }

    var parameters: ToolParameters {
        switch self {
        case .listResources, .listPrompts:
            return ToolParameters(type: "object", properties: [:], required: [])
        case .readResource:
            return ToolParameters(
                type: "object",
                properties: [
                    "uri": ToolParameterProperty(
                        type: "string",
                        description: "The exact resource URI from mcp_list_resources.",
                        items: nil
                    )
                ],
                required: ["uri"]
            )
        case .getPrompt:
            return ToolParameters(
                type: "object",
                properties: [
                    "name": ToolParameterProperty(
                        type: "string",
                        description: "The prompt name from mcp_list_prompts.",
                        items: nil
                    ),
                    "arguments": ToolParameterProperty(
                        type: "object",
                        description: "Arguments the prompt declares, as a flat JSON object of string values. Omit if the prompt takes none.",
                        items: nil
                    )
                ],
                required: ["name"]
            )
        }
    }

    /// Reading is non-destructive, so these default to auto-run. This is a DEFAULT for the
    /// user's per-tool setting, not a gate — the user can flip any of them to Ask, and
    /// nothing here overrides that choice.
    var defaultRequiresConfirmation: Bool { false }

    /// Builds the synthetic definitions for a server, given what it advertised at
    /// `initialize`. A server with no resources capability gets no resource tools, so the
    /// agent is never offered a call that can only fail.
    static func definitions(for serverInfo: MCPServerInfo?, serverName: String) -> [ToolDefinition] {
        guard let serverInfo else { return [] }
        var kinds: [MCPSyntheticTool] = []
        if serverInfo.supportsResources { kinds += [.listResources, .readResource] }
        if serverInfo.supportsPrompts { kinds += [.listPrompts, .getPrompt] }

        return kinds.map { kind in
            ToolDefinition(
                name: kind.qualifiedName(serverName: serverName),
                description: "\(kind.toolDescription) (Server: \(serverName).)",
                category: serverName,
                parameters: kind.parameters,
                requiresConfirmation: kind.defaultRequiresConfirmation
            )
        }
    }
}

// MARK: - Executable wrapper

/// Executes a synthetic resource/prompt tool against `MCPClientService`.
struct MCPResourcePromptTool: DevgenticTool {

    let name: String
    let description: String
    var category: String { source.serverName }

    private let source: ToolSource
    private let kind: MCPSyntheticTool

    init(source: ToolSource, definition: ToolDefinition, kind: MCPSyntheticTool) {
        self.source = source
        self.kind = kind
        self.name = definition.name
        self.description = definition.description
    }

    struct Arguments: Decodable, Sendable {
        let uri: String?
        let name: String?
        let arguments: [String: JSONValue]?

        init(from decoder: Decoder) throws {
            let container = try? decoder.container(keyedBy: CodingKeys.self)
            self.uri = try? container?.decodeIfPresent(String.self, forKey: .uri)
            self.name = try? container?.decodeIfPresent(String.self, forKey: .name)
            self.arguments = try? container?.decodeIfPresent([String: JSONValue].self, forKey: .arguments)
        }

        private enum CodingKeys: String, CodingKey { case uri, name, arguments }
    }

    var parameterSchema: ToolParameters { kind.parameters }

    @MainActor
    func call(arguments: Arguments) async throws -> String {
        let service = MCPClientService.shared

        switch kind {
        case .listResources:
            let resources = try await service.listResources(sourceId: source.id)
            guard !resources.isEmpty else {
                return "This server exposes no resources."
            }
            return resources.map { resource in
                let description = resource.description.map { " — \($0)" } ?? ""
                let mime = resource.mimeType.map { " [\($0)]" } ?? ""
                return "\(resource.uri)\(mime): \(resource.name)\(description)"
            }.joined(separator: "\n")

        case .readResource:
            guard let uri = arguments.uri, !uri.isEmpty else {
                throw MCPManagerError.toolReportedFailure(
                    tool: name,
                    detail: "Missing required argument 'uri'. Call \(MCPSyntheticTool.listResources.qualifiedName(serverName: source.serverName)) first to discover valid URIs."
                )
            }
            return try await service.readResource(sourceId: source.id, uri: uri)

        case .listPrompts:
            let prompts = try await service.listPrompts(sourceId: source.id)
            guard !prompts.isEmpty else {
                return "This server exposes no prompts."
            }
            return prompts.map { prompt in
                let description = prompt.description.map { " — \($0)" } ?? ""
                let arguments = (prompt.arguments ?? []).map { argument in
                    "\(argument.name)\(argument.required == true ? "*" : "")"
                }
                let argumentList = arguments.isEmpty ? "" : " (args: \(arguments.joined(separator: ", ")))"
                return "\(prompt.name)\(argumentList)\(description)"
            }.joined(separator: "\n")

        case .getPrompt:
            guard let promptName = arguments.name, !promptName.isEmpty else {
                throw MCPManagerError.toolReportedFailure(
                    tool: name,
                    detail: "Missing required argument 'name'. Call \(MCPSyntheticTool.listPrompts.qualifiedName(serverName: source.serverName)) first to discover valid prompt names."
                )
            }
            // `prompts/get` takes string-valued arguments only (MCP spec). Non-string
            // values are stringified rather than dropped — the prompt's own schema decides
            // what is acceptable, not this layer.
            let mcpArguments: [String: String]? = arguments.arguments.map { raw in
                raw.compactMapValues { jsonValue -> String? in
                    if case .string(let text) = jsonValue { return text }
                    guard let encoded = try? JSONEncoder().encode(jsonValue) else { return nil }
                    return String(data: encoded, encoding: .utf8)
                }
            }
            return try await service.getPrompt(sourceId: source.id, name: promptName, arguments: mcpArguments)
        }
    }
}
