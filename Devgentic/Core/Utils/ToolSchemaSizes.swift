// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
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

        // ⚠️⚠️ Then the CATALOGUE, as a backstop — because the registry is a SUBSET of what can
        // be dispatched. `LocalToolManager` registers `.library` + `.libraryExceptCode` only;
        // `.codeOnly` is deliberately withheld (Code profiles get those from `CodeToolPreset`),
        // and `.hidden` runs while being offered nowhere. Reading the registry alone therefore
        // left all nine code-only tools permanently unpriced, and every Code run logged them as
        // "absent from the snapshot" while blaming a late MCP connect that had nothing to do
        // with it.
        //
        // Field-observed 2026-09-20: a Code session priced 19 tools at 3,168 chars with 9 of them
        // costing ZERO — including `git` (seven actions), `edit_code_batch` (a nested array
        // schema) and `diff_files`. That is the one profile type whose tool payload is entirely
        // fixed and knowable ahead of time, and it was the only one being mis-priced.
        //
        // ⚠️ Deliberately walks EVERY entry rather than adding a second `.codeOnly`-shaped loop.
        // The defect class is "the snapshot enumerates a subset of dispatchable tools and the
        // subset fell behind" — a codeOnly-specific fix would leave that open for whatever
        // visibility is added next. `ToolSchemaSizingTests` asserts the invariant directly.
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

        // Control-plane tools next. `AgentConnect` appends `final_answer`, `ask_user`,
        // `get_conversation_history`, `load_skill` and the Code memory tools per run, outside
        // the catalogue, because each needs run-scoped data to construct. Their SCHEMAS are
        // constants, so they are priceable here — and they were not priced at all until
        // 2026-09-20, which cost a pointer-history Code run 2,102 unaccounted chars.
        for injected in NativeToolCatalog.injectedTools where measured[injected.name] == nil {
            measured[injected.name] = AgentTool.markdownDefinition(
                name: injected.name,
                description: injected.description,
                parameters: injected.parameters
            ).count
            fromCatalogue += 1
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
            logger.debug("[TOOLSCHEMA] Snapshotted \(measured.count) tool schema(s) (\(mcpToolCount) from MCP, \(fromCatalogue) from the catalogue that the registry does not carry), \(total) chars if all were enabled at once.")
        }
    }

    /// Chars the given tools contribute to the prompt.
    ///
    /// Unknown names contribute 0 and are logged. The snapshot covers built-ins, code-only tools
    /// and MCP tools, so an unknown name means a tool registered after the last snapshot — a
    /// server that connected mid-session — and nothing structural.
    ///
    /// ⚠️ That was not true until 2026-09-20: `.codeOnly` tools could never enter the snapshot at
    /// all, so all nine were reported here on EVERY Code run and the message blamed a cause that
    /// did not apply. A message that fires constantly for a reason that is never right is worse
    /// than silence — it trains the reader to skip the line that would have named a real gap.
    ///
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
            logger.debug("[TOOLSCHEMA] \(unknown.count) tool(s) absent from the snapshot, priced at 0 — the fit gauge under-reads by their schema size until the next refresh. CONSEQUENCE: the context gauge and the pre-send fit check both report more headroom than the request has. Usual cause is an MCP server that connected after the last snapshot; a NATIVE name here instead means the catalogue gained a visibility the snapshot does not walk. Absent: \(unknown.joined(separator: ", ")).")
        }
        return total
    }
}
