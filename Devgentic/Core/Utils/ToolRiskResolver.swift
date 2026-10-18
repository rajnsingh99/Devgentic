// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
//
//  ToolRiskResolver.swift
//  Devgentic
//
//  Created by Raj Singh.
//

import Foundation

/// Provenance-aware HITL risk tiering: a native tool is tiered by name, an MCP tool by its server's declaration.
/// `derive` is the pure decision core; `resolve` looks up `NativeToolCatalog` membership and the enabled MCP sources.
/// Server claims only tighten the tier, and a name collision floors at `.moderate`.
enum ToolRiskResolver {

    /// What the MCP registry knows about a name.
    enum MCPMatch: Equatable {
        /// No enabled MCP source offers a tool by this name.
        case absent
        /// An enabled MCP source offers it, with whatever annotations its server declared.
        case present(ToolAnnotations?)
    }

    struct Resolution: Equatable {
        let risk: HITLRiskTier
        /// True when the tier rests on the MCP server's own `ToolAnnotations` claims — the
        /// banner appends "(server-declared)" so a third-party assertion is never rendered
        /// indistinguishably from a native guarantee.
        let serverDeclared: Bool
    }

    /// The pure decision. `nativeTier` is `HITLRiskTier.classify(toolName:)` when the name is in
    /// `NativeToolCatalog`, nil otherwise — membership is the caller's lookup, so this function
    /// never touches the name map for a non-native tool (defect (a) above).
    nonisolated static func derive(
        toolName: String,
        nativeTier: HITLRiskTier?,
        mcp: MCPMatch
    ) -> Resolution {
        // Upward-only name heuristic: anything CALLED like an arbitrary-code tool is treated as
        // one regardless of provenance or claims. Escalation by name is safe; trust by name is not.
        if ToolCapability.executesArbitraryCode(toolName) {
            return Resolution(risk: .destructive, serverDeclared: false)
        }

        let mcpTier: (risk: HITLRiskTier, declared: Bool)? = {
            guard case .present(let annotations) = mcp else { return nil }
            // Tightening direction only: a server's claim can raise its tool's tier, never lower it.
            // `destructiveHint` is a party incriminating itself; `readOnlyHint` would be self-vouching, so it is ignored.
            if annotations?.destructiveHint == true { return (.destructive, true) }
            // Anything else from a third party: unknown mutation potential.
            return (.moderate, false)
        }()

        switch (nativeTier, mcpTier) {
        case (let native?, nil):
            return Resolution(risk: native, serverDeclared: false)

        case (nil, let mcp?):
            return Resolution(risk: mcp.risk, serverDeclared: mcp.declared)

        case (let native?, let mcp?):
            // Name collision: dispatch may run either tool, so take the worst answer, floor at `.moderate`,
            // and drop the server-declared credit.
            let worst = [native, mcp.risk, .moderate].max(by: { $0.severityRank < $1.severityRank })!
            return Resolution(risk: worst, serverDeclared: false)

        case (nil, nil):
            // Unknown provenance (e.g. a profile-local tool this build does not index): the
            // historical default.
            return Resolution(risk: .moderate, serverDeclared: false)
        }
    }

    /// The lookup glue. MainActor because both indexes live there.
    @MainActor
    static func resolve(toolName: String) -> Resolution {
        let nativeTier: HITLRiskTier? = NativeToolCatalog.entry(named: toolName) != nil
            ? HITLRiskTier.classify(toolName: toolName)
            : nil

        let mcpDefinition: ToolDefinition? = MCPToolStore.shared.sources
            .filter { $0.type == .mcp && $0.isEnabled }
            .flatMap(\.tools)
            .first { $0.name == toolName }

        if nativeTier != nil, mcpDefinition != nil {
            DGLogger(category: "ToolRiskResolver").warning("[HITL] Tool name COLLISION: '\(toolName)' is both a native tool and an MCP-served tool. CONSEQUENCE: the risk badge floors at 'Modifies' and carries no read-only claim — whichever implementation dispatch runs, the banner does not vouch for it.")
        }

        return derive(
            toolName: toolName,
            nativeTier: nativeTier,
            mcp: mcpDefinition.map { MCPMatch.present($0.annotations) } ?? .absent
        )
    }
}

extension HITLRiskTier {
    /// Ordering for the collision rule — larger is worse.
    fileprivate var severityRank: Int {
        switch self {
        case .safe: return 0
        case .moderate: return 1
        case .destructive: return 2
        }
    }
}
