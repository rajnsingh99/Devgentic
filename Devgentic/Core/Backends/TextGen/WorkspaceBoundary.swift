// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
//
//  WorkspaceBoundary.swift
//  Devgentic
//
//  Confines Code-mode filesystem tools to the selected project folder.
//

import Foundation

private let logger = DGLogger(category: "WorkspaceBoundary")

/// Decides whether a path a model asked for is inside the project the user chose.
///
/// ⚠️⚠️ WHY THIS EXISTS. The project folder was purely DESCRIPTIVE until now: `projectPath`
/// reached exactly one tool (`UpdateProjectContextTool`) and nothing else in the app consulted it.
/// The Code system prompt names the root, but its only restriction is on WRITES — it explicitly
/// sanctions cross-folder reads ("For legitimate cross-folder work … pass an explicit absolute
/// path"). Field-observed 2026-09-20: a Code session rooted at a small Java project called
/// `list_directory("/Users/<name>")`, which returned the user's entire home directory in 0.005 s
/// with no refusal and no confirmation, and the model then offered to explain any of those
/// projects. Nothing was broken — there was simply never a boundary.
///
/// ⚠️ This is NOT the "capability describes, never enforces" case. That directive is about
/// CLASSIFICATION METADATA — a detected tier, a parameter count, something the app inferred about
/// a model — which may label a row but must never gate an action. A workspace root is the
/// opposite: it is an intent the USER stated by choosing a folder. Enforcing it honours an
/// instruction rather than overriding one. That is also why leaving the project asks rather than
/// refuses: the user can always say yes.
enum WorkspaceBoundary {

    // MARK: - Verdict

    enum Verdict: Equatable {
        /// Inside the project (or an allowlisted toolchain path). Run it.
        case allowed(resolved: String)
        /// Outside, and the tool only reads. Worth asking about.
        case needsApproval(resolved: String, reason: String)
        /// Outside, and the tool writes or executes. Refuse and tell the model why.
        case refused(resolved: String, reason: String)
    }

    // MARK: - Argument names that carry a path
    //
    // ⚠️ Keyed by argument NAME, never by "looks like a path". Shape-matching a payload is how
    // four separate transforms in this codebase silently rewrote file CONTENT that happened to
    // resemble a path (see the content-corruption register). A value is only treated as a path
    // because the tool's own schema calls it one.

    /// ⚠️⚠️ DERIVED FROM THE TOOLS' OWN SCHEMAS, not guessed. The first version of this set
    /// carried `left`/`right` for `diff_files` — names that tool has never used. Its real
    /// arguments are `file_a`/`file_b`, so BOTH of its paths went unchecked and it could read
    /// anywhere on disk while every sibling tool was confined. Read the struct before adding a
    /// name here.
    ///
    /// Present per preset tool:
    ///   path              — read_file, list_directory, codebase_map, glob_files,
    ///                       find_definition, code_search_text/_symbol/_files, git_tool
    ///   file_path         — file_overview, edit_code_single, edit_code_batch,
    ///                       create_new_file, overwrite_file
    ///   working_directory — batch_command
    ///   file_a, file_b    — diff_files
    ///
    /// ⚠️ `pattern`, `glob`, `symbol`, `old_string`, `new_string`, `content` and `args` are
    /// deliberately ABSENT. They carry search text or file CONTENT, and rewriting one would be
    /// the content-corruption defect this project has already shipped four times.
    static let pathArgumentNames: Set<String> = [
        "path", "file_path", "filePath",
        "file_a", "file_b",
        "directory", "dir",
        "working_directory", "workingDirectory",
        "source", "destination",
        "old_path", "new_path",
        "root", "base_path",
    ]

    /// Preset tools that only read. Everything else is treated as mutating — the safe direction
    /// for a name this list has not been taught.
    static let readOnlyToolNames: Set<String> = [
        "read_file", "list_directory", "codebase_map", "glob_files",
        "find_definition", "file_overview",
        "code_search_text", "code_search_symbol", "code_search_files",
        "diff_files",
        // ⚠️ `git_tool` IS read-only: its schema offers status, log, diff, branch, stash_list,
        // blame and show, and nothing that writes. Classifying it as mutating was wrong in a way
        // that bites immediately — a project whose `.git` lives in a PARENT directory (a module
        // inside a larger repo, which is the common layout) would have its git calls REFUSED
        // outright instead of prompting. If a write action is ever added to that tool, remove it
        // from this list in the same commit.
        "git_tool",
        // Report on, and read the log of, a background task. Both take a `task_id` and no path,
        // so `evaluate` is never reached for them today — they are listed because this set is the
        // app's answer to "does this tool only read", and `CodeEditPreviewTests` derives from it.
        // A tool missing here is treated as mutating and must produce an approval preview; being
        // silently wrong in that direction is how a tool ships approving through a raw JSON blob.
        //
        // ⚠️ `command_stop` is deliberately NOT here. It ends a process — the machine is in a
        // different state afterwards — and only its lack of a FILE to diff keeps it out of the
        // preview requirement.
        "command_output",
    ]

