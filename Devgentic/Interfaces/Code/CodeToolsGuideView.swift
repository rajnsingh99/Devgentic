// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2026 Raj Singh
//
//  CodeToolsGuideView.swift
//  Devgentic
//
//  Premium macOS split-view guide highlighting the built-in tools assigned to the Code interface.
//
//  ⚠️ `tools` below is a HAND-MAINTAINED SECOND LIST of what `CodeToolPreset` grants — the shape
//  `NativeToolCatalog` exists to remove. It stays hand-written because it carries prose the
//  catalogue has no room for (`whySplit`, per-parameter detail), but it is `static` and internal
//  so `CodeToolsGuideDriftTests` can assert every preset tool has an entry. It had neither when
//  three tools were added on 2026-09-21 and the guide silently kept describing sixteen.
//  Details each tool's domain, description, parameters, and confirmation safety policy.
//

import SwiftUI
import AppKit

struct CodeToolsGuideView: View {

    @Environment(\.dismiss) private var dismiss
    @Environment(\.appTheme) private var theme

    @State private var searchText: String = ""
    @State private var selectedFilter: FilterSelection = .all

    enum FilterSelection: Hashable, Identifiable {
        case all
        case domain(ToolCategory)
        case policy(SafetyPolicy)

        var id: String {
            switch self {
            case .all:               return "all"
            case .domain(let cat):   return "cat_\(cat.rawValue)"
            case .policy(let pol):   return "pol_\(pol.rawValue)"
            }
        }
    }

    enum ToolCategory: String, CaseIterable, Identifiable {
        case read = "Read & Navigate"
        case search = "Code Search"
        case edit = "Precision Editing"
        case file = "File Operations"
        case vcs = "Shell & VCS"

        var id: String { rawValue }

        var icon: String {
            switch self {
            case .read:   return "doc.text.magnifyingglass"
            case .search: return "magnifyingglass"
            case .edit:   return "pencil.line"
            case .file:   return "folder.badge.plus"
            case .vcs:    return "terminal"
            }
        }

        var color: Color {
            switch self {
            case .read:   return .blue
            case .search: return .cyan
            case .edit:   return .orange
            case .file:   return .green
            case .vcs:    return .purple
            }
        }
    }

    enum SafetyPolicy: String, CaseIterable, Identifiable {
        case autoApproved = "Auto-Approved"
        case requiresApproval = "Requires Approval"

        var id: String { rawValue }

        var icon: String {
            switch self {
            case .autoApproved:      return "bolt.fill"
            case .requiresApproval:  return "shield.lefthalf.filled"
            }
        }

        var color: Color {
            switch self {
            case .autoApproved:      return .green
            case .requiresApproval:  return .orange
            }
        }
    }

    struct CodeToolItem: Identifiable {
        let id: String
        let name: String
        let category: ToolCategory
        let description: String
        let parameters: [(name: String, type: String, required: Bool, detail: String)]
        let requiresConfirmation: Bool
        let whySplit: String?
    }

