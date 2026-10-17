// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
//
//  InstructionToolReferencesTests.swift
//  DevgenticTests
//
//  Item 9 of the 2026-09-27 OpenRouter review: a profile's instructions named a tool it could not
//  call ("use fs_smart_search first" — renamed to `spotlight_search` in Build 102.6, and not enabled
//  under either name). Nothing reported it.
//

import XCTest
@testable import devgentic

final class InstructionToolReferencesTests: XCTestCase {

    /// Agent 3's own sentence and loadout.
    func testAgent3Case_RenamedToolThatIsNotEnabledEither() {
        let findings = InstructionToolReferences.check(
            instructions: "5. When the user names a file or folder without a full path, use fs_smart_search first to locate it.",
            enabledToolNames: ["list_directory", "read_file"])
        XCTAssertEqual(findings, [.renamed(old: "fs_smart_search", new: "spotlight_search", replacementEnabled: false)])
        XCTAssertTrue(findings[0].message.contains("spotlight_search"))
    }

    func testRenamedToolWhoseReplacementIsEnabled() {
        let findings = InstructionToolReferences.check(instructions: "Prefer codebase_map.", enabledToolNames: ["project_tree"])
        XCTAssertEqual(findings, [.renamed(old: "codebase_map", new: "project_tree", replacementEnabled: true)])
    }

    func testRealToolThatIsNotEnabled() {
        let findings = InstructionToolReferences.check(instructions: "Use spotlight_search, then read_file.", enabledToolNames: ["read_file"])
        XCTAssertEqual(findings, [.notEnabled(name: "spotlight_search")])
    }

    func testRemovedTool() {
        XCTAssertEqual(InstructionToolReferences.check(instructions: "Run execute_shell if needed.", enabledToolNames: []),
                       [.removed(name: "execute_shell")])
    }

    func testEnabledAndControlPlaneToolsAreNeverFlagged() {
        let text = "Call read_file, then final_answer; use ask_user when unsure."
        XCTAssertEqual(InstructionToolReferences.check(instructions: text, enabledToolNames: ["read_file"]), [])
    }

    /// Prose that happens to be snake_case, and one-word tool names used as words, are not tool
    /// references — only exact matches against declared vocabularies count.
    func testProseIsIgnored() {
        let text = "Check the user_name field and report_1_log.txt; use git to see history."
        XCTAssertEqual(InstructionToolReferences.check(instructions: text, enabledToolNames: []), [])
    }

    func testEachNameReportedOnceInFirstMentionOrder() {
        let text = "Use spotlight_search. Then fs_watch_folder. Again spotlight_search."
        XCTAssertEqual(InstructionToolReferences.check(instructions: text, enabledToolNames: []).map(\.name),
                       ["spotlight_search", "fs_watch_folder"])
    }

    func testNilOrEmptyInstructions() {
        XCTAssertEqual(InstructionToolReferences.check(instructions: nil, enabledToolNames: []), [])
        XCTAssertEqual(InstructionToolReferences.check(instructions: "", enabledToolNames: []), [])
    }

    // MARK: - The retired-name tables stay true to the catalogue

    func testRetiredNameTablesAgreeWithTheCatalogue() {
        let live = NativeToolCatalog.allToolNames
        for (old, new) in NativeToolCatalog.renamedTools {
            XCTAssertTrue(live.contains(new), "'\(old)' is listed as renamed to '\(new)', which is not a registered tool")
            XCTAssertFalse(live.contains(old), "'\(old)' is listed as renamed but is still a registered tool")
        }
        for name in NativeToolCatalog.removedTools {
            XCTAssertFalse(live.contains(name), "'\(name)' is listed as removed but is still a registered tool")
            XCTAssertNil(NativeToolCatalog.renamedTools[name], "'\(name)' cannot be both renamed and removed")
        }
    }

    // MARK: - Wiring: the validator surfaces it as an advisory

    private func tool(_ name: String) -> Tool {
        Tool(name: name, description: "", sourceId: UUID(),
             parameters: ToolParameters(type: "object", properties: [:], required: []))
    }

    private func agentSnapshot(instructions: String, tools: [Tool]) -> BackendProfileSnapshot {
        let config = AgentConfig(
            llmConfig: ProviderConfig(apiProvider: .openRouter, modelName: "a/b", apiKey: "sk-or-x"),
            tools: tools, instructions: instructions)
        return BackendProfileSnapshot(displayName: "Agent 3", details: .agent(config))
    }

    func testValidatorReportsItAsAdvisoryInBothModes() {
        let snapshot = agentSnapshot(instructions: "Always use fs_smart_search first.",
                                     tools: [tool("list_directory"), tool("read_file")])
        for strict in [true, false] {
            let errors = ProfileValidator.validate(snapshot, strict: strict)
            let finding = errors.first { $0.message.contains("fs_smart_search") }
            XCTAssertNotNil(finding, "strict=\(strict)")
            XCTAssertEqual(finding?.severity, .advisory, "a stale tool reference must never block a save")
        }
    }

    func testDisabledToolsCountAsNotEnabled() {
        var disabled = tool("spotlight_search")
        disabled.isEnabled = false
        let errors = ProfileValidator.validate(agentSnapshot(instructions: "Use spotlight_search.", tools: [disabled]), strict: false)
        XCTAssertTrue(errors.contains { $0.message.contains("isn't enabled") })
    }
}