    /// Paths outside the project that ordinary development legitimately needs, so a shell command
    /// is not refused for finding its own compiler.
    ///
    /// ⚠️ Read-ONLY intent: being on this list exempts a path from the approval prompt, it does
    /// not make it writable. A write outside the project is refused wherever it points.
    static let toolchainAllowlist: [String] = [
        "/usr/bin", "/bin", "/usr/lib", "/usr/share", "/usr/local", "/opt/homebrew",
        "/Library/Developer", "/Applications/Xcode.app",
        "/private/tmp", "/tmp", "/var/folders",
    ]

    // MARK: - Resolution

    /// Resolves a model-supplied path against the PROJECT root.
    ///
    /// ⚠️⚠️ Deliberately NOT `FilePathResolver.resolve`, which anchors a relative path to the
    /// user's HOME. That is right for a general assistant and catastrophic here: it is why
    /// `codebase_map("./")` spent 41.8 seconds walking `/Users/<name>` instead of a small project.
    /// In Code mode "." means the project, because that is the only folder the user pointed at.
    static func resolve(_ path: String, projectRoot: String) -> String {
        let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return canonical(projectRoot) }

        let expanded = (trimmed as NSString).expandingTildeInPath
        if expanded.hasPrefix("/") { return canonical(expanded) }

        let joined = (projectRoot as NSString).appendingPathComponent(expanded)
        return canonical(joined)
    }

    /// Absolute, symlink-resolved, `..`-free.
    ///
    /// ⚠️ Symlinks are resolved BEFORE any comparison. A link inside the project pointing at `/`
    /// is otherwise a one-step escape that a prefix check on the literal string cannot see. The
    /// root is canonicalised the same way so a `/tmp` → `/private/tmp` project still matches
    /// itself.
    static func canonical(_ path: String) -> String {
        URL(fileURLWithPath: path).standardizedFileURL.resolvingSymlinksInPath().path
    }

    // MARK: - Decision

    static func evaluate(
        path: String,
        toolName: String,
        projectRoot: String
    ) -> Verdict {
        let root = canonical(projectRoot)
        let resolved = resolve(path, projectRoot: root)

        if isWithin(resolved, root: root) {
            return .allowed(resolved: resolved)
        }

        let isReadOnly = readOnlyToolNames.contains(toolName)

        if isReadOnly, let allowed = toolchainAllowlist.first(where: { isWithin(resolved, root: canonical($0)) }) {
            // ⚠️ No conversation ID here, deliberately: this is a pure function of
            // (path, tool, root) and taking one purely to decorate a log would make it
            // untestable without a run. The call site in `ToolExecutionLoop` logs the
            // correlated lines; this one exists so an allowlist hit is never invisible.
            logger.info("[WORKSPACE] '\(toolName)' read \(resolved) — outside the project, but under the allowlisted \(allowed). CONSEQUENCE: permitted WITHOUT asking the user, because toolchain and temp paths are needed for ordinary development; a write to the same path is still refused.")
            return .allowed(resolved: resolved)
        }

        let projectName = (root as NSString).lastPathComponent
        if isReadOnly {
            return .needsApproval(
                resolved: resolved,
                reason: "'\(toolName)' wants to read \(resolved), which is outside the '\(projectName)' project."
            )
        }

        return .refused(
            resolved: resolved,
            reason: "'\(toolName)' cannot modify \(resolved) — it is outside the '\(projectName)' project. "
                + "Work inside \(root), or ask the user to change the project folder."
        )
    }

    /// Containment on PATH COMPONENTS, not string prefix.
    ///
    /// ⚠️ A plain `hasPrefix` says `/Users/x/proj-secrets` is inside `/Users/x/proj`. It is not.
    static func isWithin(_ path: String, root: String) -> Bool {
        if path == root { return true }
        let pathParts = (path as NSString).pathComponents
        let rootParts = (root as NSString).pathComponents
        guard pathParts.count > rootParts.count else { return false }
        return Array(pathParts.prefix(rootParts.count)) == rootParts
    }

    // MARK: - Argument rewriting

    /// Returns every (key, value) in `arguments` whose key names a path.
    static func pathArguments(in arguments: [String: Any]) -> [(key: String, value: String)] {
        arguments.compactMap { key, value in
            guard pathArgumentNames.contains(key), let str = value as? String, !str.isEmpty else { return nil }
            return (key, str)
        }
        .sorted { $0.key < $1.key }   // stable order so logs and prompts read the same every run
    }
}

// MARK: - Applying the boundary to a tool call

/// The boundary's verdict for one tool call, plus the arguments rewritten to project-anchored,
/// canonical paths.
///
/// ⚠️ Separate from `WorkspaceBoundary` so the POLICY stays a pure function of (path, tool, root)
/// and stays unit-testable without `JSONValue`, while this adapter owns the argument plumbing.
struct WorkspaceBoundaryDecision {

    enum Outcome: Equatable {
        /// Inside the project, or no project (every non-Code profile). Run it unchanged.
        case proceed
        /// A read outside the project. Ask the user before running it.
        case askUser(reason: String)
        /// A write outside the project. Do not run it.
        case refuse(reason: String)
    }

