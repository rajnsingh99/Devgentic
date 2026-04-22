//
//  ToolRecoveryHints.swift
//  Devgentic
//
//  Static registry that maps (built-in tool name, error pattern) to a list of recovery
//  tool suggestions. Used by ToolExecutionMediator to enrich failed-tool outputs with
//  actionable next-step hints — but only when the suggested tools are actually present
//  in the current request's available tool set.
//
//  Design principles:
//  - Applies ONLY to built-in local tools. MCP tools are opaque to us — the registry
//    lookup fails silently for unknown tool names, returning the original error unchanged.
//  - Substring match on error output (not regex) — fast and predictable.
//  - First matching hint per tool wins. Order rows most-specific-first when patterns overlap.
//  - Self-exclusion: the failed tool is stripped from its own suggestion list at render time.
//  - Available-intersection: only suggests tools that are enabled in the current request.
//  - Caps rendered output at 3 suggestions to avoid menu-paralysis.
//

import Foundation

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
        Hint(toolName: "read_file",      errorSubstring: "File not found",              suggestions: ["list_directory", "glob_files", "codebase_map", "code_search"]),
        Hint(toolName: "read_file",      errorSubstring: "Error extracting document",   suggestions: ["file_overview", "preview_file"]),

        // edit_code — three distinct failure modes, each needs a different recovery.
        Hint(toolName: "edit_code",      errorSubstring: "File not found",              suggestions: ["list_directory", "glob_files", "codebase_map"]),
        Hint(toolName: "edit_code",      errorSubstring: "old_string matches",          suggestions: ["read_file"]),
        Hint(toolName: "edit_code",      errorSubstring: "old_string not found",        suggestions: ["read_file", "code_search"]),

        // edit_code_single / edit_code_batch (Code interface splits) — mirror edit_code's patterns,
        // but suggest search tools that are actually in the Code preset (code_search_text / _symbol).
        Hint(toolName: "edit_code_single", errorSubstring: "File not found",           suggestions: ["list_directory", "glob_files", "codebase_map"]),
        Hint(toolName: "edit_code_single", errorSubstring: "matches",                  suggestions: ["read_file"]),
        Hint(toolName: "edit_code_single", errorSubstring: "old_string not found",     suggestions: ["read_file", "code_search_text"]),
        Hint(toolName: "edit_code_batch",  errorSubstring: "File not found",           suggestions: ["list_directory", "glob_files", "codebase_map"]),
        Hint(toolName: "edit_code_batch",  errorSubstring: "matches",                  suggestions: ["read_file"]),
        Hint(toolName: "edit_code_batch",  errorSubstring: "old_string not found",     suggestions: ["read_file", "code_search_text"]),

        // file_overview — same path-recovery pattern as read_file.
        Hint(toolName: "file_overview",  errorSubstring: "File not found",              suggestions: ["list_directory", "glob_files", "codebase_map"]),

        // move_file / copy_file — symmetric: source-missing vs destination-collision.
        Hint(toolName: "move_file",      errorSubstring: "Source path does not exist", suggestions: ["list_directory", "glob_files"]),
        Hint(toolName: "move_file",      errorSubstring: "Destination already exists", suggestions: ["read_file", "list_directory"]),
        Hint(toolName: "copy_file",      errorSubstring: "Source path does not exist", suggestions: ["list_directory", "glob_files"]),
        Hint(toolName: "copy_file",      errorSubstring: "Destination already exists", suggestions: ["read_file", "list_directory"]),

        // delete_file — most likely a path mistake if file is missing.
        Hint(toolName: "delete_file",    errorSubstring: "File not found",              suggestions: ["list_directory", "glob_files"]),

        // create_file — already-exists is a signal to read current content before overwriting.
        Hint(toolName: "create_file",    errorSubstring: "File already exists",         suggestions: ["read_file"]),

        // create_new_file — strict-new variant. Already-exists means the agent should read
        // current contents and decide between edit_code_single or explicit overwrite_file.
        Hint(toolName: "create_new_file", errorSubstring: "File already exists",        suggestions: ["read_file", "overwrite_file", "edit_code_single"]),

        // Exploration/search tools that take a path argument — always fall back to list_directory
        // (never suggest the tool itself; that would loop).
        Hint(toolName: "codebase_map",   errorSubstring: "does not exist",              suggestions: ["list_directory"]),
        Hint(toolName: "code_search",    errorSubstring: "does not exist",              suggestions: ["list_directory", "codebase_map"]),
        Hint(toolName: "code_search_text",   errorSubstring: "does not exist",          suggestions: ["list_directory", "codebase_map"]),
        Hint(toolName: "code_search_symbol", errorSubstring: "does not exist",          suggestions: ["list_directory", "codebase_map"]),
        Hint(toolName: "code_search_files",  errorSubstring: "does not exist",          suggestions: ["list_directory", "codebase_map"]),
        Hint(toolName: "glob_files",     errorSubstring: "does not exist",              suggestions: ["list_directory", "codebase_map"]),
        Hint(toolName: "find_definition", errorSubstring: "does not exist",             suggestions: ["list_directory", "codebase_map"]),

        // batch_command's working_directory problem is a path-not-found in disguise.
        Hint(toolName: "batch_command",  errorSubstring: "working_directory",           suggestions: ["list_directory", "codebase_map"]),

        // git_tool guards its path arg before dispatch; same recovery as other path tools.
        Hint(toolName: "git_tool",       errorSubstring: "does not exist",              suggestions: ["list_directory"]),

        // finder_tags — file-level metadata tool; recovery via filename discovery.
        Hint(toolName: "finder_tags",    errorSubstring: "File not found",              suggestions: ["list_directory", "glob_files"]),

        // list_directory — generally a top-level call; when it fails (bad path, permission)
        // the useful recoveries are broader views (codebase_map) or pattern search (glob_files).
        // Kept intentionally minimal since list_directory is usually the first step, not a
        // fallback target, so a short suggestion list keeps the model's next move obvious.
        Hint(toolName: "list_directory", errorSubstring: "Error listing directory",     suggestions: ["codebase_map", "glob_files"]),

        // execute_shell — legacy single-shot shell. batch_command is a richer superset
        // (timeout, working_directory, background, output cap); hint the model to use it
        // when simple execution fails.
        Hint(toolName: "execute_shell", errorSubstring: "Command failed",               suggestions: ["batch_command"]),

        // grep_files — classic grep wrapper. code_search is a structured ripgrep-backed
        // alternative with richer output; glob_files is the right fallback for "find by
        // name/pattern" rather than content.
        Hint(toolName: "grep_files",    errorSubstring: "Grep error",                   suggestions: ["code_search", "glob_files"]),

        // fs_read_metadata — metadata read failures usually mean the path is wrong or
        // the file is unreadable. Fall back to content-level reads that may bypass the
        // metadata quirk, or list the parent dir to verify the path.
        Hint(toolName: "fs_read_metadata", errorSubstring: "Error reading metadata",    suggestions: ["read_file", "file_overview", "list_directory"]),

        // diff_files — when diffing fails, read each file independently so the model
        // can reason about differences manually.
        Hint(toolName: "diff_files",    errorSubstring: "Diff error",                   suggestions: ["read_file"]),

        // create_folder — already-exists collision means the directory is real; the
        // model should inspect its contents before deciding what to do.
        Hint(toolName: "create_folder", errorSubstring: "Directory already exists",     suggestions: ["list_directory"]),

        // fs_organize_batch — when the destination can't be created, creating it
        // explicitly via create_folder first is the clean recovery path.
        Hint(toolName: "fs_organize_batch", errorSubstring: "Could not create destination folder", suggestions: ["create_folder"]),

        // fs_smart_search — both path-missing and permission-denied land on the same
        // substring; recovery via broader exploration works for the path-missing case
        // and is harmless for permission (model sees bare error + suggestion that won't
        // itself error if tools exist).
        Hint(toolName: "fs_smart_search", errorSubstring: "does not exist",             suggestions: ["list_directory", "codebase_map"]),
    ]

    /// Short, action-phrase descriptors rendered alongside each suggestion.
    /// Kept separate from the registry so the same description can be reused across hints.
    private static let toolDescriptors: [String: String] = [
        "list_directory":     "list files in a specific directory",
        "glob_files":         "find files by pattern (e.g. '**/*.java')",
        "codebase_map":       "see the full project tree",
        "code_search":        "regex-search content across the codebase",
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

    /// Returns an enriched version of the error string if a matching hint exists AND at least
    /// one suggested tool is present in the request's available tool set. Otherwise returns
    /// the original error unchanged.
    ///
    /// Enrichment is safe to call on every failed tool — non-registered tools (e.g., MCP) and
    /// unrecognized error patterns produce no output change.
    ///
    /// - Parameters:
    ///   - toolName: the tool whose call just failed
    ///   - originalError: the raw error string returned by the tool's `call(arguments:)`
    ///   - availableToolNames: names of all tools enabled for the current request
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
            // Model doesn't have access to any of the mapped recovery tools — return the
            // original error. Inventing a suggestion for a tool the model can't call would
            // cause hallucination (the exact failure mode we're trying to prevent).
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