    static let tools: [CodeToolItem] = [
        // MARK: - Read & Navigate
        CodeToolItem(
            id: "read_file",
            name: "read_file",
            category: .read,
            description: "Reads file content with 1-based line numbering. Supports targeted line slices via offset and limit to conserve context window.",
            parameters: [
                ("file_path", "string", true, "Target file path"),
                ("offset", "integer", false, "Start line index (1-indexed)"),
                ("limit", "integer", false, "Maximum lines to read")
            ],
            requiresConfirmation: false,
            whySplit: nil
        ),
        CodeToolItem(
            id: "list_directory",
            name: "list_directory",
            category: .read,
            description: "Lists directory contents including file names, types (file/directory), byte sizes, and recursive child counts.",
            parameters: [
                ("directory_path", "string", true, "Target directory path"),
                ("recursive", "boolean", false, "Traverse subdirectories recursively"),
                ("max_depth", "integer", false, "Maximum recursion depth")
            ],
            requiresConfirmation: false,
            whySplit: nil
        ),
        CodeToolItem(
            id: "project_tree",
            name: "project_tree",
            category: .read,
            description: "Generates an architectural tree map of the workspace, automatically excluding build artifacts, caches, and git metadata.",
            parameters: [
                ("path", "string", true, "Project root directory"),
                ("max_depth", "integer", false, "Maximum tree depth")
            ],
            requiresConfirmation: false,
            whySplit: nil
        ),
        CodeToolItem(
            id: "glob_files",
            name: "glob_files",
            category: .read,
            description: "Fast pattern matching across the repository using glob syntax (e.g. '**/*.swift', 'src/**/*.tsx') for instant file discovery.",
            parameters: [
                ("pattern", "string", true, "Glob pattern to match"),
                ("path", "string", true, "Directory to evaluate glob in")
            ],
            requiresConfirmation: false,
            whySplit: nil
        ),
        CodeToolItem(
            id: "find_definition",
            name: "find_definition",
            category: .read,
            description: "Locates declarations of functions, classes, structs, enums, protocols, and variables across the entire project.",
            parameters: [
                ("symbol", "string", true, "Symbol identifier to find"),
                ("path", "string", true, "Project root directory")
            ],
            requiresConfirmation: false,
            whySplit: nil
        ),
        CodeToolItem(
            id: "file_overview",
            name: "file_overview",
            category: .read,
            description: "Produces a structural outline of a source file (types, methods, properties, imports) without loading raw file text into context.",
            parameters: [
                ("file_path", "string", true, "Source file to outline")
            ],
            requiresConfirmation: false,
            whySplit: nil
        ),

        // MARK: - Search
        CodeToolItem(
            id: "code_search_text",
            name: "code_search_text",
            category: .search,
            description: "Ripgrep regex or substring search across file contents with 2 lines of surrounding context. Best for finding TODOs, keywords, and API calls.",
            parameters: [
                ("pattern", "string", true, "Regex or literal text"),
                ("path", "string", true, "Search root directory"),
                ("glob", "string", false, "File filter (e.g. '*.swift')"),
                ("max_results", "integer", false, "Max lines (default 50)")
            ],
            requiresConfirmation: false,
            whySplit: "Split from code_search to remove confusing boolean flags so smaller models search reliably."
        ),
        CodeToolItem(
            id: "code_search_symbol",
            name: "code_search_symbol",
            category: .search,
            description: "Exact whole-word, case-sensitive symbol search. Guarantees 'User' will not match 'Username' or 'UserSession'.",
            parameters: [
                ("pattern", "string", true, "Exact identifier name"),
                ("path", "string", true, "Search root directory"),
                ("glob", "string", false, "File filter (e.g. '*.ts')"),
                ("max_results", "integer", false, "Max matches to return")
            ],
            requiresConfirmation: false,
            whySplit: "Pins case-sensitive whole-word matching at the tool level to prevent false positives."
        ),
        CodeToolItem(
            id: "code_search_files",
            name: "code_search_files",
            category: .search,
            description: "Returns only the filenames of files containing a pattern, saving token context when line content isn't needed.",
            parameters: [
                ("pattern", "string", true, "Pattern to match inside files"),
                ("path", "string", true, "Search root directory"),
                ("glob", "string", false, "File filter")
            ],
            requiresConfirmation: false,
            whySplit: "Pins files-only mode so the model receives an efficient compact path list."
        ),

        // MARK: - Editing
        CodeToolItem(
            id: "edit_code_single",
            name: "edit_code_single",
            category: .edit,
            description: "Applies ONE search-and-replace edit to a file. Requires old_string to appear exactly once in the file for strict uniqueness.",
            parameters: [
                ("file_path", "string", true, "File path to modify"),
                ("old_string", "string", true, "Exact unique code block to find"),
                ("new_string", "string", true, "Replacement code (empty to delete)")
            ],
            requiresConfirmation: true,
            whySplit: "Enforces exact single-region matching to guarantee no other blocks are corrupted."
        ),
        CodeToolItem(
            id: "edit_code_batch",
            name: "edit_code_batch",
            category: .edit,
            description: "Applies multiple search-and-replace edits to a file in a single atomic operation with rollback if any block fails.",
            parameters: [
                ("file_path", "string", true, "File path to modify"),
                ("edits", "array<object>", true, "Array of {old_string, new_string} blocks")
            ],
            requiresConfirmation: true,
            whySplit: "Provides atomic multi-edit transactions in a single turn without intermediate file inconsistencies."
        ),

        // MARK: - File Ops
        CodeToolItem(
            id: "create_new_file",
            name: "create_new_file",
            category: .file,
            description: "Creates a brand-new file and builds parent directories. Strictly fails if a file already exists at that path.",
            parameters: [
                ("file_path", "string", true, "New file path to create"),
                ("content", "string", true, "Complete content to write")
            ],
            requiresConfirmation: true,
            whySplit: "Guarantees no existing files are accidentally truncated or overwritten during creation."
        ),
        CodeToolItem(
            id: "overwrite_file",
            name: "overwrite_file",
            category: .file,
            description: "Replaces an existing file's contents entirely with new content. Discards previous file content.",
            parameters: [
                ("file_path", "string", true, "Existing file path to overwrite"),
                ("content", "string", true, "New complete content")
            ],
            requiresConfirmation: true,
            whySplit: "Explicit destructive intent separated from file creation for security."
        ),

        // MARK: - Shell & VCS
        CodeToolItem(
            id: "run_command",
            name: "run_command",
            category: .vcs,
            description: "Runs a terminal command and WAITS for it, returning the output. Builds, tests, linters — anything whose result you need.",
            parameters: [
                ("command", "string", true, "Shell command or script to run"),
                ("working_directory", "string", true, "Working directory path"),
                ("timeout_seconds", "integer", false, "Max seconds to wait, up to 900 (default 30)")
            ],
            requiresConfirmation: true,
            whySplit: "Split from batch_command: a `background` boolean made one tool serve two intents, and the mode had to be explained in 270 characters of prose the tool name now carries for free."
        ),
        CodeToolItem(
            id: "start_background_task",
            name: "start_background_task",
            category: .vcs,
            description: "Starts a command and returns immediately with a task id, without waiting. For something left running — a dev server, a watcher.",
            parameters: [
                ("command", "string", true, "Shell command to start"),
                ("working_directory", "string", true, "Working directory path"),
                ("timeout_seconds", "integer", false, "Seconds before the task is killed, up to 900 (default 900)")
            ],
            requiresConfirmation: true,
            whySplit: "The other half of the batch_command split. It runs unattended, so its timeout is the only thing that stops a runaway."
        ),
        CodeToolItem(
            id: "git",
            name: "git",
            category: .vcs,
            description: "Structured Git operations: status, log, diff, branch, stash_list, blame, and commit inspection.",
            parameters: [
                ("action", "string", true, "'status', 'log', 'diff', 'branch', 'stash_list', 'blame', 'show'"),
                ("path", "string", true, "Repository directory path"),
                ("args", "string", false, "Optional arguments (e.g. '-n 5' for log)")
            ],
            requiresConfirmation: false,
            whySplit: nil
        ),
        CodeToolItem(
            id: "diff_files",
            name: "diff_files",
            category: .vcs,
            description: "Compares two files or revisions and returns a unified diff (diff -u) showing line-by-line differences.",
            parameters: [
                ("file_a", "string", true, "Path to the first file"),
                ("file_b", "string", true, "Path to the second file")
            ],
            requiresConfirmation: false,
            whySplit: nil
        ),

        // MARK: - Background tasks
        CodeToolItem(
            id: "get_task_output",
            name: "get_task_output",
            category: .vcs,
            description: "Reads what a background command has written so far. Pass since_line to get only what is new since the last read.",
            parameters: [
                ("task_id", "string", true, "Task whose output to read (e.g. 'bg_1')"),
                ("since_line", "integer", false, "Start from this line, as reported by the previous read")
            ],
            requiresConfirmation: false,
            whySplit: "Background output used to go to /dev/null; it is captured to a log file now and read through here."
        ),
        CodeToolItem(
            id: "stop_background_task",
            name: "stop_background_task",
            category: .vcs,
            description: "Ends a background command early. Output up to that point is kept and can still be read.",
            parameters: [
                ("task_id", "string", true, "Task to end (e.g. 'bg_1')")
            ],
            requiresConfirmation: false,
            whySplit: "Only ends work this agent itself started, unlike kill_process which takes any target."
        )
    ]