    let outcome: Outcome
    /// Original arguments with every path-shaped value resolved against the project root.
    let arguments: [String: JSONValue]

    /// ⚠️ `repositoryLocator` exists for ONE tool. See `applyRepositoryDiscovery` below: every
    /// other preset tool acts on the path it was handed, so validating the argument is the whole
    /// job. `git_tool` acts on whatever repository git DISCOVERS by walking up from that path,
    /// which can be — and on the common "module inside a larger repo" layout usually is —
    /// outside the project.
    static func evaluate(
        toolName: String,
        arguments: [String: JSONValue],
        workspaceRoot: String?,
        repositoryLocator: GitRepositoryLocator = .live
    ) -> WorkspaceBoundaryDecision {
        // No root → no boundary. This is the path every chat, agent and workflow run takes, and
        // it must behave exactly as it did before this type existed.
        guard let root = workspaceRoot, !root.isEmpty else {
            return WorkspaceBoundaryDecision(outcome: .proceed, arguments: arguments)
        }

        var rewritten = arguments
        var worst: Outcome = .proceed

        for (key, value) in arguments.sorted(by: { $0.key < $1.key }) {
            guard WorkspaceBoundary.pathArgumentNames.contains(key),
                  case .string(let raw) = value,
                  !raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { continue }

            switch WorkspaceBoundary.evaluate(path: raw, toolName: toolName, projectRoot: root) {
            case .allowed(let resolved):
                rewritten[key] = .string(resolved)
            case .needsApproval(let resolved, let reason):
                rewritten[key] = .string(resolved)
                // A refusal already recorded wins — one write outside the project condemns the
                // whole call, however many of its other arguments were merely readable.
                if case .refuse = worst {} else { worst = .askUser(reason: reason) }
            case .refused(let resolved, let reason):
                rewritten[key] = .string(resolved)
                worst = .refuse(reason: reason)
            }
        }

        worst = applyRepositoryDiscovery(
            toolName: toolName,
            arguments: rewritten,
            root: root,
            current: worst,
            locator: repositoryLocator
        )

        return WorkspaceBoundaryDecision(outcome: worst, arguments: rewritten)
    }

    /// Folds git's REPOSITORY DISCOVERY into the verdict.
    ///
    /// ⚠️⚠️ THE ARGUMENT-VS-BEHAVIOUR GAP. `git -C <dir> status` does not report on `<dir>`. Git
    /// walks up from `<dir>` to the nearest `.git` and reports on THAT repository. So a path that
    /// passes every check above — absolute, canonical, provably inside the project — still hands
    /// back the parent repository's status, log, diff and blame when the project is a module
    /// inside a larger checkout.
    ///
    /// Field-observed 2026-09-20: project `…/cp-dsa/java`, repository `…/cp-dsa`. The boundary
    /// saw a compliant in-project path and allowed it; the output covered sibling folders the
    /// user never pointed the agent at.
    ///
    /// The verdict is `askUser`, not `refuse`, and that is deliberate on two counts. `git_tool`
    /// is read-only, and the boundary's whole policy is that reads outside the project ASK while
    /// writes are refused — treating this as a write would contradict it. And the parent-repo
    /// layout is legitimate and common: the user can simply say yes, once, having been told
    /// exactly which repository they are saying yes to.
    private static func applyRepositoryDiscovery(
        toolName: String,
        arguments: [String: JSONValue],
        root: String,
        current: Outcome,
        locator: GitRepositoryLocator
    ) -> Outcome {
        guard toolName == "git_tool" else { return current }

        // Only when the ARGUMENT check found nothing to object to. A path already outside the
        // project has produced its own verdict, and asking twice about one call would park the
        // run on two banners for a single tool.
        guard case .proceed = current else { return current }

        guard case .string(let start)? = arguments["path"], !start.isEmpty else { return current }

        // Nil means "not in a repository", or git was unavailable. Either way there is nothing
        // to confine: the tool will report the failure itself.
        guard let discovered = locator.toplevel(start) else { return current }

        let canonicalRoot = WorkspaceBoundary.canonical(root)
        let repository = WorkspaceBoundary.canonical(discovered)
        guard !WorkspaceBoundary.isWithin(repository, root: canonicalRoot) else { return current }

        let projectName = (canonicalRoot as NSString).lastPathComponent
        logger.notice("[WORKSPACE] 'git_tool' path \(start) is inside the project, but git resolves it to the repository at \(repository), which is OUTSIDE '\(projectName)'. CONSEQUENCE: the call is routed through the ordinary confirmation banner instead of silently reporting on a repository the user did not point the agent at; the path argument alone could never have caught this, because git discovers its repository by walking upwards.")

        return .askUser(reason:
            "'git_tool' would operate on the repository at \(repository), which git finds by "
            + "walking up from \(start). That repository is outside the '\(projectName)' project, "
            + "so its status, log, diff and blame cover files the project folder does not contain."
        )
    }
}
