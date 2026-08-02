//
//  ToolSchemaSizes.swift
//  Devgentic
//
//  Serialized size of each registered tool's schema, so the fit gauges can price the tool
//  payload instead of pretending it is free.
//
//  Both estimators folded tool schemas into a flat `layerOverheadChars = 2_000` covering
//  "instructions, environment facts, tool schemas, etc." An agent with twenty tools enabled
//  carries several KB of names, descriptions and argument schemas on EVERY request; a bot
//  carries exactly zero (`AgentConnect` sets `rawTools = []` on the bot flow and
//  `ChatExecutor` passes `tools: nil`). Charging both the same 2,000 under-read every agent
//  and over-read every bot — and the error grew with each tool the user enabled.
//
//  Why a cache rather than a direct lookup: `LocalToolManager` is `@MainActor`, the composer
//  gauge is too, but the orchestrator's send-time check is not. Without a shared readable
//  snapshot the two estimators would disagree again — the exact drift this file exists to
//  avoid. Sizes are static per tool, so one snapshot serves both.
//

import Foundation
import os

private let logger = DGLogger(category: "ToolSchemaSizes")

enum ToolSchemaSizes {

    private static let lock = NSLock()
    nonisolated(unsafe) private static var sizesByName: [String: Int] = [:]

    /// Snapshots every registered tool's serialized schema size. Cheap, idempotent, and
    /// called from the gauge — which recomputes on turn boundaries and always runs before a
    /// send, so the send-time check finds a warm cache in practice.
    @MainActor
    static func refreshFromRegistry() {
        var measured = LocalToolManager.shared.availableTools().reduce(into: [String: Int]()) { acc, tool in
            acc[tool.name] = AgentTool.markdownDefinition(
                name: tool.name,
                description: tool.description,
                parameters: tool.parameters
            ).count
        }

        // MCP tools are priced too. They used to fall through to the unknown-name branch
        // and cost 0, which is the WORST case for this gauge: a single server can add
        // dozens of tools with long descriptions and deep argument schemas — easily more
        // than the entire built-in catalogue — and the fit check would report the request
        // as comfortably within budget right up until the provider rejected it.
        //
        // Built-ins are not overwritten on a name clash, matching `AgentConnect`, where the
        // first registration wins and later duplicates are dropped.
        var mcpToolCount = 0
        for source in UnifiedToolStore.shared.sources where source.type == .mcp {
            for definition in source.tools where measured[definition.name] == nil {
                measured[definition.name] = AgentTool.markdownDefinition(
                    name: definition.name,
                    description: definition.description,
                    parameters: definition.parameters
                ).count
                mcpToolCount += 1
            }
        }

        guard !measured.isEmpty else { return }

        lock.lock()
        let isFirst = sizesByName.isEmpty
        sizesByName = measured
        lock.unlock()

        if isFirst {
            let total = measured.values.reduce(0, +)
            logger.debug("[TOOLSCHEMA] Snapshotted \(measured.count) tool schema(s) (\(mcpToolCount) from MCP), \(total) chars if all were enabled at once.")
        }
    }

    /// Chars the given tools contribute to the prompt.
    ///
    /// Unknown names contribute 0 and are logged. Since 2026-08-01 the snapshot covers MCP
    /// tools as well as built-ins, so an unknown name now means a tool registered after the
    /// last snapshot (a server connected mid-session) rather than "every MCP tool".
    /// An empty cache also yields 0 — under-reading, which is the safe direction for an
    /// advisory the user cannot act on.
    static func chars(for toolNames: [String]) -> Int {
        guard !toolNames.isEmpty else { return 0 }

        lock.lock()
        let snapshot = sizesByName
        lock.unlock()

        guard !snapshot.isEmpty else {
            logger.debug("[TOOLSCHEMA] Registry not snapshotted yet — pricing \(toolNames.count) tool(s) at 0. The gauge warms this on its first recompute; a send before that under-reads the tool payload.")
            return 0
        }

        var total = 0
        var unknown: [String] = []
        for name in toolNames {
            if let size = snapshot[name] { total += size } else { unknown.append(name) }
        }
        if !unknown.isEmpty {
            logger.debug("[TOOLSCHEMA] \(unknown.count) tool(s) absent from the snapshot, priced at 0 — the fit gauge under-reads by their schema size until the next refresh (usual cause: an MCP server connected after the last snapshot): \(unknown.joined(separator: ", ")).")
        }
        return total
    }
}
