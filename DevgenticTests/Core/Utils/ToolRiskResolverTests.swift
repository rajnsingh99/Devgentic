// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
//
//  ToolRiskResolverTests.swift
//  DevgenticTests
//
//  Regression cover for Workflow_Production_Readiness.md row WF-SE3.
//
//  The HITL risk tier used to be derived from the bare tool NAME: a third-party MCP tool named
//  `read_file` wore the native green "Read-only" badge, and every non-colliding MCP tool fell to
//  `.moderate` — the tier that qualifies for the durable "Allow for this chat" grant — even when
//  its own server declared it destructive. `ToolRiskResolver.derive` is the pure decision core
//  (the `UserSkipTeardownPolicy` shape); this is its truth table.
//

import XCTest
@testable import devgentic

final class ToolRiskResolverTests: XCTestCase {

    private func annotations(destructive: Bool? = nil, readOnly: Bool? = nil) -> ToolAnnotations {
        ToolAnnotations(destructiveHint: destructive, idempotentHint: nil, openWorldHint: nil, readOnlyHint: readOnly)
    }

    // MARK: - Native-only names keep the native map

    func testNativeOnlyToolKeepsItsNativeTier() {
        let r = ToolRiskResolver.derive(toolName: "read_file", nativeTier: .safe, mcp: .absent)
        XCTAssertEqual(r, .init(risk: .safe, serverDeclared: false))
    }

    // MARK: - MCP tools are tiered by their server's declared annotations

    func testMCPDestructiveHintIsDestructive() {
        let r = ToolRiskResolver.derive(toolName: "drop_tables", nativeTier: nil,
                                        mcp: .present(annotations(destructive: true)))
        XCTAssertEqual(r.risk, .destructive,
                       "a server-declared destructive tool must lose the durable-grant affordance — under the old name map it was .moderate and offered 'Allow for this chat'")
        XCTAssertTrue(r.serverDeclared)
    }

    /// A third party may INCRIMINATE its own tool but may not VOUCH for it: `readOnlyHint` is
    /// ignored. Granting `.safe` on a server's word unlocked no code path (every affordance keys
    /// off `== .destructive`) — its only effect would have been a green "Read-only" eye
    /// indistinguishable from native `read_file` on a tool that might shell out.
    func testMCPReadOnlyHintIsIgnoredAndStaysModerate() {
        let r = ToolRiskResolver.derive(toolName: "fetch_docs", nativeTier: nil,
                                        mcp: .present(annotations(readOnly: true)))
        XCTAssertEqual(r.risk, .moderate,
                       "a server vouching for itself must not lower its own tool's tier")
        XCTAssertFalse(r.serverDeclared,
                       "nothing was granted on the server's word, so nothing needs the qualifier")
    }

    func testMCPDestructiveHintOutranksReadOnlyHint() {
        let r = ToolRiskResolver.derive(toolName: "sync_and_wipe", nativeTier: nil,
                                        mcp: .present(annotations(destructive: true, readOnly: true)))
        XCTAssertEqual(r.risk, .destructive, "contradictory hints resolve to the worse one")
    }

    func testMCPWithNoUsableClaimIsModerateAndNotServerDeclared() {
        let noClaims = ToolRiskResolver.derive(toolName: "mystery_tool", nativeTier: nil, mcp: .present(nil))
        XCTAssertEqual(noClaims, .init(risk: .moderate, serverDeclared: false))
        let emptyClaims = ToolRiskResolver.derive(toolName: "mystery_tool", nativeTier: nil,
                                                  mcp: .present(annotations()))
        XCTAssertEqual(emptyClaims, .init(risk: .moderate, serverDeclared: false))
    }

    // MARK: - The filed harm (a): a name collision must not vouch for anyone

    func testCollisionOnAReadOnlyNativeNameFloorsAtModerate() {
        // A third-party server offers its own `read_file`: whichever implementation dispatch runs,
        // the badge must not say "Read-only".
        let r = ToolRiskResolver.derive(toolName: "read_file", nativeTier: .safe,
                                        mcp: .present(annotations(readOnly: true)))
        XCTAssertEqual(r, .init(risk: .moderate, serverDeclared: false),
                       "the collision floor is the whole point — the old name map handed this tool the native green eye")
    }

    func testCollisionTakesTheWorseTier() {
        let r = ToolRiskResolver.derive(toolName: "delete_file", nativeTier: .destructive,
                                        mcp: .present(annotations(readOnly: true)))
        XCTAssertEqual(r.risk, .destructive)
        XCTAssertFalse(r.serverDeclared)
    }

    // MARK: - Upward-only name heuristics

    func testArbitraryCodeNameEscalatesAnyProvenance() {
        // Escalation BY NAME is safe (worst case: an extra confirmation); trust by name is the
        // defect. An MCP tool calling itself `execute_shell` is treated as what it claims to be.
        let r = ToolRiskResolver.derive(toolName: "execute_shell", nativeTier: nil,
                                        mcp: .present(annotations(readOnly: true)))
        XCTAssertEqual(r.risk, .destructive)
    }

    // MARK: - Unknown provenance keeps the historical default

    func testUnknownProvenanceIsModerate() {
        let r = ToolRiskResolver.derive(toolName: "profile_local_tool", nativeTier: nil, mcp: .absent)
        XCTAssertEqual(r, .init(risk: .moderate, serverDeclared: false))
    }

    // MARK: - Old persisted confirmations decode (the optional flag)

    func testPreSE3PersistedConfirmationDecodesWithNilFlag() throws {
        let old = PendingToolConfirmation(toolName: "write_file", params: "{}", risk: .moderate)
        var json = try JSONSerialization.jsonObject(with: JSONEncoder().encode(old)) as! [String: Any]
        json.removeValue(forKey: "riskIsServerDeclared")
        let decoded = try JSONDecoder().decode(PendingToolConfirmation.self,
                                               from: JSONSerialization.data(withJSONObject: json))
        XCTAssertNil(decoded.riskIsServerDeclared, "a pre-SE3 parked confirmation must hydrate, not fail G1 resume")
    }
}
