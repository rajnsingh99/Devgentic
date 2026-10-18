// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
//
//  MCPProtocolSurfaceTests.swift
//  DevgenticTests
//
//  Created by Raj Singh.
//

import XCTest
@testable import devgentic

final class MCPProtocolSurfaceTests: XCTestCase {

    // MARK: - Helpers

    private func serverInfo(
        resources: Bool = false,
        prompts: Bool = false,
        tools: Bool = true
    ) -> MCPServerInfo {
        MCPServerInfo(
            protocolVersion: "2025-06-18",
            serverName: "Test Server",
            serverVersion: "1.0.0",
            instructions: nil,
            supportsResources: resources,
            supportsResourceSubscribe: false,
            supportsResourceListChanged: false,
            supportsPrompts: prompts,
            supportsPromptListChanged: false,
            supportsTools: tools,
            supportsLogging: false
        )
    }

    // MARK: - Capability-driven exposure

    /// A server that advertises neither capability must get no synthetic tools — offering
    /// the agent a call that can only fail is worse than not offering it.
    func testDefinitions_NoCapabilities_YieldsNothing() {
        let definitions = MCPSyntheticTool.definitions(for: serverInfo(), serverName: "Test Server")
        XCTAssertTrue(definitions.isEmpty)
    }

    func testDefinitions_ResourcesOnly_YieldsListAndRead() {
        let definitions = MCPSyntheticTool.definitions(
            for: serverInfo(resources: true), serverName: "Test Server"
        )
        XCTAssertEqual(definitions.count, 2)
        let kinds = definitions.compactMap { MCPSyntheticTool.kind(fromQualified: $0.name) }
        XCTAssertEqual(Set(kinds), [.listResources, .readResource])
    }

    func testDefinitions_PromptsOnly_YieldsListAndGet() {
        let definitions = MCPSyntheticTool.definitions(
            for: serverInfo(prompts: true), serverName: "Test Server"
        )
        XCTAssertEqual(definitions.count, 2)
        let kinds = definitions.compactMap { MCPSyntheticTool.kind(fromQualified: $0.name) }
        XCTAssertEqual(Set(kinds), [.listPrompts, .getPrompt])
    }

    func testDefinitions_BothCapabilities_YieldsFour() {
        let definitions = MCPSyntheticTool.definitions(
            for: serverInfo(resources: true, prompts: true), serverName: "Test Server"
        )
        XCTAssertEqual(definitions.count, 4)
    }

    func testDefinitions_NilServerInfo_YieldsNothing() {
        XCTAssertTrue(MCPSyntheticTool.definitions(for: nil, serverName: "Test Server").isEmpty)
    }

    // MARK: - Naming

    /// Two connected servers must not both claim `mcp_list_resources`, or the
    /// duplicate-name guard in AgentConnect would drop one server's access entirely.
    func testQualifiedName_DiffersPerServer() {
        let first = MCPSyntheticTool.listResources.qualifiedName(serverName: "GitHub")
        let second = MCPSyntheticTool.listResources.qualifiedName(serverName: "Notion")
        XCTAssertNotEqual(first, second)
    }

    func testQualifiedName_IsStableForTheSameServer() {
        XCTAssertEqual(
            MCPSyntheticTool.readResource.qualifiedName(serverName: "My Server"),
            MCPSyntheticTool.readResource.qualifiedName(serverName: "My Server")
        )
    }

    /// Tool names reach provider APIs, which constrain the character set.
    func testQualifiedName_SanitisesServerNames() {
        let name = MCPSyntheticTool.listResources.qualifiedName(serverName: "My Server! (v2) 🚀")
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "_"))
        XCTAssertTrue(
            name.unicodeScalars.allSatisfy(allowed.contains),
            "Name must be provider-safe, got: \(name)"
        )
    }

    func testQualifiedName_EmptyServerName_StillProducesAUsableName() {
        let name = MCPSyntheticTool.listPrompts.qualifiedName(serverName: "")
        XCTAssertTrue(name.hasPrefix("mcp_list_prompts__"))
        XCTAssertFalse(name.hasSuffix("__"), "Must not end with a dangling separator")
    }

    // MARK: - Reserved-name routing

    /// `AgentConnect.resolveMCPTool` uses this to route away from `DynamicMCPTool`.
    /// A miss here means a `tools/call` for a tool the server has never heard of.
    func testKindRecovery_RoundTripsForEveryCase() {
        for kind in MCPSyntheticTool.allCases {
            let qualified = kind.qualifiedName(serverName: "Some Server")
            XCTAssertEqual(MCPSyntheticTool.kind(fromQualified: qualified), kind, "Failed for \(kind)")
        }
    }

    func testKindRecovery_RealServerToolName_IsNotClaimed() {
        XCTAssertNil(MCPSyntheticTool.kind(fromQualified: "read_file"))
        XCTAssertNil(MCPSyntheticTool.kind(fromQualified: "search_issues"))
        XCTAssertNil(MCPSyntheticTool.kind(fromQualified: "list_resources"))
    }

    // MARK: - Schemas

    /// `read_resource` without a URI cannot do anything, so the model must be told it is required.
    func testSchema_ReadResource_RequiresURI() {
        let parameters = MCPSyntheticTool.readResource.parameters
        XCTAssertEqual(parameters.required, ["uri"])
        XCTAssertEqual(parameters.properties["uri"]?.type, "string")
    }

    func testSchema_GetPrompt_RequiresNameButNotArguments() {
        let parameters = MCPSyntheticTool.getPrompt.parameters
        XCTAssertEqual(parameters.required, ["name"])
        XCTAssertNotNil(parameters.properties["arguments"], "Optional arguments must still be advertised")
    }

    func testSchema_ListTools_TakeNoArguments() {
        for kind in [MCPSyntheticTool.listResources, .listPrompts] {
            XCTAssertTrue(kind.parameters.properties.isEmpty, "\(kind) should take no arguments")
            XCTAssertTrue(kind.parameters.required.isEmpty)
        }
    }

    /// Read-only operations default to auto-run. This is a DEFAULT for the user's per-tool
    /// setting, never a gate — the user can flip any of them to Ask.
    func testSyntheticTools_DefaultToAutoRun() {
        for kind in MCPSyntheticTool.allCases {
            XCTAssertFalse(kind.defaultRequiresConfirmation, "\(kind) is read-only")
        }
    }

    /// The definitions must survive the persistence round-trip like any other tool.
    func testDefinitions_AreCodable() throws {
        let definitions = MCPSyntheticTool.definitions(
            for: serverInfo(resources: true, prompts: true), serverName: "Test Server"
        )
        let data = try JSONEncoder().encode(definitions)
        let decoded = try JSONDecoder().decode([ToolDefinition].self, from: data)
        XCTAssertEqual(decoded.map(\.name), definitions.map(\.name))
    }
}
