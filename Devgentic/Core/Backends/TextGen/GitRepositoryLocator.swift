// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
//
//  GitRepositoryLocator.swift
//  Devgentic
//
//  Created by Raj Singh.
//

import Foundation

private let logger = DGLogger(category: "GitRepositoryLocator")

// Why: `git -C <dir>` walks UP to the nearest `.git`, so validating the argument cannot catch an escape to a parent
// repo; the boundary asks git where it would go and applies the policy to that answer.
/// Resolves the repository root git would discover from a directory.
/// Injectable so boundary decisions are unit-testable without a real repository on disk.
struct GitRepositoryLocator: Sendable {

    /// Returns the absolute repository toplevel for `directory`, or nil when it is not inside a
    /// repository (or git is unavailable — which fails in the permissive direction on purpose:
    /// `git` will then report "not a git repository" itself, which is the honest message).
    let toplevel: @Sendable (_ directory: String) -> String?

    /// Asks the real git.
    static let live = GitRepositoryLocator { directory in
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: directory, isDirectory: &isDirectory) else { return nil }
        // `rev-parse` needs a directory to walk up from; a file path would resolve against the process cwd
        // instead and silently answer about the wrong repository.
        let start = isDirectory.boolValue ? directory : (directory as NSString).deletingLastPathComponent

        do {
            // Same hardening as the tool itself: this runs against a repository the user has not vouched for,
            // so no repo-nominated program may fire.
            let run = try ProcessRunner.run(
                executable: "/usr/bin/git",
                arguments: ["-C", start] + GitCommandBuilder.hardening + ["rev-parse", "--show-toplevel"],
                environment: GitCommandBuilder.environment()
            )
            guard run.succeeded else { return nil }
            let path = run.standardOutput.trimmingCharacters(in: .whitespacesAndNewlines)
            return path.isEmpty ? nil : path
        } catch {
            logger.error("[WORKSPACE] Could not ask git which repository '\(start)' belongs to: \(error.localizedDescription). CONSEQUENCE: the parent-repository check is SKIPPED for this call, so a git action whose repository lies outside the project runs without prompting. The path argument is still confined.")
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
