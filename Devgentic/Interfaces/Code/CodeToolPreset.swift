// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
//
//  CodeToolPreset.swift
//  Devgentic
//
//  Created by Raj Singh.
//

import Foundation
import os

private let logger = DGLogger(category: "CodeToolPreset")

/// Pre-configured tool set for the Code interface; these tools are auto-enabled, so users need not configure them.
enum CodeToolPreset {

    /// The fixed source UUID for built-in tools (matches UnifiedToolStore's built-in ID).
    /// Aliased to the canonical constant — this was the third re-spelled copy of the UUID.
    private static let builtInSourceID = ToolSource.builtInSourceID

    /// Default coding tools, auto-enabled in every Code session; each line names a tool and whether it asks first.
    /// Description and argument schema come from `NativeToolCatalog`, so the preset cannot drift from the tool.
    /// `edit_code`, `code_search` and `create_file` are absent: Code uses intent-specific splits without behaviour booleans.
    static let defaultTools: [Tool] = [
        // MARK: - Read & Navigate
        preset("read_file"),
        preset("list_directory"),
        preset("project_tree"),
        preset("glob_files"),
        preset("find_definition"),
        preset("file_overview"),
        // MARK: - Search (split from code_search — no behavior toggles)
        preset("code_search_text"),
        preset("code_search_symbol"),
        preset("code_search_files"),
        // MARK: - Edit (split from edit_code — single shape per tool)
        preset("edit_code_single", confirms: true),
        preset("edit_code_batch", confirms: true),
        // MARK: - Create / Overwrite (split from create_file — explicit destructive intent)
        preset("create_new_file", confirms: true),
        preset("overwrite_file", confirms: true),
        // MARK: - Shell / VCS / Compare
        preset("run_command", confirms: true),
        preset("start_background_task", confirms: true),
        // Reading a task's state is not a side effect, and stopping only ends work this agent started (unlike `batch_command`),
        // so confirming these would teach the user to approve without reading.
        preset("get_task_output"),
        preset("stop_background_task"),
        preset("git"),
        preset("diff_files"),
    ].compactMap { $0 }

    /// Whether a tool the Code pipeline injects at run time must park on an approval banner.
    /// The memory tools (`remember`, `forget`, `recall`) are appended per run by `AgentConnect`, so their answer lives here.
    /// All false: `remember` writes one small entry and refuses unverified claims itself, so a banner adds only friction.
    static func injectedToolRequiresConfirmation(_ toolName: String) -> Bool { false }

    /// Builds a preset entry from the catalogue; returns nil for a name the catalogue does not know.
    /// That is a programming error: it asserts in debug builds and is logged and skipped in release, not a launch crash.
    private static func preset(_ name: String, confirms requiresConfirmation: Bool = false) -> Tool? {
        guard let entry = NativeToolCatalog.entry(named: name) else {
            assertionFailure("CodeToolPreset names '\(name)', which is not in NativeToolCatalog")
            logger.error("CodeToolPreset names '\(name)', which is not in NativeToolCatalog — omitted from the preset")
            return nil
        }
        let tool = entry.executable()
        return Tool(
            name: tool.name,
            description: tool.description,
            isEnabled: true,
            requiresConfirmation: requiresConfirmation,
            sourceId: builtInSourceID,
            parameters: tool.parameters
        )
    }

    /// Names of core preset tools that are always enabled for a Code profile and cannot be disabled.
    static let lockedToolNames: Set<String> = {
        Set(defaultTools.map(\.name))
    }()

    /// Names of tools hidden from the Tool Library when it is opened for a Code profile.
    /// Library tools the preset supersedes are hidden to avoid duplicate shapes; core preset tools show as locked.
    static let hiddenToolNames: Set<String> = {
        NativeToolCatalog.hiddenFromCodeLibrary
    }()
}

