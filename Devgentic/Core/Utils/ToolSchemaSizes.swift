// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
//
//  ToolSchemaSizes.swift
//  Devgentic
//
//  Created by Raj Singh.
//

import Foundation
import os

private let logger = DGLogger(category: "ToolSchemaSizes")

/// Serialized size of each registered tool's schema, so the fit gauges price the tool payload.
/// A shared snapshot serves both the main-actor composer gauge and the off-main send-time check.
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

        // Backstop: the registry holds only `.library` / `.libraryExceptCode` tools, but `.codeOnly` and `.hidden` ones
        // dispatch too. Walks every catalogue entry so a subset-only snapshot cannot leave tools unpriced.
        var fromCatalogue = 0
        for entry in NativeToolCatalog.entries where measured[entry.name] == nil {
            let tool = entry.executable()
            measured[entry.name] = AgentTool.markdownDefinition(
                name: tool.name,
                description: tool.description,
                parameters: tool.parameters
            ).count
            fromCatalogue += 1
        }

        // Control-plane tools: `AgentConnect` appends `final_answer`, `ask_user`, `get_conversation_history`, `load_skill`
        // and the Code memory tools per run, outside the catalogue; their schemas are constants, so they are priced here.
        for injected in NativeToolCatalog.injectedTools where measured[injected.name] == nil {
            measured[injected.name] = AgentTool.markdownDefinition(
                name: injected.name,
                description: injected.description,
                parameters: injected.parameters
            ).count
            fromCatalogue += 1
        }

        // MCP tools are priced too: unpriced, a server's many tools would let the fit check pass a request the provider rejects.
        // Built-ins win a name clash, matching `AgentConnect` where the first registration wins.
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
            logger.debug("[TOOLSCHEMA] Snapshotted \(measured.count) tool schema(s) (\(mcpToolCount) from MCP, \(fromCatalogue) from the catalogue that the registry does not carry), \(total) chars if all were enabled at once.")
        }
    }

    /// Chars the given tools contribute to the prompt.
    /// Unknown names contribute 0 and are logged: they are tools registered after the last snapshot, such as a late
    /// MCP connect. An empty cache also yields 0, which under-reads: the safe direction for an advisory.
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
            logger.debug("[TOOLSCHEMA] \(unknown.count) tool(s) absent from the snapshot, priced at 0 — the fit gauge under-reads by their schema size until the next refresh. CONSEQUENCE: the context gauge and the pre-send fit check both report more headroom than the request has. Usual cause is an MCP server that connected after the last snapshot; a NATIVE name here instead means the catalogue gained a visibility the snapshot does not walk. Absent: \(unknown.joined(separator: ", ")).")
        }
        return total
    }
}
