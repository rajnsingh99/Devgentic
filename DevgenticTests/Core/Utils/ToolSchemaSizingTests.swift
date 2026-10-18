// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
//
//  ToolSchemaSizingTests.swift
//  DevgenticTests
//
//  Created by Raj Singh.
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
                       "spotlight_search", "edit_code_single", "create_new_file", "git"]
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

        // ⚠️ Was `XCTAssertEqual(agent.schemaBearingToolNames, ["read_file"])`. That pinned the
        // WHOLE array while the point of the test is the bot/agent asymmetry — so it went red
        // when the agent side correctly grew to include the control-plane tools `AgentConnect`
        // injects (2026-09-20). Asserting containment keeps the intent and stops the test
        // objecting to a list it was never about.
        XCTAssertTrue(agent.schemaBearingToolNames.contains("read_file"))
        XCTAssertFalse(agent.schemaBearingToolNames.isEmpty)
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

        // ⚠️ Same over-specification as above: this asserted the entire array, so the
        // control-plane additions failed a test about DISABLED tools. What it actually means is
        // that the disabled one is absent and the enabled one is present.
        let names = profile.schemaBearingToolNames
        XCTAssertTrue(names.contains("read_file"), "the enabled tool must be charged")
        XCTAssertFalse(names.contains("execute_shell"),
                       "a disabled tool is not sent, so it must not be priced: \(names)")
    }

    // MARK: - Coverage: nothing dispatchable may be priced at zero

    /// ⚠️⚠️ THE REGRESSION GUARD. The snapshot was built from `LocalToolManager`, which registers
    /// `.library` + `.libraryExceptCode` and withholds `.codeOnly`. So all NINE code-only tools
    /// were priced at 0 forever, and the "absent from the snapshot" warning fired on every single
    /// Code run while blaming an MCP server that had nothing to do with it.
    ///
    /// Asserted over the whole CATALOGUE, not over a hardcoded list of the nine: the defect class
    /// is "the snapshot walks a subset of what can be dispatched", so a tenth code-only tool — or
    /// a visibility case invented next year — must be covered without anyone remembering to come
    /// back here.
    func testEveryDispatchableNativeToolIsPriced() {
        let unpriced = NativeToolCatalog.entries
            .map(\.name)
            .filter { ToolSchemaSizes.chars(for: [$0]) == 0 }
            .sorted()

        XCTAssertTrue(
            unpriced.isEmpty,
            "\(unpriced.count) catalogue tool(s) cost 0 in the fit gauge: \(unpriced.joined(separator: ", ")). "
            + "Every tool here can ride a request, so a zero price means the gauge and the "
            + "pre-send check both report more headroom than the request has. If a new visibility "
            + "was added, teach `ToolSchemaSizes.refreshFromRegistry` to walk it."
        )
    }

    /// The user-facing form of the same invariant: a real Code session's fixed loadout.
    ///
    /// Its payload is entirely knowable before the run — no MCP, no user configuration — so there
    /// is no excuse for it being approximate. It was the ONLY profile type being mis-priced.
    func testTheCodePresetLoadoutIsFullyPriced() {
        let preset = CodeToolPreset.defaultTools.map(\.name)
        XCTAssertFalse(preset.isEmpty, "the Code preset must not be empty")

        let free = preset.filter { ToolSchemaSizes.chars(for: [$0]) == 0 }.sorted()
        XCTAssertTrue(free.isEmpty,
                      "Code preset tool(s) priced at 0: \(free.joined(separator: ", "))")

        // And the whole loadout costs the sum of its parts — no double counting, no silent drops.
        let total = ToolSchemaSizes.chars(for: preset)
        let sum = preset.reduce(0) { $0 + ToolSchemaSizes.chars(for: [$1]) }
        XCTAssertEqual(total, sum)
    }

    /// All coding tools are now registered in the shared registry and fully priced.
    func testAllCodingToolsAreInSharedRegistryAndPriced() {
        let codingTools = [
            "diff_files", "git", "edit_code_single", "edit_code_batch",
            "code_search_text", "code_search_symbol", "code_search_files",
            "create_new_file", "overwrite_file"
        ]

        let registered = Set(LocalToolManager.shared.availableTools().map(\.name))
        for name in codingTools {
            XCTAssertTrue(registered.contains(name),
                          "'\(name)' must now be in the shared registry for all profiles")
            XCTAssertGreaterThan(
                ToolSchemaSizes.chars(for: [name]), 30,
                "'\(name)' is dispatchable but costs nothing in the gauge."
            )
        }
    }

    // MARK: - Control-plane tools (injected by AgentConnect, outside the catalogue)

    private func profile(
        _ details: ProfileDetails
    ) -> BackendProfileModel {
        BackendProfileSnapshot(displayName: "P", details: details)
    }

    private func agentConfig(
        tools: [Tool] = [],
        strategy: HistoryStrategy? = nil,
        skills: [SkillSelection]? = nil
    ) -> AgentConfig {
        AgentConfig(
            llmConfig: ProviderConfig(apiProvider: .ollama, modelName: "m"),
            tools: tools,
            historyStrategy: strategy,
            skillSelections: skills
        )
    }

    /// ⚠️⚠️ THE REGRESSION GUARD for the pricing half. All five injected tools cost 0 because
    /// they are deliberately outside the catalogue (each needs run-scoped data to CONSTRUCT) and
    /// nothing else priced them. Their schemas are constants, so there was never a reason.
    func testEveryControlPlaneToolIsPriced() {
        XCTAssertFalse(NativeToolCatalog.injectedTools.isEmpty,
                       "the injected-tool list is empty, so every assertion about it is vacuous")

        for injected in NativeToolCatalog.injectedTools {
            XCTAssertGreaterThan(
                ToolSchemaSizes.chars(for: [injected.name]), 30,
                "'\(injected.name)' rides every request that injects it but costs nothing in the gauge."
            )
        }
    }

    /// ⚠️⚠️ THE REGRESSION GUARD for the input half. Pricing them is useless if nothing submits
    /// them: `schemaBearingToolNames` returned only `config.tools`, so all five were invisible
    /// even once priced. A pointer-history Code run hid 2,102 chars this way.
    func testControlPlaneToolNamesAreSubmittedForPricing() {
        let code = profile(.code(agentConfig(strategy: .pointer)))
        let names = Set(code.schemaBearingToolNames)

        for expected in ["final_answer", "ask_user", "remember", "forget", "recall", "get_conversation_history"] {
            XCTAssertTrue(names.contains(expected),
                          "a Code profile with pointer history carries '\(expected)', but the gauge "
                          + "is not charged for it")
        }
        XCTAssertGreaterThan(ToolSchemaSizes.chars(for: code.schemaBearingToolNames), 0)
    }

    /// ⚠️ The typo guard. A name here that is not in `injectedTools` prices at 0 and the whole
    /// property is silently back to under-reading — the exact failure it was written to end.
    func testEverySubmittedNameIsActuallyPriceable() {
        let profiles: [BackendProfileModel] = [
            profile(.agent(agentConfig(strategy: .pointer, skills: []))),
            profile(.code(agentConfig(strategy: .hybrid))),
            profile(.agent(agentConfig(strategy: .recentHistory))),
        ]
        for candidate in profiles {
            for name in candidate.schemaBearingToolNames {
                XCTAssertGreaterThan(
                    ToolSchemaSizes.chars(for: [name]), 0,
                    "'\(name)' is submitted for pricing but is unknown to the snapshot — a "
                    + "misspelled control-plane name prices at 0 and reports no error."
                )
            }
        }
    }

    // MARK: - Each condition is real

    func testTheMemoryToolsAreCodeOnly() {
        for tool in ["remember", "forget", "recall"] {
            XCTAssertFalse(profile(.agent(agentConfig())).schemaBearingToolNames.contains(tool),
                           "an Agent profile never gets '\(tool)'; charging for it over-reads on every agent run")
            XCTAssertTrue(profile(.code(agentConfig())).schemaBearingToolNames.contains(tool))
        }
    }

    func testConversationHistoryToolFollowsThePointerMarker() {
        // ⚠️ `.hybrid` renders its older turns through the same `renderPointerTurn`, so it
        // carries the marker too. Matching only `.pointer` left the middle strategy short 814.
        for strategy in [HistoryStrategy.pointer, .hybrid] {
            XCTAssertTrue(
                profile(.agent(agentConfig(strategy: strategy))).schemaBearingToolNames
                    .contains("get_conversation_history"),
                "\(strategy) emits get_conversation_history( pointers, so the tool ships with it")
        }
        for strategy in [HistoryStrategy.recentHistory, .fullHistory] {
            XCTAssertFalse(
                profile(.agent(agentConfig(strategy: strategy))).schemaBearingToolNames
                    .contains("get_conversation_history"),
                "\(strategy) emits no pointers, so the tool is not injected and must not be charged")
        }
    }

    func testLoadSkillFollowsTheProfilesSkillReferences() {
        XCTAssertFalse(profile(.agent(agentConfig())).schemaBearingToolNames.contains("load_skill"))
        XCTAssertFalse(profile(.agent(agentConfig(skills: []))).schemaBearingToolNames.contains("load_skill"),
                       "an empty selection resolves to no manifests, so no tool is injected")
    }

    // MARK: - It must not double-count

    func testAToolAlreadyInTheProfileIsNotChargedTwice() {
        // ⚠️ An MCP server may publish a tool called `ask_user`. `AgentConnect` keeps the first
        // registration and drops the duplicate, so charging for both would over-read by a whole
        // schema — and the name collision is exactly the case nobody writes a test for.
        let clash = Tool(name: "ask_user", description: "d", isEnabled: true, requiresConfirmation: false,
                         sourceId: UUID(), parameters: ToolParameters(type: "object", properties: [:], required: []))
        let names = profile(.agent(agentConfig(tools: [clash]))).schemaBearingToolNames

        XCTAssertEqual(names.filter { $0 == "ask_user" }.count, 1,
                       "'ask_user' is charged twice: \(names)")
    }

    func testBotsStillCarryNoToolPayloadAtAll() {
        // The control-plane additions must not leak into the one profile type that sends
        // `tools: nil` — a bot charged for final_answer would over-read on every message.
        XCTAssertTrue(profile(.bot(BotConfig(llmConfig: ProviderConfig(apiProvider: .ollama, modelName: "m"))))
            .schemaBearingToolNames.isEmpty)
    }
}
