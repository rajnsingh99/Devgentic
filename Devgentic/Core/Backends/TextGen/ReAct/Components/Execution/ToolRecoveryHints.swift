// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
//
//  ToolRecoveryHints.swift
//  Devgentic
//
//  Created by Raj Singh.
//

import Foundation

/// Static registry mapping (built-in tool name, error pattern) to recovery tool suggestions for failed tool outputs.
/// Applies only to built-in tools and suggests only tools present in the request; first matching hint per tool wins,
/// the failed tool is excluded from its own list, and at most 3 suggestions are rendered.
enum ToolRecoveryHints {

    // MARK: - Registry

    private struct Hint {
        let toolName: String
        let errorSubstring: String
        let suggestions: [String]
    }

    /// Ordered registry of recovery hints. Scanned linearly; first row matching
    /// `(toolName, errorSubstring)` wins. Within a tool, list more specific patterns first.
    private static let registry: [Hint] = [
        // read_file — the canonical hallucination recovery path.
        Hint(toolName: "read_file",      errorSubstring: "File not found",              suggestions: ["list_directory", "glob_files", "project_tree", "code_search_text"]),
        Hint(toolName: "read_file",      errorSubstring: "Error extracting document",   suggestions: ["file_overview", "preview_file"]),

        // edit_code_single / edit_code_batch: three distinct failure modes, each needing a different recovery.
        Hint(toolName: "edit_code_single", errorSubstring: "File not found",           suggestions: ["list_directory", "glob_files", "project_tree"]),
        Hint(toolName: "edit_code_single", errorSubstring: "matches",                  suggestions: ["read_file"]),
        Hint(toolName: "edit_code_single", errorSubstring: "old_string not found",     suggestions: ["read_file", "code_search_text"]),
        Hint(toolName: "edit_code_batch",  errorSubstring: "File not found",           suggestions: ["list_directory", "glob_files", "project_tree"]),
        Hint(toolName: "edit_code_batch",  errorSubstring: "matches",                  suggestions: ["read_file"]),
        Hint(toolName: "edit_code_batch",  errorSubstring: "old_string not found",     suggestions: ["read_file", "code_search_text"]),

        // file_overview — same path-recovery pattern as read_file.
        Hint(toolName: "file_overview",  errorSubstring: "File not found",              suggestions: ["list_directory", "glob_files", "project_tree"]),

        // move_file / copy_file — symmetric: source-missing vs destination-collision.
        Hint(toolName: "move_file",      errorSubstring: "Source path does not exist", suggestions: ["list_directory", "glob_files"]),
        Hint(toolName: "move_file",      errorSubstring: "Destination already exists", suggestions: ["read_file", "list_directory"]),
        Hint(toolName: "copy_file",      errorSubstring: "Source path does not exist", suggestions: ["list_directory", "glob_files"]),
        Hint(toolName: "copy_file",      errorSubstring: "Destination already exists", suggestions: ["read_file", "list_directory"]),

        // delete_file — most likely a path mistake if file is missing.
        Hint(toolName: "delete_file",    errorSubstring: "File not found",              suggestions: ["list_directory", "glob_files"]),

        // create_new_file — strict-new variant. Already-exists means the agent should read
        // current contents and decide between edit_code_single or explicit overwrite_file.
        Hint(toolName: "create_new_file", errorSubstring: "File already exists",        suggestions: ["read_file", "overwrite_file", "edit_code_single"]),

        // Exploration/search tools that take a path argument — always fall back to list_directory
        // (never suggest the tool itself; that would loop).
        Hint(toolName: "project_tree",   errorSubstring: "does not exist",              suggestions: ["list_directory"]),
        Hint(toolName: "code_search_text",   errorSubstring: "does not exist",          suggestions: ["list_directory", "project_tree"]),
        Hint(toolName: "code_search_symbol", errorSubstring: "does not exist",          suggestions: ["list_directory", "project_tree"]),
        Hint(toolName: "code_search_files",  errorSubstring: "does not exist",          suggestions: ["list_directory", "project_tree"]),
        Hint(toolName: "glob_files",     errorSubstring: "does not exist",              suggestions: ["list_directory", "project_tree"]),
        Hint(toolName: "find_definition", errorSubstring: "does not exist",             suggestions: ["list_directory", "project_tree"]),

        // batch_command's working_directory problem is a path-not-found in disguise.
        Hint(toolName: "run_command",    errorSubstring: "working_directory",           suggestions: ["list_directory", "project_tree"]),
        Hint(toolName: "start_background_task", errorSubstring: "working_directory",    suggestions: ["list_directory", "project_tree"]),

        // git guards its path arg before dispatch; same recovery as other path tools.
        Hint(toolName: "git",            errorSubstring: "does not exist",              suggestions: ["list_directory"]),

        // manage_finder_tags — file-level metadata tool; recovery via filename discovery.
        Hint(toolName: "manage_finder_tags", errorSubstring: "File not found",          suggestions: ["list_directory", "glob_files"]),

        // list_directory: usually the first step, not a fallback target; on failure broader views (project_tree) or
        // pattern search (glob_files) help, and a short list keeps the model's next move obvious.
        Hint(toolName: "list_directory", errorSubstring: "Error listing directory",     suggestions: ["project_tree", "glob_files"]),

        // read_file_metadata: failures usually mean a wrong path or an unreadable file; fall back to content-level reads
        // or list the parent directory to verify the path.
        Hint(toolName: "read_file_metadata", errorSubstring: "Error reading metadata",  suggestions: ["read_file", "file_overview", "list_directory"]),

        // diff_files — when diffing fails, read each file independently so the model
        // can reason about differences manually.
        Hint(toolName: "diff_files",    errorSubstring: "Diff error",                   suggestions: ["read_file"]),

        // create_folder — already-exists collision means the directory is real; the
        // model should inspect its contents before deciding what to do.
        Hint(toolName: "create_folder", errorSubstring: "Directory already exists",     suggestions: ["list_directory"]),

        // batch_move_files — when the destination can't be created, creating it
        // explicitly via create_folder first is the clean recovery path.
        Hint(toolName: "batch_move_files", errorSubstring: "Could not create destination folder", suggestions: ["create_folder"]),

        // spotlight_search: path-missing and permission-denied share a substring; broader exploration helps the
        // first and is harmless for the second.
        Hint(toolName: "spotlight_search", errorSubstring: "does not exist",             suggestions: ["list_directory", "project_tree"]),
    ]

