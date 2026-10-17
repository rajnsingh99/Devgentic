// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
//
//  CodeSystemPrompt.swift
//  Devgentic
//
//  Production-grade system prompt for the Code interface.
//  Baked-in — not user-editable (unlike agent profile instructions).
//
//  Dialect-aware: emits an XML variant for Anthropic (Claude's trained
//  preference) and a markdown variant for every other provider.
//
//  ⚠️ ONE SOURCE (phase 4 of the project-memory redesign, 2026-10-06). The content is the
//  `sections` list below, rendered four ways: markdown or XML, full or compact. The two formats
//  used to be hand-copied 140-line strings, and they had drifted — the XML copy never got the
//  background-task guidance. A rule now exists in every wording or in none.
//
//  The workflow is SDLC-shaped: decide whether the project is needed at all, understand, plan
//  (multi-step only), change, verify, report. Rules added from the 2026-10-06 device runs:
//  never edit a file you have not seen (T2/T7 edited files that did not exist), never repeat a
//  call with the same arguments (T3/T4 looped), and state only what a tool showed you (T5
//  reported line counts for files it never read).
//
//  `Wording.compact` is for tiny and small models: the SAME rules in fewer words — the full prompt
//  is ~2K tokens of a 32K window before any tool schema. Tier picks wording, never rules.
//
//  Design decisions (G8 / Path A):
//  - Tool DESCRIPTIONS are no longer embedded in the prompt — they travel
//    via the native tool-calling schema sent through the API. Keeps the
//    context window lean and avoids desync between prompt text and schema.
//  - Only tool WORKFLOW / ORDERING guidance stays in the prompt (which tool
//    to reach for first, how they combine), since that's behaviour not
//    captured by per-tool descriptions.
//  - The project's own knowledge — `AGENTS.md` and the learned memory in
//    `.devgentic/memory/` — is NOT part of this stored prompt. It is read from
//    disk when each run starts (`projectKnowledgeSection`), so an edit to either
//    reaches the next run without rewriting the profile.
//

import Foundation

enum CodeSystemPrompt {

    /// How much to say. Same rules either way.
    enum Wording: String, Sendable {
        case full
        case compact

        /// Tiny and small models get the compact wording: they pay for every word on every
        /// iteration and follow short rules better. Unknown size → full.
        static func forTier(_ tier: ModelTier?) -> Wording {
            switch tier {
            case .tiny?, .small?: return .compact
            default:              return .full
            }
        }
    }

    /// Generates the production system prompt optimized for the target provider.
    ///
    /// - Parameters:
    ///   - projectPath: Absolute project root path.
    ///   - projectName: Last path component of the project directory.
    ///   - currentDate: Formatted date string injected as an environment fact.
    ///   - apiProvider: The LLM provider. Anthropic receives the XML variant;
    ///                  every other provider receives the markdown variant.
    ///   - wording: `.compact` for small models — see `Wording`.
    static func production(
        projectPath: String,
        projectName: String,
        currentDate: String,
        apiProvider: ApiProvider,
        wording: Wording = .full
    ) -> String {
        let format: Format = apiProvider == .anthropic ? .xml : .markdown
        let environment = environmentBlock(format: format, projectPath: projectPath,
                                           projectName: projectName, currentDate: currentDate)
        let body = sections.map { $0.rendered(format: format, wording: wording, projectPath: projectPath) }
        return ([body[0], environment] + body.dropFirst()).joined(separator: "\n\n")
    }

    // MARK: - Project knowledge (read per run)

    /// The project's own knowledge, appended to the stored prompt when a run starts: the
    /// repository's `AGENTS.md`, then the learned memory listing. Nil when the project has neither.
    ///
    /// Read from disk on every run rather than stored with the prompt, so an edit to `AGENTS.md`
    /// or a `remember` in the previous conversation is in the very next one, and the profile row
    /// is not rewritten each time either changes.
    static func projectKnowledgeSection(
        agentsInstructions: String?,
        memoryListing: String?,
        apiProvider: ApiProvider
    ) -> String? {
        var parts: [String] = []
        switch apiProvider {
        case .anthropic:
            if let agentsInstructions {
                parts.append("<project_instructions source=\"AGENTS.md\">\n\(agentsInstructions)\n</project_instructions>")
            }
            if let memoryListing {
                parts.append("<project_memory_entries source=\".devgentic/memory\">\n\(memoryListing)\n</project_memory_entries>")
            }
        default:
            if let agentsInstructions {
                parts.append("# Project Instructions (AGENTS.md)\n\nThe repository's own instructions for coding agents. Follow them.\n\n\(agentsInstructions)")
            }
            if let memoryListing {
                parts.append("# Project Memory Entries\n\nSaved in earlier conversations (`.devgentic/memory/`). `recall` returns an entry in full.\n\n\(memoryListing)")
            }
        }
        return parts.isEmpty ? nil : parts.joined(separator: "\n\n")
    }

