//
//  ToolRiskResolver.swift
//  Devgentic
//
//  Provenance-aware HITL risk tiering — Workflow_Production_Readiness.md row WF-SE3.
//
//  `HITLRiskTier.classify(toolName:)` is a NAME map: it answers "what would the native tool by
//  this name do", not "what does the tool that will actually run do". Used alone (as the HITL
//  enqueue site did), two things went wrong:
//    (a) a third-party MCP tool that happens to be NAMED `read_file` inherited the native green
//        "Read-only" badge — a guard on a name is a guard on a name (injection-audit lesson);
//    (b) every non-colliding MCP tool fell to `default: .moderate`, which is what qualifies a
//        tool for the durable "Allow for this chat" grant — even when its own server declared it
//        destructive (`ToolAnnotations.destructiveHint`, imported and persisted since MCP v0.11
//        and never consulted here).
//
//  The decision core (`derive`) is a pure nonisolated function tested exhaustively — the
//  `UserSkipTeardownPolicy` shape — and the MainActor `resolve` is thin glue doing the two
//  lookups (NativeToolCatalog membership, enabled MCP sources).
//
//  Trust rules, deliberately asymmetric:
//    • A server's claims are consumed in the TIGHTENING direction ONLY — `destructiveHint` raises
//      the tier, `readOnlyHint` is ignored. A third party may incriminate its own tool; it may not
//      vouch for it. (The permissive arm was built, reviewed and removed: `.safe` unlocks no code
//      path, so its only effect was a green "Read-only" eye indistinguishable from a native tool's
//      on a banner whose job is informing consent.)
//    • A NAME COLLISION (native and MCP tool share the name) floors at `.moderate` and drops the
//      server-declared credit: whichever of the two actually runs, the badge must not claim
//      read-only when we cannot know. Collisions are security-relevant and logged.
//    • The arbitrary-code name check escalates ANY provenance to `.destructive` — upward-only
//      name heuristics are safe; downward ones are the defect this file fixes.
//

import Foundation

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
            // TIGHTENING DIRECTION ONLY. A server's own claim can raise its tool's tier, never
            // lower it: `destructiveHint` is a party incriminating itself and costs nothing to
            // believe, while `readOnlyHint` is a party vouching for itself.
            //
            // ⚠️ `readOnlyHint == true → .safe` was implemented and then REMOVED on review. It
            // bought nothing and risked real harm: `.safe` unlocks no code path (every affordance
            // keys off `== .destructive`), so the entire effect was showing a green "Read-only"
            // eye — byte-identical to what native `read_file` earns — for a tool that might shell
            // out, on a banner whose whole job is informing consent. A "(server-declared)"
            // qualifier was the mitigation, and it would have had to be rendered correctly on
            // EVERY confirmation surface forever (the QuickAccess banner already missed it). An
            // unverifiable claim that only ever makes a warning quieter is not worth carrying.
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
            // NAME COLLISION — we cannot know which tool dispatch will run. Take the worst of
            // the two answers, floor at `.moderate` (the badge must never claim read-only under
            // ambiguity), and drop the server-declared credit.
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
