//
//  CodeToolPreset.swift
//  Devgentic
//
//  Pre-configured tool set for the Code interface.
//  These 12 tools are auto-enabled — users don't need to configure them.
//

import Foundation

enum CodeToolPreset {

    /// The fixed source UUID for built-in tools (matches UnifiedToolStore's built-in ID).
    private static let builtInSourceID = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!

    /// Default coding tools — auto-enabled in every Code session.
    /// NOTE: edit_code / code_search / create_file are deliberately split into intent-specific
    /// variants that carry no behavior-changing booleans — small models can't silently mis-set
    /// a toggle. The Code-only split tools are NOT listed in the Tool Library (they are not
    /// registered with LocalToolManager); chat & workflow continue using the original trio.
    static let defaultTools: [Tool] = [
        // MARK: - Read & Navigate

        Tool(name: "read_file", description: "Read file contents from the project.",
             isEnabled: true, requiresConfirmation: false,
             sourceId: builtInSourceID, parameters: ToolParameters(type: "object", properties: [:], required: [])),

        Tool(name: "list_directory", description: "List directory contents with file types and sizes.",
             isEnabled: true, requiresConfirmation: false,
             sourceId: builtInSourceID, parameters: ToolParameters(type: "object", properties: [:], required: [])),

        Tool(name: "codebase_map", description: "High-level repository structure visualization.",
             isEnabled: true, requiresConfirmation: false,
             sourceId: builtInSourceID, parameters: ToolParameters(type: "object", properties: [:], required: [])),

        Tool(name: "glob_files", description: "Find files by glob pattern.",
             isEnabled: true, requiresConfirmation: false,
             sourceId: builtInSourceID, parameters: ToolParameters(type: "object", properties: [:], required: [])),

        Tool(name: "find_definition", description: "Find symbol definitions across the codebase.",
             isEnabled: true, requiresConfirmation: false,
             sourceId: builtInSourceID, parameters: ToolParameters(type: "object", properties: [:], required: [])),

        Tool(name: "file_overview", description: "Structured file analysis with line count, language, and symbols.",
             isEnabled: true, requiresConfirmation: false,
             sourceId: builtInSourceID, parameters: ToolParameters(type: "object", properties: [:], required: [])),

        // MARK: - Search (split from code_search — no behavior toggles)

        Tool(name: "code_search_text", description: "Loose text/regex search (case-insensitive, substring) with context lines.",
             isEnabled: true, requiresConfirmation: false,
             sourceId: builtInSourceID, parameters: ToolParameters(type: "object", properties: [:], required: [])),

        Tool(name: "code_search_symbol", description: "Exact symbol lookup (case-sensitive, whole-word).",
             isEnabled: true, requiresConfirmation: false,
             sourceId: builtInSourceID, parameters: ToolParameters(type: "object", properties: [:], required: [])),

        Tool(name: "code_search_files", description: "List files that contain a pattern (filenames only, no content).",
             isEnabled: true, requiresConfirmation: false,
             sourceId: builtInSourceID, parameters: ToolParameters(type: "object", properties: [:], required: [])),

        // MARK: - Edit (split from edit_code — single shape per tool)

        Tool(name: "edit_code_single", description: "Apply ONE search-and-replace edit to a file.",
             isEnabled: true, requiresConfirmation: true,
             sourceId: builtInSourceID, parameters: ToolParameters(type: "object", properties: [:], required: [])),

        Tool(name: "edit_code_batch", description: "Apply MULTIPLE atomic edits to a single file in one call.",
             isEnabled: true, requiresConfirmation: true,
             sourceId: builtInSourceID, parameters: ToolParameters(type: "object", properties: [:], required: [])),

        // MARK: - Create / Overwrite (split from create_file — explicit destructive intent)

        Tool(name: "create_new_file", description: "Create a brand-new file. Fails if the file already exists.",
             isEnabled: true, requiresConfirmation: true,
             sourceId: builtInSourceID, parameters: ToolParameters(type: "object", properties: [:], required: [])),

        Tool(name: "overwrite_file", description: "Replace an existing file's entire contents. Destructive.",
             isEnabled: true, requiresConfirmation: true,
             sourceId: builtInSourceID, parameters: ToolParameters(type: "object", properties: [:], required: [])),

        // MARK: - Shell / VCS / Compare

        Tool(name: "batch_command", description: "Execute shell commands with timeout and background support.",
             isEnabled: true, requiresConfirmation: true,
             sourceId: builtInSourceID, parameters: ToolParameters(type: "object", properties: [:], required: [])),

        Tool(name: "git_tool", description: "Git operations: status, log, diff, branch, blame.",
             isEnabled: true, requiresConfirmation: false,
             sourceId: builtInSourceID, parameters: ToolParameters(type: "object", properties: [:], required: [])),

        Tool(name: "diff_files", description: "Unified diff between two files.",
             isEnabled: true, requiresConfirmation: false,
             sourceId: builtInSourceID, parameters: ToolParameters(type: "object", properties: [:], required: [])),
    ]

    /// Names of tools that should be hidden from the Tool Library when it is opened
    /// for a Code profile.
    ///
    /// Covers three groups:
    /// 1. Preset built-ins (`read_file`, `batch_command`, `git_tool`, …) — part of the
    ///    active preset; hidden so the user can't disable them.
    /// 2. Code-only splits (`edit_code_single`, `code_search_text`, …) — preset too;
    ///    already invisible via `LocalToolManager`, listed here for completeness.
    /// 3. The originals replaced by the splits (`edit_code`, `code_search`, `create_file`)
    ///    — surfacing them alongside the splits would give the agent duplicate shapes
    ///    for the same intent and re-introduce the toggle-hallucination risk the splits
    ///    were designed to avoid. Chat / Workflow profiles still see these originals.
    /// 4. Behavioral overlaps with preset tools (`write_file`, `execute_shell`)
    ///    — if the user added these from the library, the Code agent would face two
    ///    shell runners (write_file also has an `append` bool) competing with the
    ///    opinionated preset. Hidden here to preserve the split-tools guarantee.
    static let hiddenToolNames: Set<String> = {
        var names = Set(defaultTools.map(\.name))
        names.formUnion([
            // Originals superseded by Code-only splits.
            "edit_code", "code_search", "create_file",
            // Behavioral overlaps with the preset.
            "write_file", "execute_shell"
        ])
        return names
    }()
}