    private var filteredTools: [CodeToolItem] {
        var list = Self.tools

        switch selectedFilter {
        case .all:
            break
        case .domain(let cat):
            list = list.filter { $0.category == cat }
        case .policy(let pol):
            list = list.filter {
                pol == .requiresApproval ? $0.requiresConfirmation : !$0.requiresConfirmation
            }
        }

        if !searchText.isEmpty {
            let q = searchText.lowercased()
            list = list.filter {
                $0.name.lowercased().contains(q) ||
                $0.description.lowercased().contains(q) ||
                $0.category.rawValue.lowercased().contains(q) ||
                ($0.whySplit?.lowercased().contains(q) ?? false) ||
                $0.parameters.contains { $0.name.lowercased().contains(q) }
            }
        }

        return list
    }

    var body: some View {
        HStack(spacing: 0) {
            // Left Master Sidebar (Navigation & Filters)
            sidebarView
                .frame(width: 240)
                .background(theme.secondaryBackground.opacity(0.85))

            // Subtle Vertical Divider
            Rectangle()
                .fill(theme.dividerColor.opacity(0.35))
                .frame(width: 1)

            // Right Detail Content Area
            detailContentView
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(theme.primaryBackground)
        }
        .frame(minWidth: 860, idealWidth: 920, maxWidth: 1040, minHeight: 580, idealHeight: 640, maxHeight: 820)
    }

