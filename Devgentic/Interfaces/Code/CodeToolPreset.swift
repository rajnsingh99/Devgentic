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
    static let defaultTools: [Tool] = [
        // MARK: - Core 8

        Tool(name: "read_file", description: "Read file contents from the project.",
             isEnabled: true, requiresConfirmation: false,
             sourceId: builtInSourceID, parameters: ToolParameters(type: "object", properties: [:], required: [])),

        Tool(name: "edit_code", description: "Apply search-and-replace edits to files.",
             isEnabled: true, requiresConfirmation: true,
             sourceId: builtInSourceID, parameters: ToolParameters(type: "object", properties: [:], required: [])),

        Tool(name: "create_file", description: "Create new files with parent directory creation.",
             isEnabled: true, requiresConfirmation: true,
             sourceId: builtInSourceID, parameters: ToolParameters(type: "object", properties: [:], required: [])),

        Tool(name: "code_search", description: "Search file contents using regex patterns.",
             isEnabled: true, requiresConfirmation: false,
             sourceId: builtInSourceID, parameters: ToolParameters(type: "object", properties: [:], required: [])),

        Tool(name: "glob_files", description: "Find files by glob pattern.",
             isEnabled: true, requiresConfirmation: false,
             sourceId: builtInSourceID, parameters: ToolParameters(type: "object", properties: [:], required: [])),

        Tool(name: "batch_command", description: "Execute shell commands with timeout and background support.",
             isEnabled: true, requiresConfirmation: true,
             sourceId: builtInSourceID, parameters: ToolParameters(type: "object", properties: [:], required: [])),

        Tool(name: "git_tool", description: "Git operations: status, log, diff, branch, blame.",
             isEnabled: true, requiresConfirmation: false,
             sourceId: builtInSourceID, parameters: ToolParameters(type: "object", properties: [:], required: [])),

        Tool(name: "list_directory", description: "List directory contents with file types and sizes.",
             isEnabled: true, requiresConfirmation: false,
             sourceId: builtInSourceID, parameters: ToolParameters(type: "object", properties: [:], required: [])),

        // MARK: - Enhancer 4

        Tool(name: "find_definition", description: "Find symbol definitions across the codebase.",
             isEnabled: true, requiresConfirmation: false,
             sourceId: builtInSourceID, parameters: ToolParameters(type: "object", properties: [:], required: [])),

        Tool(name: "file_overview", description: "Structured file analysis with line count, language, and symbols.",
             isEnabled: true, requiresConfirmation: false,
             sourceId: builtInSourceID, parameters: ToolParameters(type: "object", properties: [:], required: [])),

        Tool(name: "codebase_map", description: "High-level repository structure visualization.",
             isEnabled: true, requiresConfirmation: false,
             sourceId: builtInSourceID, parameters: ToolParameters(type: "object", properties: [:], required: [])),

        Tool(name: "diff_files", description: "Unified diff between two files.",
             isEnabled: true, requiresConfirmation: false,
             sourceId: builtInSourceID, parameters: ToolParameters(type: "object", properties: [:], required: [])),
    ]
}