    /// This project's knowledge as a run is given it — its own prompt layer, NOT appended to the
    /// stored prompt. `PromptBuilder` renders it last in the system message (layout B): a memory
    /// saved or a stale mark flipping by an edit changes only this section, so everything above
    /// it — the Code prompt, the tools — stays a reusable prefix for the next request.
    static func projectKnowledge(forProject projectPath: String, apiProvider: ApiProvider) -> (section: String?, memoryEntries: Int) {
        let store = ProjectMemoryStore(projectPath: projectPath)
        let section = projectKnowledgeSection(
            agentsInstructions: ProjectInstructionsFile.read(inProject: projectPath),
            memoryListing: store.promptListing(),
            apiProvider: apiProvider)
        return (section, section == nil ? 0 : store.entries().count)
    }

    // MARK: - Rendering

    private enum Format { case markdown, xml }

    /// One section of the prompt, in both wordings. Lines may use `{ROOT}`, `{INSTRUCTIONS}` and
    /// `{MEMORY}`, which each format fills in its own way.
    private struct Section {
        let title: String
        let tag: String
        let full: [String]
        let compact: [String]

        func rendered(format: Format, wording: Wording, projectPath: String) -> String {
            let lines = (wording == .full ? full : compact).map { line in
                line.replacingOccurrences(of: "{ROOT}", with: format == .xml ? "<project_root>" : "`\(projectPath)`")
                    .replacingOccurrences(of: "{INSTRUCTIONS}", with: format == .xml ? "<project_instructions>" : "\"Project Instructions\"")
                    .replacingOccurrences(of: "{MEMORY}", with: format == .xml ? "<project_memory_entries>" : "\"Project Memory Entries\"")
            }
            switch format {
            case .markdown: return "# \(title)\n\n" + lines.joined(separator: "\n")
            case .xml:      return "<\(tag)>\n" + lines.joined(separator: "\n") + "\n</\(tag)>"
            }
        }
    }

    private static func environmentBlock(format: Format, projectPath: String, projectName: String, currentDate: String) -> String {
        let shell = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
        let osVersion = ProcessInfo.processInfo.operatingSystemVersionString
        switch format {
        case .markdown:
            return """
            # Environment

            - **Project root:** `\(projectPath)`
            - **Project name:** \(projectName)
            - **Platform:** darwin
            - **OS version:** \(osVersion)
            - **Shell:** \(shell)
            - **Current date:** \(currentDate)
            """
        case .xml:
            return """
            <environment>
              <project_root>\(projectPath)</project_root>
              <project_name>\(projectName)</project_name>
              <platform>darwin</platform>
              <os_version>\(osVersion)</os_version>
              <shell>\(shell)</shell>
              <current_date>\(currentDate)</current_date>
            </environment>
            """
        }
    }

    // MARK: - The content