    // MARK: - Sidebar View

    private var sidebarView: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Sidebar Header Branding
            HStack(spacing: 10) {
                ZStack {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(theme.accentColor.opacity(0.15))
                        .frame(width: 32, height: 32)
                    Image(systemName: "chevron.left.forwardslash.chevron.right")
                        .font(.system(size: 14, weight: .bold))
                        .foregroundColor(theme.accentColor)
                }

                VStack(alignment: .leading, spacing: 1) {
                    Text("Code Tools")
                        .font(.system(size: 14, weight: .bold))
                        .foregroundColor(theme.primaryText)
                    Text("16 Built-in Tools")
                        .font(.system(size: 10.5, weight: .medium))
                        .foregroundColor(theme.secondaryText)
                }

                Spacer()
            }
            .padding(.horizontal, 16)
            .padding(.top, 18)
            .padding(.bottom, 12)

            // Search Bar in Sidebar
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 11))
                    .foregroundColor(theme.secondaryText)
                TextField("Search tools...", text: $searchText)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12))
                if !searchText.isEmpty {
                    Button(action: { searchText = "" }) {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 10))
                            .foregroundColor(theme.secondaryText)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .background(theme.surfaceOverlay)
            .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .stroke(theme.dividerColor.opacity(0.3), lineWidth: 0.8)
            )
            .padding(.horizontal, 12)
            .padding(.bottom, 12)

            // Filter List
            ScrollView {
                VStack(alignment: .leading, spacing: 2) {
                    // All Tools Row
                    sidebarRow(
                        title: "All Tools",
                        icon: "square.grid.2x2",
                        color: theme.accentColor,
                        count: 16,
                        selection: .all
                    )

                    sidebarSectionHeader("DOMAINS")

                    ForEach(ToolCategory.allCases) { cat in
                        let catCount = Self.tools.filter { $0.category == cat }.count
                        sidebarRow(
                            title: cat.rawValue,
                            icon: cat.icon,
                            color: cat.color,
                            count: catCount,
                            selection: .domain(cat)
                        )
                    }

                    sidebarSectionHeader("SAFETY POLICY")

                    sidebarRow(
                        title: "Auto-Approved",
                        icon: "bolt.fill",
                        color: .green,
                        count: 11,
                        selection: .policy(.autoApproved)
                    )

                    sidebarRow(
                        title: "Requires Approval",
                        icon: "shield.lefthalf.filled",
                        color: .orange,
                        count: 5,
                        selection: .policy(.requiresApproval)
                    )
                }
                .padding(.horizontal, 8)
            }

            Spacer(minLength: 0)

            // Sidebar Footer Callout
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 5) {
                    Image(systemName: "checkmark.shield.fill")
                        .font(.system(size: 11))
                        .foregroundColor(.green)
                    Text("Single-Intent Presets")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundColor(theme.primaryText)
                }
                Text("Pre-tuned for zero flag hallucinations across MLX, Ollama & cloud models.")
                    .font(.system(size: 10))
                    .foregroundColor(theme.secondaryText)
                    .lineSpacing(1.5)
            }
            .padding(10)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(theme.surfaceOverlay.opacity(0.7))
            )
            .padding(12)
        }
    }

    private func sidebarSectionHeader(_ title: String) -> some View {
        Text(title)
            .font(.system(size: 9.5, weight: .bold, design: .rounded))
            .foregroundColor(theme.secondaryText.opacity(0.65))
            .padding(.horizontal, 10)
            .padding(.top, 14)
            .padding(.bottom, 4)
    }

    private func sidebarRow(
        title: String,
        icon: String,
        color: Color,
        count: Int,
        selection: FilterSelection
    ) -> some View {
        let isSelected = selectedFilter == selection
        return Button(action: {
            withAnimation(.spring(response: 0.22, dampingFraction: 0.8)) {
                selectedFilter = selection
            }
        }) {
            HStack(spacing: 8) {
                Image(systemName: icon)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(isSelected ? color : theme.secondaryText)
                    .frame(width: 18)

                Text(title)
                    .font(.system(size: 12, weight: isSelected ? .semibold : .regular))
                    .foregroundColor(isSelected ? theme.primaryText : theme.secondaryText)

                Spacer(minLength: 4)

                Text("\(count)")
                    .font(.system(size: 10, weight: .medium, design: .rounded))
                    .foregroundColor(isSelected ? color : theme.secondaryText.opacity(0.6))
                    .padding(.horizontal, 6)
                    .padding(.vertical, 1.5)
                    .background(
                        Capsule()
                            .fill(isSelected ? color.opacity(0.18) : theme.surfaceOverlay)
                    )
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(isSelected ? theme.surfaceOverlayStrong : Color.clear)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .stroke(isSelected ? color.opacity(0.3) : Color.clear, lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
    }

    // MARK: - Detail Content View

    private var detailContentView: some View {
        VStack(spacing: 0) {
            // Detail Header Bar
            detailHeaderBar
            Divider().background(theme.dividerColor.opacity(0.3))

            // Scrollable Tools
            ScrollView {
                VStack(spacing: 16) {
                    if selectedFilter == .all && searchText.isEmpty {
                        architectureCallout
                    }

                    if filteredTools.isEmpty {
                        emptyStateView
                    } else {
                        LazyVStack(spacing: 12) {
                            ForEach(filteredTools) { tool in
                                modernToolCard(tool)
                            }
                        }
                    }
                }
                .padding(20)
            }
        }
    }

    private var detailHeaderBar: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 8) {
                    Text(detailTitle)
                        .font(.system(size: 16, weight: .bold))
                        .foregroundColor(theme.primaryText)

                    Text("\(filteredTools.count) \(filteredTools.count == 1 ? "tool" : "tools")")
                        .font(.system(size: 11, weight: .semibold, design: .rounded))
                        .foregroundColor(theme.accentColor)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 2)
                        .background(theme.accentColor.opacity(0.12))
                        .clipShape(Capsule())
                }

                Text(detailSubtitle)
                    .font(.system(size: 11.5))
                    .foregroundColor(theme.secondaryText)
            }

            Spacer()

            Button(action: { dismiss() }) {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 20))
                    .foregroundColor(theme.secondaryText.opacity(0.7))
            }
            .buttonStyle(.plain)
            .keyboardShortcut(.cancelAction)
            .help("Close (Esc)")
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
    }

    private var detailTitle: String {
        switch selectedFilter {
        case .all:               return "All Built-in Coding Tools"
        case .domain(let cat):   return cat.rawValue
        case .policy(let pol):   return pol.rawValue
        }
    }

    private var detailSubtitle: String {
        switch selectedFilter {
        case .all:
            return "\(Self.tools.count) deterministic tools pre-configured for code analysis, editing, and execution."
        case .domain(let cat):
            switch cat {
            case .read:   return "File reading, recursive directory traversal, codebase maps & definition finding."
            case .search: return "Fast ripgrep searches: text regex with context, exact symbol, and files-only."
            case .edit:   return "Uniqueness-verified single and atomic batch search-and-replace replacements."
            case .file:   return "Strict creation of new files and explicit destructive full-file overwriting."
            case .vcs:    return "Terminal script execution, structured Git operations, and unified diffs."
            }
        case .policy(let pol):
            switch pol {
            case .autoApproved:     return "Safe inspection and query tools that execute automatically without modal prompts."
            case .requiresApproval: return "Modifying and execution operations guarded by explicit confirmation prompts."
            }
        }
    }

    // MARK: - Architecture Callout

    private var architectureCallout: some View {
        HStack(spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Image(systemName: "sparkles")
                        .font(.system(size: 11))
                        .foregroundColor(theme.accentColor)
                    Text("Deterministic Single-Intent Architecture")
                        .font(.system(size: 12.5, weight: .bold))
                        .foregroundColor(theme.primaryText)
                }

                Text("Generic tools with multi-modal boolean toggles (e.g. edit_code, code_search) are superseded by focused single-intent splits. Smaller models (MLX & Ollama 7B–14B) never hallucinate toggles or corrupt files.")
                    .font(.system(size: 11))
                    .foregroundColor(theme.secondaryText)
                    .lineSpacing(2)
            }

            Spacer(minLength: 12)

            HStack(spacing: 10) {
                VStack(spacing: 2) {
                    Text("11")
                        .font(.system(size: 15, weight: .bold, design: .rounded))
                        .foregroundColor(.green)
                    Text("Auto-Approved")
                        .font(.system(size: 9, weight: .medium))
                        .foregroundColor(theme.secondaryText)
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(Color.green.opacity(0.1))
                .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))

                VStack(spacing: 2) {
                    Text("5")
                        .font(.system(size: 15, weight: .bold, design: .rounded))
                        .foregroundColor(.orange)
                    Text("Approval Gated")
                        .font(.system(size: 9, weight: .medium))
                        .foregroundColor(theme.secondaryText)
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(Color.orange.opacity(0.1))
                .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
            }
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(theme.surfaceOverlay)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(theme.dividerColor.opacity(0.35), lineWidth: 1)
        )
    }

    // MARK: - Modern Tool Card

    private func modernToolCard(_ tool: CodeToolItem) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            // Card Header
            HStack(spacing: 10) {
                ZStack {
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .fill(tool.category.color.opacity(0.15))
                        .frame(width: 26, height: 26)
                    Image(systemName: tool.category.icon)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundColor(tool.category.color)
                }

                Text(tool.name)
                    .font(.system(size: 13, weight: .bold, design: .monospaced))
                    .foregroundColor(theme.primaryText)

                Text(tool.category.rawValue)
                    .font(.system(size: 9.5, weight: .medium))
                    .foregroundColor(tool.category.color)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 2)
                    .background(tool.category.color.opacity(0.10))
                    .clipShape(Capsule())

                Spacer()

                if tool.requiresConfirmation {
                    HStack(spacing: 4) {
                        Image(systemName: "shield.lefthalf.filled")
                            .font(.system(size: 9.5))
                        Text("Requires Approval")
                            .font(.system(size: 10, weight: .semibold))
                    }
                    .foregroundColor(.orange)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(Color.orange.opacity(0.12))
                    .clipShape(Capsule())
                    .overlay(Capsule().stroke(Color.orange.opacity(0.3), lineWidth: 0.5))
                } else {
                    HStack(spacing: 4) {
                        Image(systemName: "bolt.fill")
                            .font(.system(size: 9))
                        Text("Auto-Approved")
                            .font(.system(size: 10, weight: .medium))
                    }
                    .foregroundColor(.green)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(Color.green.opacity(0.10))
                    .clipShape(Capsule())
                }
            }

            // Description
            Text(tool.description)
                .font(.system(size: 12))
                .foregroundColor(theme.primaryText.opacity(0.85))
                .lineSpacing(2)

            // Why Split callout
            if let why = tool.whySplit {
                HStack(alignment: .top, spacing: 6) {
                    Image(systemName: "sparkles")
                        .font(.system(size: 9.5))
                        .foregroundColor(theme.accentColor)
                        .padding(.top, 1.5)
                    Text(why)
                        .font(.system(size: 11, weight: .regular))
                        .foregroundColor(theme.accentColor.opacity(0.95))
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.horizontal, 9)
                .padding(.vertical, 5)
                .background(theme.accentColor.opacity(0.06))
                .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
            }

            // Parameters Breakdown
            VStack(alignment: .leading, spacing: 4) {
                Text("PARAMETERS")
                    .font(.system(size: 8.5, weight: .bold))
                    .foregroundColor(theme.secondaryText.opacity(0.6))

                ForEach(tool.parameters, id: \.name) { param in
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text(param.name)
                            .font(.system(size: 11, weight: .semibold, design: .monospaced))
                            .foregroundColor(param.required ? theme.accentColor : theme.primaryText)

                        Text("(\(param.type))")
                            .font(.system(size: 9.5, design: .monospaced))
                            .foregroundColor(theme.secondaryText.opacity(0.8))

                        if param.required {
                            Text("required")
                                .font(.system(size: 8, weight: .bold))
                                .foregroundColor(.red.opacity(0.85))
                                .padding(.horizontal, 4)
                                .padding(.vertical, 1)
                                .background(Color.red.opacity(0.08))
                                .clipShape(RoundedRectangle(cornerRadius: 3))
                        }

                        Text("— \(param.detail)")
                            .font(.system(size: 11))
                            .foregroundColor(theme.secondaryText)
                            .lineLimit(2)
                    }
                }
            }
            .padding(10)
            .background(theme.surfaceOverlay.opacity(0.5))
            .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(theme.secondaryBackground)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(theme.dividerColor.opacity(0.3), lineWidth: 1)
        )
    }

    private var emptyStateView: some View {
        VStack(spacing: 12) {
            Image(systemName: "questionmark.folder")
                .font(.system(size: 32))
                .foregroundColor(theme.secondaryText.opacity(0.5))
            Text("No tools found matching '\(searchText)'")
                .font(theme.fontHeadline)
                .foregroundColor(theme.secondaryText)
            Button("Reset Search & Filters") {
                searchText = ""
                selectedFilter = .all
            }
            .buttonStyle(.bordered)
        }
        .frame(maxWidth: .infinity)
        .padding(48)
    }
}
