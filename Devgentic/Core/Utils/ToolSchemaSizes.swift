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
        let measured = LocalToolManager.shared.availableTools().reduce(into: [String: Int]()) { acc, tool in
            acc[tool.name] = AgentTool.markdownDefinition(
                name: tool.name,
                description: tool.description,
                parameters: tool.parameters
            ).count
        }
        guard !measured.isEmpty else { return }

        lock.lock()
        let isFirst = sizesByName.isEmpty
        sizesByName = measured
        lock.unlock()

        if isFirst {
            let total = measured.values.reduce(0, +)
            logger.debug("[TOOLSCHEMA] Snapshotted \(measured.count) tool schema(s), \(total) chars if all were enabled at once.")
        }
    }

    /// Chars the given tools contribute to the prompt.
    ///
    /// Unknown names contribute 0 and are logged: MCP tools are registered per-session rather
    /// than in the local registry, so they are a KNOWN under-count rather than a silent one.
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
            logger.debug("[TOOLSCHEMA] \(unknown.count) tool(s) not in the local registry, priced at 0 (likely MCP, registered per-session): \(unknown.joined(separator: ", ")).")
        }
        return total
    }
}
