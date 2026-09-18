// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
//
//  WorkflowActionToolResolutionTests.swift
//  DevgenticTests
//
//  Regression cover for Workflow_Production_Readiness.md row WF3 — tool shadowing on the
//  workflow Action-node path.
//
//  `AgentConnect.resolveWorkflowTool` resolved by NAME first and only fell through to MCP when
//  the name missed, ignoring `Tool.sourceId` entirely. MCP servers choose their own tool names,
//  so an Action node bound to a sandboxed filesystem server's `write_file` silently executed
//  Devgentic's own unsandboxed `write_file`, with arguments resolved from upstream MODEL output.
//  The agent path (`resolveExecutableTools`) fixed this; this twin never received it.
//

import XCTest
@testable import devgentic

final class WorkflowActionToolResolutionTests: XCTestCase {

    /// A tool name that genuinely exists in `NativeToolCatalog`, chosen at run time so the test
    /// cannot rot against a renamed built-in.
    private var nativeToolName: String {
        // Sorted for determinism — any real entry proves the point.
        NativeToolCatalog.byName.keys.sorted().first ?? "read_file"
    }

    private func tool(named name: String, sourceId: UUID) -> Tool {
        Tool(
            name: name,
            description: "Action-node tool under test",
            isEnabled: true,
            requiresConfirmation: true,
            sourceId: sourceId,
            parameters: ToolParameters(type: "object", properties: [:], required: [])
        )
    }

    // MARK: - WF3

    /// The shadowing case. A tool whose `sourceId` names an MCP server must NEVER resolve to the
    /// built-in of the same name — not even when that server is absent, which is precisely when
    /// the old name-first lookup silently substituted the local implementation.
    func testMCPSourcedToolDoesNotFallBackToTheNativeImplementation() async {
        let name = nativeToolName
        XCTAssertNotNil(NativeToolCatalog.entry(named: name),
                        "Precondition: '\(name)' must be a real built-in, or this test proves nothing")

        let foreignSource = UUID()
        XCTAssertNotEqual(foreignSource, ToolSource.builtInSourceID)

        let resolved = await AgentConnect().resolveWorkflowTool(
            tool(named: name, sourceId: foreignSource),
            conversationID: UUID()
        )

        XCTAssertNil(
            resolved,
            "A tool sourced from an MCP server must not resolve to the same-named built-in. "
            + "Returning the native tool here is the shadowing bug: the sandbox the user chose by "
            + "picking that server is replaced by an implementation with no such limit."
        )
    }

    /// The other half of the branch: a genuinely built-in tool must still resolve, or the fix
    /// would have broken every native Action node.
    func testBuiltInSourcedToolStillResolves() async {
        let name = nativeToolName

        let resolved = await AgentConnect().resolveWorkflowTool(
            tool(named: name, sourceId: ToolSource.builtInSourceID),
            conversationID: UUID()
        )

        XCTAssertNotNil(resolved, "A built-in-sourced Action tool must still resolve")
        XCTAssertEqual(resolved?.name, name)
    }

    /// A built-in `sourceId` carrying a name no built-in has must fail closed rather than being
    /// resolved against whatever MCP server happens to expose that name.
    func testBuiltInSourcedUnknownNameResolvesToNil() async {
        let resolved = await AgentConnect().resolveWorkflowTool(
            tool(named: "definitely_not_a_real_tool_name_wf3", sourceId: ToolSource.builtInSourceID),
            conversationID: UUID()
        )

        XCTAssertNil(resolved)
    }

    // MARK: - WF59 (the AGENT path's twin)

    /// The same rule on the agent path. Both arms of `resolveExecutableTools` used to end in
    /// `?? <the other resolver>`, so a declared source that MISSED — an enabled server that no
    /// longer exposes the name, or a server row removed entirely — silently ran the same-named
    /// local implementation instead.
    ///
    /// Differential rather than absolute: `resolveExecutableTools` also appends core system tools
    /// unconditionally, so the test compares the SAME name under two source ids.
    func testAgentPathDoesNotFallBackAcrossSources() async {
        let name = nativeToolName
        let memory = StaticGroundingMemory(ragContext: "")

        let underForeignSource = await AgentConnect().resolveExecutableTools(
            profileTools: [tool(named: name, sourceId: UUID())],
            conversationID: UUID(),
            longTermMemory: memory
        )
        XCTAssertFalse(
            underForeignSource.contains { $0.name == name },
            "A tool declared as coming from an MCP source must not resolve to the same-named "
            + "built-in when that source cannot supply it — that substitution is the shadowing bug."
        )

        let underBuiltInSource = await AgentConnect().resolveExecutableTools(
            profileTools: [tool(named: name, sourceId: ToolSource.builtInSourceID)],
            conversationID: UUID(),
            longTermMemory: memory
        )
        XCTAssertTrue(
            underBuiltInSource.contains { $0.name == name },
            "The control: declared as built-in, the same tool must still resolve — otherwise the "
            + "test above would pass simply because nothing resolves at all."
        )
    }

