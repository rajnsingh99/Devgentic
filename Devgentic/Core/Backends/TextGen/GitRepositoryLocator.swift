// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
//
//  GitRepositoryLocator.swift
//  Devgentic
//
//  Answers "which repository would git actually operate on from here?" so the workspace
//  boundary can check git's BEHAVIOUR rather than only its arguments.
//

import Foundation

private let logger = DGLogger(category: "GitRepositoryLocator")

/// Resolves the repository root git would discover from a directory.
///
/// ⚠️⚠️ WHY THIS EXISTS. `WorkspaceBoundary` validates the path a tool was HANDED. That is
/// sufficient for every other preset tool, because `read_file("<root>/x")` reads exactly
/// `<root>/x`. It is not sufficient for `git_tool`, because `git -C <dir>` does not operate on
/// `<dir>` — it walks UP from `<dir>` until it finds a `.git`, and operates on whatever it finds.
///
/// Field-observed 2026-09-20: a Code session rooted at `…/cp-dsa/java` ran `git_tool(status)`
/// with a perfectly compliant in-project path. The repository is at `…/cp-dsa`, one level ABOVE
/// the project, so `status --short` returned the parent repo's changes — files the project folder
/// does not contain — and the boundary had nothing to object to, because the ARGUMENT was fine.
///
/// **Argument validation structurally cannot catch this.** The escape is in git's discovery
/// algorithm, not in the string. So the boundary asks git where it would go, and applies the
/// ordinary policy to the ANSWER.
///
/// Injectable because the boundary decision must stay unit-testable without a real repository on
/// disk — and because a test that had to `git init` a fixture to assert a policy would be
/// asserting git's behaviour rather than ours.
struct GitRepositoryLocator: Sendable {

    /// Returns the absolute repository toplevel for `directory`, or nil when it is not inside a
    /// repository (or git is unavailable — which fails in the permissive direction on purpose:
    /// `git_tool` will then report "not a git repository" itself, which is the honest message).
    let toplevel: @Sendable (_ directory: String) -> String?

    /// Asks the real git.
    static let live = GitRepositoryLocator { directory in
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: directory, isDirectory: &isDirectory) else { return nil }
        // `rev-parse` needs a DIRECTORY to walk up from. A file path (e.g. `blame` targeting a
        // file) would make git resolve relative to the process cwd instead — which is not the
        // project, and would silently answer about the wrong repository.
        let start = isDirectory.boolValue ? directory : (directory as NSString).deletingLastPathComponent

        do {
            // ⚠️ The SAME hardening the tool itself applies. `rev-parse --show-toplevel` does not
            // read the index or render a diff, so no repo-nominated program should fire here — but
            // this runs against a repository the user has not vouched for yet, which is the one
            // place not to rely on "should".
            var environment = ProcessInfo.processInfo.environment
            environment["TERM"] = "dumb"
            let run = try ProcessRunner.run(
                executable: "/usr/bin/git",
                arguments: ["-C", start] + GitCommandBuilder.hardening + ["rev-parse", "--show-toplevel"],
                environment: environment
            )
            guard run.succeeded else { return nil }
            let path = run.standardOutput.trimmingCharacters(in: .whitespacesAndNewlines)
            return path.isEmpty ? nil : path
        } catch {
            logger.error("[WORKSPACE] Could not ask git which repository '\(start)' belongs to: \(error.localizedDescription). CONSEQUENCE: the parent-repository check is SKIPPED for this call, so a git_tool action whose repository lies outside the project runs without prompting. The path argument is still confined.")
            return nil
        }
    }

    /// Never finds a repository. For tests, and for any call site that must not spawn a process.
    static let unavailable = GitRepositoryLocator { _ in nil }

    /// Fixed answer, for tests that need a repository root without one existing on disk.
    static func fixed(_ toplevel: String?) -> GitRepositoryLocator {
        GitRepositoryLocator { _ in toplevel }
    }
}
