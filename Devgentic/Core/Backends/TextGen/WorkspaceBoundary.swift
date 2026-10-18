// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
//
//  WorkspaceBoundary.swift
//  Devgentic
//
//  Created by Raj Singh.
//

import Foundation

private let logger = DGLogger(category: "WorkspaceBoundary")

/// Decides whether a path a model asked for is inside the project the user chose. The root is an intent the user
/// stated by choosing a folder, so leaving the project asks rather than refuses: the user can always say yes.
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
    // Keyed by argument NAME, never by "looks like a path": shape-matching a payload rewrites file content that
    // resembles a path. A value is a path only because the tool's own schema calls it one.

    // Why: search text and file content (`pattern`, `glob`, `symbol`, `old_string`, `new_string`, `content`, `args`) are
    // absent on purpose: rewriting them would corrupt content.
    /// Path-argument names checked for every tool, derived from the tools' own schemas: read the tool's struct before
    /// adding a name. A tool's own aliases come from `ToolPathKeys.byTool` and are checked only for that tool; read keys
    /// through `ToolPathKeys.pathArguments(forTool:)`, never this set alone.
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
        "read_file", "list_directory", "project_tree", "glob_files",
        "find_definition", "file_overview",
        "code_search_text", "code_search_symbol", "code_search_files",
        "diff_files",
        // `git` is read-only (status, log, diff, branch, stash_list, blame, show), so a project whose `.git` is in a parent
        // directory is prompted, not refused. Remove it from this list if a write action is added.
        "git",
        // Report on and read the log of a background task (a `task_id`, no path). A tool missing from this read-only set is
        // treated as mutating and needs an approval preview; `stop_background_task` ends a process, so it is absent.
        "get_task_output",
    ]

    /// Paths outside the project that ordinary development legitimately needs, so a shell command is not refused for
    /// finding its own compiler. Read-only intent: being listed exempts a path from the approval prompt but does not make
    /// it writable; a write outside the project is refused.
    static let toolchainAllowlist: [String] = [
        "/usr/bin", "/bin", "/usr/lib", "/usr/share", "/usr/local", "/opt/homebrew",
        "/Library/Developer", "/Applications/Xcode.app",
        "/private/tmp", "/tmp", "/var/folders",
    ]

    // MARK: - Resolution

    // Why: anchoring "." to home made `codebase_map("./")` walk the entire home directory.
    /// Resolves a model-supplied path against the project root, not `FilePathResolver.resolve`, which anchors relative
    /// paths to the user's home. In Code mode "." means the project, the only folder the user pointed at.
    static func resolve(_ path: String, projectRoot: String) -> String {
        let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return canonical(projectRoot) }

        let expanded = (trimmed as NSString).expandingTildeInPath
        if expanded.hasPrefix("/") { return canonical(expanded) }

        let joined = (projectRoot as NSString).appendingPathComponent(expanded)
        return canonical(joined)
    }

    // Why: symlinks resolve before any comparison (a link to `/` is a one-step escape a prefix check misses), and not via
    // `standardizedFileURL`, which turns `/private/var/...` back into `/var/...` and undoes the resolution.
    /// Absolute, symlink-resolved, `..`-free. Resolved one component at a time so a path that does not exist yet still
    /// resolves: each existing symlink is replaced by its target and the walk restarts (bounded at 40 hops, the kernel's
    /// `MAXSYMLINKS`). The root is canonicalised the same way; the caller rewrites the tool's argument to this result.
    static func canonical(_ path: String) -> String {
        let absolute = path.hasPrefix("/") ? path : (FileManager.default.currentDirectoryPath as NSString).appendingPathComponent(path)
        var pending = lexicalComponents(absolute)
        var resolved = "/"
        var index = 1   // components[0] is "/"
        var hops = 0
        while index < pending.count {
            let candidate = (resolved as NSString).appendingPathComponent(pending[index])
            if hops < 40, let destination = try? FileManager.default.destinationOfSymbolicLink(atPath: candidate) {
                hops += 1
                let target = destination.hasPrefix("/")
                    ? destination
                    : (resolved as NSString).appendingPathComponent(destination)
                let remainder = pending[(index + 1)...]
                pending = lexicalComponents(target) + remainder
                resolved = "/"
                index = 1
                continue
            }
            resolved = candidate
            index += 1
        }
        return resolved
    }

    /// `["/", a, b, …]` with `.` dropped and `..` folded — purely lexical, touching nothing on disk.
    private static func lexicalComponents(_ absolutePath: String) -> [String] {
        var parts: [String] = []
        for component in absolutePath.split(separator: "/", omittingEmptySubsequences: true) {
            switch component {
            case ".": continue
            case "..": if !parts.isEmpty { parts.removeLast() }
            default: parts.append(String(component))
            }
        }
        return ["/"] + parts
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
            // No conversation ID here: this is a pure function of (path, tool, root); the call site in `ToolExecutionLoop` logs
            // the correlated lines, and this one ensures an allowlist hit is never invisible.
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

    /// Containment on path components, not string prefix: a plain `hasPrefix` says `/Users/x/proj-secrets` is inside
    /// `/Users/x/proj`.
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

/// The boundary's verdict for one tool call, plus the arguments rewritten to project-anchored, canonical paths.
/// Separate from `WorkspaceBoundary` so the policy stays a pure function of (path, tool, root), testable without
/// `JSONValue`.
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

    /// Evaluates a tool call's path arguments against the project boundary. `repositoryLocator` exists for `git` alone:
    /// every other preset tool acts on the path it was handed, while `git` acts on whatever repository it discovers by
    /// walking up from that path, which can be outside the project.
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

        // This tool's path arguments: the generic set plus the aliases its own decoder reads (`ToolPathKeys`).
        let pathKeys = ToolPathKeys.pathArguments(forTool: toolName)

        /// Checks one path, folds its verdict into `worst`, and returns the resolved form.
        func check(_ raw: String) -> String? {
            guard !raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
            switch WorkspaceBoundary.evaluate(path: raw, toolName: toolName, projectRoot: root) {
            case .allowed(let resolved):
                return resolved
            case .needsApproval(let resolved, let reason):
                // A refusal already recorded wins — one write outside the project condemns the
                // whole call, however many of its other arguments were merely readable.
                if case .refuse = worst {} else { worst = .askUser(reason: reason) }
                return resolved
            case .refused(let resolved, let reason):
                worst = .refuse(reason: reason)
                return resolved
            }
        }

        for (key, value) in arguments.sorted(by: { $0.key < $1.key }) where pathKeys.contains(key) {
            switch value {
            case .string(let raw):
                if let resolved = check(raw) { rewritten[key] = .string(resolved) }
            case .array(let items):
                // `batch_move_files.sourcePaths` is an array of paths: each string element is checked, non-string elements are left
                // alone.
                rewritten[key] = .array(items.map { item in
                    guard case .string(let raw) = item, let resolved = check(raw) else { return item }
                    return .string(resolved)
                })
            default:
                continue
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

    /// Folds git's repository discovery into the verdict: `git -C <dir>` walks up to the nearest `.git`, so an in-project
    /// path can report on a parent repository. The verdict is `askUser`, not `refuse`: `git` is read-only, reads outside
    /// the project ask, and a parent-repo layout is legitimate.
    private static func applyRepositoryDiscovery(
        toolName: String,
        arguments: [String: JSONValue],
        root: String,
        current: Outcome,
        locator: GitRepositoryLocator
    ) -> Outcome {
        guard toolName == "git" else { return current }

        // Only when the argument check found nothing to object to: a path already outside the project has its own verdict,
        // and asking twice would park the run on two banners for one tool.
        guard case .proceed = current else { return current }

        guard case .string(let start)? = arguments["path"], !start.isEmpty else { return current }

        // Nil means "not in a repository", or git was unavailable. Either way there is nothing
        // to confine: the tool will report the failure itself.
        guard let discovered = locator.toplevel(start) else { return current }

        let canonicalRoot = WorkspaceBoundary.canonical(root)
        let repository = WorkspaceBoundary.canonical(discovered)
        guard !WorkspaceBoundary.isWithin(repository, root: canonicalRoot) else { return current }

        let projectName = (canonicalRoot as NSString).lastPathComponent
        logger.notice("[WORKSPACE] 'git' path \(start) is inside the project, but git resolves it to the repository at \(repository), which is OUTSIDE '\(projectName)'. CONSEQUENCE: the call is routed through the ordinary confirmation banner instead of silently reporting on a repository the user did not point the agent at; the path argument alone could never have caught this, because git discovers its repository by walking upwards.")

        return .askUser(reason:
            "'git' would operate on the repository at \(repository), which git finds by "
            + "walking up from \(start). That repository is outside the '\(projectName)' project, "
            + "so its status, log, diff and blame cover files the project folder does not contain."
        )
    }
}