    // MARK: - WF7 (confirmation is re-derived, not read off the stored snapshot)

    /// An Action node saved before 2026-07-31 carries `requiresConfirmation: false` for EVERY
    /// tool, because `ActionNodeInspectorView.selectTool` seeded it unconditionally. The resolved
    /// tool must not inherit that stale `false` — the node's confirmation gate reads the resolved
    /// tool, so inheriting it means a destructive tool runs unattended with model-derived
    /// arguments, forever.
    ///
    /// ⚠️ This exercises the LIVE-DERIVATION path, not the fail-closed fallback: the test host
    /// does build `UnifiedToolStore`'s built-in source (it is `LocalToolManager`, in-process and
    /// needing no server), so `liveDefinition` is found and supplies the real default. The
    /// precondition below pins that, because if the built-in source were ever absent the
    /// assertion would still pass — via the fail-closed `?? true` — and the test would silently
    /// stop testing what it names.
    func testStaleStoredConfirmationIsNotTrusted() async {
        let name = nativeToolName

        let liveDefinition = await UnifiedToolStore.shared.sources
            .first { $0.id == ToolSource.builtInSourceID }?
            .tools.first { $0.name == name }
        XCTAssertNotNil(liveDefinition,
                        "Precondition: the built-in source must be live, or this asserts the fallback instead")
        XCTAssertTrue(liveDefinition?.requiresConfirmation == true,
                      "Precondition: '\(name)' must be a confirm-by-default tool for this test to mean anything")

        var staleNode = tool(named: name, sourceId: ToolSource.builtInSourceID)
        staleNode.requiresConfirmation = false   // the pre-fix snapshot

        let resolved = await AgentConnect().resolveWorkflowTool(staleNode, conversationID: UUID())

        XCTAssertNotNil(resolved)
        XCTAssertTrue(
            resolved?.requiresConfirmation == true,
            "A stored `false` must not be trusted: it is a snapshot of the catalogue default at "
            + "pick time, not a user preference, and this path has no per-node Ask/Auto control."
        )
    }

    /// The live default must be honoured in BOTH directions — a read-only tool must not start
    /// asking just because the derivation now runs. Guards against "fail closed" being applied
    /// where a live answer exists.
    func testReadOnlyToolDoesNotStartAskingAfterLiveDerivation() async {
        // `read_file` is on `LocalToolManager`'s read-only allowlist.
        guard let liveDefinition = await UnifiedToolStore.shared.sources
            .first(where: { $0.id == ToolSource.builtInSourceID })?
            .tools.first(where: { $0.name == "read_file" })
        else { return XCTFail("read_file must be live in the built-in source") }
        XCTAssertFalse(liveDefinition.requiresConfirmation, "Precondition: read_file is auto-run by default")

        var node = tool(named: "read_file", sourceId: ToolSource.builtInSourceID)
        node.requiresConfirmation = true

        let resolved = await AgentConnect().resolveWorkflowTool(node, conversationID: UUID())

        XCTAssertEqual(resolved?.requiresConfirmation, false,
                       "The live definition is the authority in both directions, not just when it tightens")
    }

    /// The same fail-closed rule for an MCP-sourced tool whose server is unreachable: it must not
    /// resolve at all, so a stale `false` cannot reach the gate by any route.
    func testStaleStoredConfirmationOnUnreachableMCPToolResolvesToNil() async {
        var staleNode = tool(named: nativeToolName, sourceId: UUID())
        staleNode.requiresConfirmation = false

        let resolved = await AgentConnect().resolveWorkflowTool(staleNode, conversationID: UUID())

        XCTAssertNil(resolved, "No live source ⇒ no tool, rather than a local substitute carrying a stale flag")
    }

    /// A disabled tool is never resolved regardless of source — guards against the strict branch
    /// accidentally widening what gets registered.
    func testDisabledToolIsNotResolvedOnTheAgentPath() async {
        let name = nativeToolName
        var disabled = tool(named: name, sourceId: ToolSource.builtInSourceID)
        disabled.isEnabled = false

        let resolved = await AgentConnect().resolveExecutableTools(
            profileTools: [disabled],
            conversationID: UUID(),
            longTermMemory: StaticGroundingMemory(ragContext: "")
        )

        XCTAssertFalse(resolved.contains { $0.name == name })
    }
}
