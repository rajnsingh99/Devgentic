// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
//
//  CodeToolPresetTests.swift
//  DevgenticTests
//
//  `CodeToolPreset.defaultTools` used to spell out a description and an empty `ToolParameters`
//  for each of its 16 entries. Both were wrong in different ways: the descriptions were dead text
//  (resolution reads the tool's own via `AgentToolFactory`, never the profile's copy), and the
//  empty schemas were a latent trap — harmless for Code profiles, which never read them, but
//  `Tool.parameters` is exactly what a workflow Action node binds its arguments from.
//
//  It derives from `NativeToolCatalog` now. These tests pin the membership that was previously
//  guaranteed by the literal, and pin the two properties the old shape got wrong.
//

import XCTest
@testable import devgentic

final class CodeToolPresetTests: XCTestCase {

    /// The 16 tools the preset guaranteed before it began deriving. Pinned by name so a silent
    /// change in membership — a `preset(…)` line lost to a bad merge, or a catalogue rename —
    /// fails here rather than quietly shipping a Code agent with fewer tools.
    private static let expectedNames: Set<String> = [
        "read_file", "list_directory", "codebase_map", "glob_files", "find_definition",
        "file_overview", "code_search_text", "code_search_symbol", "code_search_files",
        "edit_code_single", "edit_code_batch", "create_new_file", "overwrite_file",
        "batch_command", "git_tool", "diff_files",
    ]

    func testPresetMembershipIsUnchanged() {
        XCTAssertEqual(Set(CodeToolPreset.defaultTools.map(\.name)), Self.expectedNames)
    }

    /// `preset(…)` returns nil for a name the catalogue does not know, and `compactMap` drops it.
    /// A count mismatch means a preset entry silently vanished — the release-path behaviour the
    /// assertion in `preset(…)` is meant to make impossible in debug.
    func testEveryPresetNameResolvesInTheCatalog() {
        XCTAssertEqual(CodeToolPreset.defaultTools.count, Self.expectedNames.count,
            "\(Self.expectedNames.count - CodeToolPreset.defaultTools.count) preset entr(ies) were "
            + "dropped because the catalogue does not know their name")

        for name in Self.expectedNames {
            XCTAssertNotNil(NativeToolCatalog.entry(named: name), "\(name) is not in the catalogue")
        }
    }

    // MARK: - The two things the old literal got wrong

    /// Every preset tool carries the real argument schema. The old literal passed
    /// `ToolParameters(type: "object", properties: [:], required: [])` for all 16 — an empty
    /// schema. This asserts the tools that take arguments actually declare them.
    func testPresetToolsCarryRealArgumentSchemas() {
        // Tools that genuinely take no arguments would legitimately have an empty schema, so this
        // checks the ones that certainly do take some rather than asserting over all 16.
        let mustHaveArguments = ["read_file", "glob_files", "edit_code_single", "overwrite_file",
                                 "batch_command", "git_tool", "diff_files"]
        for name in mustHaveArguments {
            guard let tool = CodeToolPreset.defaultTools.first(where: { $0.name == name }) else {
                return XCTFail("\(name) is missing from the preset")
            }
            XCTAssertFalse(tool.parameters.properties.isEmpty,
                "\(name) has an empty argument schema — this is what a workflow Action node binds "
                + "its arguments from, so an empty one silently yields a tool with no arguments")
        }
    }

    /// Descriptions come from the tool, not from a copy in the preset. Pinning equality with the
    /// catalogue is the whole point: a preset that restates a description can drift from what the
    /// tool actually does, and the model is told the preset's version by nothing at all.
    func testDescriptionsComeFromTheCatalogNotACopy() {
        for tool in CodeToolPreset.defaultTools {
            guard let entry = NativeToolCatalog.entry(named: tool.name) else {
                return XCTFail("\(tool.name) is not in the catalogue")
            }
            XCTAssertEqual(tool.description, entry.executable().description,
                           "\(tool.name)'s preset description has drifted from the tool's own")
            XCTAssertFalse(tool.description.trimmingCharacters(in: .whitespaces).isEmpty,
                           "\(tool.name) has a blank description")
        }
    }

    // MARK: - Per-tool config remains the preset's own job

    /// Deriving metadata must not flatten the settings the preset exists to express: the
    /// destructive and shell tools ask first, the read-only ones do not.
    func testDestructiveAndShellToolsAskFirst() {
        let mustConfirm: Set<String> = ["edit_code_single", "edit_code_batch", "create_new_file",
                                        "overwrite_file", "batch_command"]
        let mustNotConfirm: Set<String> = ["read_file", "list_directory", "glob_files",
                                           "find_definition", "git_tool", "diff_files"]

        for tool in CodeToolPreset.defaultTools {
            if mustConfirm.contains(tool.name) {
                XCTAssertTrue(tool.requiresConfirmation, "\(tool.name) must ask before running")
            }
            if mustNotConfirm.contains(tool.name) {
                XCTAssertFalse(tool.requiresConfirmation,
                               "\(tool.name) is read-only — prompting on it trains the user to click through")
            }
        }
    }

    func testEveryPresetToolIsEnabled() {
        for tool in CodeToolPreset.defaultTools {
            XCTAssertTrue(tool.isEnabled, "\(tool.name) is in the preset but disabled")
        }
    }
}
