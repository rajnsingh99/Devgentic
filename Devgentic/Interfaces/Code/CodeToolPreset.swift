// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
//
//  CodeToolPreset.swift
//  Devgentic
//
//  Pre-configured tool set for the Code interface.
//  These 12 tools are auto-enabled — users don't need to configure them.
//

import Foundation
import os

private let logger = DGLogger(category: "CodeToolPreset")

enum CodeToolPreset {

    /// The fixed source UUID for built-in tools (matches UnifiedToolStore's built-in ID).
    /// Aliased to the canonical constant — this was the third re-spelled copy of the UUID.
    private static let builtInSourceID = ToolSource.builtInSourceID

    /// Default coding tools — auto-enabled in every Code session.
    ///
    /// Each line names a tool and, where it differs from the default, whether it asks first.
    /// **Description and argument schema are NOT restated here** — they come from
    /// `NativeToolCatalog`, so the preset cannot drift from what the tool actually is.
    ///
    /// Before 2026-07-31 every entry carried a hand-written description and an EMPTY
    /// `ToolParameters`. The descriptions were dead text (resolution reads the tool's own, via
    /// `AgentToolFactory`), and the empty schemas were a latent trap: harmless for Code profiles,
    /// which never read them, but `Tool.parameters` is what a workflow Action node binds its
    /// arguments from — so the shape was one reuse away from producing a tool with no arguments.
    ///
    /// `edit_code` / `code_search` / `create_file` are deliberately absent: the Code interface
    /// uses intent-specific splits that carry no behaviour-changing booleans, so a small model
    /// cannot silently mis-set a toggle. Chat and Workflow keep the originals — see
    /// `NativeToolVisibility.libraryExceptCode`.
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
        // Reading a task's state is not a side effect, and stopping one only ends work this agent
        // itself started — unlike `batch_command`, which runs arbitrary code. Confirming these
        // would teach the user to approve without reading, which is what the 2026-07-31
        // manage_processes/kill_process split was about.
        preset("get_task_output"),
        preset("stop_background_task"),
        preset("git"),
        preset("diff_files"),
    ].compactMap { $0 }

    /// Whether a tool the Code pipeline INJECTS at run time must park on an approval banner.
    ///
    /// `defaultTools` above declares this for every user-visible preset tool. The memory tools
    /// (`remember`, `forget`, `recall`) are not in that list — `AgentConnect` appends them per run
    /// with the project path baked in — so their answer lives here rather than as a bare literal
    /// at that call site.
    ///
    /// All `false` (2026-10-06). Their predecessor, `update_project_context`, parked on a diff
    /// banner because it rewrote one whole file that every later conversation read, unchecked.
    /// `remember` writes one small entry and refuses unverified claims itself (a command must
    /// have exited 0 in the conversation, files must exist); a mid-task banner for that was
    /// friction without a review it could add. Phase 2's Memory panel is where entries are
    /// reviewed and undone.
    static func injectedToolRequiresConfirmation(_ toolName: String) -> Bool { false }

    /// Builds a preset entry from the catalogue.
    ///
    /// Returns nil for a name the catalogue does not know. That is a programming error — a preset
    /// naming a tool that does not exist — so it trips an assertion in debug builds and is logged
    /// and skipped in release, rather than crashing an app at launch over one misconfigured tool.
    /// `CodeToolPresetTests` asserts the list is complete, so the release path should never run.
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
    ///
    /// Library tools the preset supersedes (if any) are hidden so the model is not offered
    /// duplicate shapes for one intent. Core preset tools are no longer hidden — they are shown
    /// with locked status so users can inspect them and configure execution modes.
    static let hiddenToolNames: Set<String> = {
        NativeToolCatalog.hiddenFromCodeLibrary
    }()
}

