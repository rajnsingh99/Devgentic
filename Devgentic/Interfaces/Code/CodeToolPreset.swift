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
        preset("codebase_map"),
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
        preset("batch_command", confirms: true),
        preset("git_tool"),
        preset("diff_files"),
    ].compactMap { $0 }

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

    /// Names of tools hidden from the Tool Library when it is opened for a Code profile.
    ///
    /// Two groups, both DERIVED as of 2026-07-31 — neither is a list maintained here:
    ///
    /// 1. **The preset's own tools.** Hidden so the user cannot disable what the preset
    ///    guarantees. Taken from `defaultTools`, which is this type's actual job.
    /// 2. **Library tools the preset supersedes** — `edit_code`, `code_search`, `create_file`,
    ///    `write_file`, `execute_shell`. Offering these to a Code agent alongside the narrower
    ///    tools that replaced them would hand it several shapes for one intent, which is the
    ///    confusion the splits were introduced to prevent. This group used to be a `Set` literal
    ///    right here, so the reason a tool was hidden lived in a comment rather than beside the
    ///    tool; it now comes from `NativeToolCatalog`, where each entry names what supersedes it.
    ///
    /// Chat and Workflow profiles still see group 2 — being superseded is a fact about the CODE
    /// interface, not about the tool.
    static let hiddenToolNames: Set<String> = {
        Set(defaultTools.map(\.name)).union(NativeToolCatalog.hiddenFromCodeLibrary)
    }()
}