    /// Short, action-phrase descriptors rendered alongside each suggestion.
    /// Kept separate from the registry so the same description can be reused across hints.
    private static let toolDescriptors: [String: String] = [
        "list_directory":     "list files in a specific directory",
        "glob_files":         "find files by pattern (e.g. '**/*.java')",
        "project_tree":       "see the full project tree",
        "code_search_text":   "loose regex/text search (case-insensitive) across the codebase",
        "code_search_symbol": "exact whole-word, case-sensitive symbol lookup",
        "code_search_files":  "list files that contain a pattern (filenames only)",
        "read_file":          "read the file's current contents",
        "file_overview":      "get line count + top-level symbols without loading full content",
        "preview_file":       "read just the first/last N lines",
        "edit_code_single":   "apply a single search-and-replace edit",
        "overwrite_file":     "replace an existing file's contents (destructive)"
    ]

    // MARK: - Enrichment

    /// Returns the error enriched with recovery suggestions when a hint matches and a suggested tool is available;
    /// otherwise the original error. Safe on every failed tool: unregistered tools (e.g. MCP) are unchanged.
    /// - Parameters: toolName is the failed tool; availableToolNames lists the tools enabled for the request.
    static func enrich(
        toolName: String,
        originalError: String,
        availableToolNames: Set<String>
    ) -> String {
        // Find the first hint whose (toolName, errorSubstring) matches.
        guard let hint = registry.first(where: {
            $0.toolName == toolName && originalError.contains($0.errorSubstring)
        }) else {
            return originalError
        }

        // Filter suggestions: drop the failed tool itself (anti-loop), keep only tools
        // actually enabled for this request, cap at 3 to avoid menu paralysis.
        let pickable = hint.suggestions
            .filter { $0 != toolName && availableToolNames.contains($0) }
            .prefix(3)

        guard !pickable.isEmpty else {
            // No mapped recovery tool is available: return the original error, since suggesting a tool the model
            // cannot call invites hallucination.
            return originalError
        }

        var enriched = originalError
        enriched += "\n\nTry these available tools to recover:"
        for name in pickable {
            let descriptor = toolDescriptors[name] ?? "available tool"
            enriched += "\n  - \(name): \(descriptor)"
        }
        enriched += "\nDo NOT retry the same call — it will keep failing."
        return enriched
    }
}