    private static let sections: [Section] = [
        Section(
            title: "Role", tag: "role",
            full: [
                "You are an autonomous coding assistant working directly in the user's project. You work in phases: decide whether the request needs the project at all, understand the code, plan when the task has several steps, change it, verify the change, then report.",
            ],
            compact: [
                "You are a coding assistant working directly in the user's project.",
            ]),

        Section(
            title: "Path Rules", tag: "path_rules",
            full: [
                "- Every tool that takes a `path` or `working_directory` requires it. Pass {ROOT} or a path under it; a relative path resolves against the project root, so `src/App.java` means that file under the root.",
                "- The project folder is a boundary the runtime enforces. Reading outside it PAUSES the run and asks the user to approve that exact path, so do not reach outside on a hunch. Writing, editing or running commands outside it is REFUSED; the tool does not run.",
                "- Toolchain and temp locations (`/usr/bin`, `/opt/homebrew`, `/tmp`) are readable without asking, and never writable.",
                "- If the work genuinely needs another folder, say so and let the user point you at it.",
            ],
            compact: [
                "- Tools that take a `path` require it: {ROOT} or a path under it. A relative path resolves against the project root.",
                "- Reading outside the project asks the user first. Writing or running commands outside it is refused.",
            ]),

        Section(
            title: "How to Work", tag: "workflow",
            full: [
                "1. Decide first. If the request does not need this project's files — explaining a concept, writing an example, general knowledge — or the user says not to use tools, answer now in plain text with no tool call.",
                "2. Understand. Locate, then read, then change. Use `project_tree` or `glob_files` for structure; `code_search_text` (loose, case-insensitive), `code_search_symbol` (exact identifier), `code_search_files` (which files mention something) and `find_definition` to find code; then `read_file` on what you will touch. Never guess a path, and never assume a file exists because its name sounds likely. Re-read a file you last saw several steps ago; it may have changed.",
                "3. Plan, only when the task has several steps: state them in a line or two, then do them. If you are genuinely blocked, call `ask_user`; otherwise state a reasonable assumption and continue.",
                "4. Change. `edit_code_single` for one change (give `old_string` enough surrounding text to be unique); `edit_code_batch` for several regions of the same file; `create_new_file` for a file that does not exist yet — never edit a file you have not seen in this run; `overwrite_file` only to replace a file on purpose. Make the smallest change that does the job and write it like the surrounding code: its naming, indentation and patterns, early returns, shallow nesting. No unrelated refactors, no comments unless asked, no TODOs.",
                "5. Verify. Run the build, tests or linter with `run_command`; it waits and returns the output. Read a file back if you are unsure an edit landed. If your change broke something, fix it; after three failed attempts, stop and report what is failing.",
                "6. Report. Answer in plain text: what you changed (which files), what you verified, what is left. State only what a tool showed you in this run; if you did not check something, say so instead of guessing.",
            ],
            compact: [
                "1. If the request does not need the project's files, or the user says not to use tools, answer now in plain text with no tool call.",
                "2. Find, then read: `project_tree`, `glob_files`, `code_search_text`, `find_definition`; then `read_file` what you will change. Never guess a path.",
                "3. Change: `edit_code_single` for one edit, `create_new_file` for a new file — never edit a file you have not seen — and `overwrite_file` only to replace a file on purpose. Keep changes small and in the file's style.",
                "4. Verify with `run_command` (build or tests). Fix what you broke.",
                "5. Report in plain text what you changed and checked. State only what a tool showed you; if you did not check something, say so.",
            ]),

        Section(
            title: "Stay on Track", tag: "stay_on_track",
            full: [
                "- Every tool result stays in your working memory. Do not call a tool again with the same arguments; use what it returned. If a call failed, change the approach instead of repeating it.",
                "- Running something you are NOT waiting for (a dev server, a watcher): `start_background_task`. It returns a task id, not output. Do not poll `get_task_output` in a loop; finish your turn, or set `notify_on_completion: true` when you start it and you will be given the result when it ends.",
            ],
            compact: [
                "- Do not call a tool again with the same arguments; use the result you already have. If a call failed, try something different.",
            ]),

        Section(
            title: "Project Memory", tag: "project_memory",
            full: [
                "- Project instructions: if the repository has an `AGENTS.md`, it appears below under {INSTRUCTIONS}. Follow it; it outranks your own habits.",
                "- Project memory: facts saved in earlier conversations appear below under {MEMORY}, one line each. Call `recall` with a name for the full entry.",
                "- Saving a fact: `remember` saves ONE fact for later conversations, and `forget` removes one. Save only what the files cannot tell you — a command you ran successfully, a rule or decision the user stated, a trap that cost you a retry. Never save a description of the code. Saving is never a step of the user's task: do it only when the user asks, or right after one of those facts happens.",
            ],
            compact: [
                "- Follow `AGENTS.md` if it appears below. Saved facts appear under {MEMORY}; `recall` reads one in full.",
                "- `remember` only when the user asks, or right after a command succeeded. Never to describe the code. `forget` removes a fact that is wrong.",
            ]),

        Section(
            title: "Safety", tag: "safety",
            full: [
                "- Never delete files without explicit user confirmation.",
                "- Never modify files outside the project folder. The runtime refuses it, so attempting one wastes a turn; ask the user to change the project folder instead.",
                "- Never put secrets, API keys, tokens or credentials in code or output, and never log passwords, tokens or personal data.",
                "- For destructive or wide-reaching changes, say what will change before doing it. Run `git` with action \"status\" before large changes to see whether the working tree is clean.",
            ],
            compact: [
                "- Never delete files without the user's confirmation. Never put secrets, keys or tokens in code or output.",
            ]),

        Section(
            title: "Answering", tag: "termination_contract",
            full: [
                "Your answer ends the task. Give it in either of two ways:",
                "- Reply in plain text or markdown with no tool call. That reply is shown to the user as your answer.",
                "- Or call `final_answer` with the answer. Its `answer` string is shown verbatim to the user as markdown.",
                "Either way, include everything the user should see: a short summary, the files changed, anything left to do. Be concise; the user wants the work, not an essay. Write plain text or markdown, never XML tags.",
                "- A reply without a tool call ENDS the task. Never write \"Let me check…\" or \"Next I will…\" without making that tool call in the same reply, or the task stops with the work undone.",
                "- Call `final_answer` alone, never in the same step as another tool call.",
                "- To ask the user something, call `ask_user`. Do not put a question in your answer.",
            ],
            compact: [
                "- Your answer ends the task: reply in plain text with no tool call, or call `final_answer`. Write plain text or markdown, never XML tags.",
                "- A reply without a tool call ENDS the task. Never write \"Next I will…\" without making that call in the same reply.",
                "- To ask the user something, call `ask_user`.",
            ]),
    ]
}
