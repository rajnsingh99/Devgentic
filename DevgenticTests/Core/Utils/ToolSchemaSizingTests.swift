//
//  ToolSchemaSizingTests.swift
//  DevgenticTests
//
//  Tool schemas rode every request and were charged as part of a flat
//  `layerOverheadChars = 2_000` shared with instructions and environment facts. An agent with
//  twenty tools carries several KB of names, descriptions and argument schemas; a bot carries
//  exactly zero. Both were priced identically, and the error grew with each tool enabled —
//  making it a large part of why the same model reads differently as a bot and as an agent.
//

import XCTest
@testable import devgentic

@MainActor
final class ToolSchemaSizingTests: XCTestCase {

    override func setUp() async throws {
        ToolSchemaSizes.refreshFromRegistry()
    }

    // MARK: - Sizing

    /// Real registry entries through the real serializer — a tool must cost something.
    func testAKnownToolHasANonTrivialSchemaCost() {
        let chars = ToolSchemaSizes.chars(for: ["read_file"])
        XCTAssertGreaterThan(chars, 30, "a name + description + arguments is not free")
    }

    func testMoreToolsCostMore() {
        let one = ToolSchemaSizes.chars(for: ["read_file"])
        let several = ToolSchemaSizes.chars(for: ["read_file", "write_file", "list_directory"])
        XCTAssertGreaterThan(several, one)
    }

    /// A realistic agent loadout must be large enough to matter against the flat 2,000 the
    /// whole layer used to be charged at — that gap is the defect.
    func testARealisticLoadoutDwarfsTheFlatOverhead() {
        let loadout = ["read_file", "write_file", "list_directory", "execute_shell",
                       "fs_smart_search", "edit_code_single", "create_new_file", "git_tool"]
        let chars = ToolSchemaSizes.chars(for: loadout)
        XCTAssertGreaterThan(chars, PromptFitCheck.layerOverheadChars / 2,
                             "8 tools priced at \(chars) chars vs a \(PromptFitCheck.layerOverheadChars)-char flat allowance for the ENTIRE layer")
    }

    func testNoToolsCostNothing() {
        XCTAssertEqual(ToolSchemaSizes.chars(for: []), 0)
    }

    /// MCP tools register per-session and are not in the local registry. They must price at 0
    /// rather than crash or guess — a KNOWN under-count, logged, not a silent one.
    func testUnknownToolNamesPriceAtZeroRatherThanGuessing() {
        let known = ToolSchemaSizes.chars(for: ["read_file"])
        let withMystery = ToolSchemaSizes.chars(for: ["read_file", "some_mcp_tool_xyz"])
        XCTAssertEqual(withMystery, known)
    }

    /// Idempotent — the gauge calls it on every recompute.
    func testRefreshIsIdempotent() {
        let before = ToolSchemaSizes.chars(for: ["read_file", "write_file"])
        ToolSchemaSizes.refreshFromRegistry()
        ToolSchemaSizes.refreshFromRegistry()
        XCTAssertEqual(ToolSchemaSizes.chars(for: ["read_file", "write_file"]), before)
    }

    // MARK: - Which profiles carry schemas at all

    /// The bot/agent asymmetry, stated directly. `AgentConnect` sets `rawTools = []` on the
    /// bot flow and `ChatExecutor` passes `tools: nil`, so a bot's tool payload is zero
    /// regardless of what the UI shows enabled.
    func testBotProfilesCarryNoToolSchemas() throws {
        let tools = [Tool(name: "read_file", description: "d", isEnabled: true,
                          requiresConfirmation: false, sourceId: UUID(),
                          parameters: ToolParameters(type: "object", properties: [:], required: []))]

        let agent = BackendProfileSnapshot(displayName: "A", details: .agent(
            AgentConfig(llmConfig: ProviderConfig(apiProvider: .anthropic, modelName: "m"), tools: tools)))
        let bot = BackendProfileSnapshot(displayName: "B", details: .bot(
            BotConfig(llmConfig: ProviderConfig(apiProvider: .anthropic, modelName: "m"))))

        XCTAssertEqual(agent.schemaBearingToolNames, ["read_file"])
        XCTAssertTrue(bot.schemaBearingToolNames.isEmpty,
                      "a bot sends no tool schemas, so it must not be charged for any")
    }

    /// Disabled tools are not sent, so they must not be priced.
    func testDisabledToolsAreNotCharged() {
        let tools = [
            Tool(name: "read_file", description: "d", isEnabled: true, requiresConfirmation: false,
                 sourceId: UUID(), parameters: ToolParameters(type: "object", properties: [:], required: [])),
            Tool(name: "execute_shell", description: "d", isEnabled: false, requiresConfirmation: false,
                 sourceId: UUID(), parameters: ToolParameters(type: "object", properties: [:], required: []))
        ]
        let profile = BackendProfileSnapshot(displayName: "A", details: .agent(
            AgentConfig(llmConfig: ProviderConfig(apiProvider: .anthropic, modelName: "m"), tools: tools)))

        XCTAssertEqual(profile.schemaBearingToolNames, ["read_file"])
    }
}
