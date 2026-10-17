// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
//
//  GitUICommand.swift
//  Devgentic
//
//  The ONLY place the Git Changes panel builds a git argv or environment.
//

import Foundation

private let logger = DGLogger(category: "GitUI")

/// One git invocation: argv (after the executable) plus environment OVERRIDES. The runner merges
/// the overrides over the inherited environment.
struct GitInvocation: Equatable, Sendable {
    let arguments: [String]
    let environment: [String: String]
}

/// What a runner hands back. `standardOutput` is raw bytes — the parsers split on NUL.
struct GitRunOutput: Sendable {
    let standardOutput: Data
    let standardError: String
    let exitCode: Int32
    /// False when stdout is not the whole output: the capture cap elided its middle, a descendant
    /// held the pipe, or the time bound killed git. A parse of an incomplete stream is shown as
    /// truncated, never as the full list.
    let isComplete: Bool

    var succeeded: Bool { exitCode == 0 }
}

/// Runs one invocation. Injected into `GitChangesStore` so tests feed canned git output and record
/// every invocation the store makes — no processes.
typealias GitCommandRunner = @Sendable (GitInvocation) async throws -> GitRunOutput

/// Builds every git command the panel runs.
///
/// ⚠️ Every invocation carries, by construction:
/// - `GitCommandBuilder.hardening` — neutralises repo-supplied programs (`core.fsmonitor` fires on a
///   bare `status`; `diff.external` on a bare `diff`). Shared with the agent's `git` tool so the
///   security review is not re-derived here.
/// - `GIT_OPTIONAL_LOCKS=0` — `git status` otherwise opportunistically rewrites the index stat cache
///   under `.git/index.lock`; a background refresh racing the user's own `git commit` makes THEIR
///   command fail with "index.lock: File exists". The panel is read-only only with this set.
/// - `TERM=dumb`.
/// Diff-family commands also carry `diffProgramSuppression` (`.gitattributes` drivers).
///
/// The UI never forwards user-typed git arguments; every argv is assembled here from typed inputs.
enum GitUICommand {

    static let executable = "/usr/bin/git"

    /// Shared with the agent's `git` tool and `GitRepositoryLocator` — see
    /// `GitCommandBuilder.environmentOverrides` for why each entry is there.
    static let environmentOverrides: [String: String] = GitCommandBuilder.environmentOverrides

    /// Which committed side of a file to read.
    enum BlobSide: Equatable, Sendable {
        case head
        case index
    }

    /// `rev-parse --show-toplevel --absolute-git-dir`: the repository root (porcelain and numstat
    /// paths are relative to it, NOT to the project folder) and the git dir (for merge/rebase state;
    /// in a linked worktree `.git` is a file, so the dir must be asked for, not assumed).
    static func locate(directory: String) -> GitInvocation {
        invocation(in: directory, ["rev-parse", "--show-toplevel", "--absolute-git-dir"])
    }

    static func status(repoRoot: String) -> GitInvocation {
        invocation(in: repoRoot, ["status", "--porcelain=v2", "--branch", "-z", "--untracked-files=all"])
    }

    /// `-M` is pinned: it overrides the user's `diff.renames`, so a rename always arrives in the
    /// one record shape `GitNumstatParser` reads (verified against git 2.54).
    static func numstat(repoRoot: String, staged: Bool) -> GitInvocation {
        invocation(in: repoRoot,
                   ["diff"] + (staged ? ["--cached"] : []) + ["--numstat", "-z", "-M"],
                   diffFamily: true)
    }

    /// One side of a file, for the diff view.
    ///
    /// ⚠️ The index form is `:0:<path>`, never `:<path>`. Verified: with a file named `0:x.txt`,
    /// `:0:x.txt` is parsed as STAGE 0 of `x.txt` — a different file. The explicit stage makes the
    /// remainder unambiguously a path.
    ///
    /// `cat-file blob` rather than `show`: plumbing, prints the raw blob, and never applies a
    /// textconv filter (that is opt-in for cat-file; `show`'s behaviour depends on its defaults).
    static func blob(repoRoot: String, side: BlobSide, path: String) -> GitInvocation {
        invocation(in: repoRoot, ["cat-file", "blob", object(side: side, path: path)])
    }

    /// `cat-file -s`: the blob's size in bytes, WITHOUT transferring it. Asked before `blob` so a side
    /// over the diff limit is refused for the cost of one tiny process instead of streaming up to
    /// ProcessRunner's capture cap (16 MB) only to discard it.
    static func blobSize(repoRoot: String, side: BlobSide, path: String) -> GitInvocation {
        invocation(in: repoRoot, ["cat-file", "-s", object(side: side, path: path)])
    }

    /// One construction of the object name for both reads, so they can never name different
    /// objects. See `blob` for why the index form is `:0:`.
    private static func object(side: BlobSide, path: String) -> String {
        switch side {
        case .head:  return "HEAD:" + path
        case .index: return ":0:" + path
        }
    }

    // MARK: - Private

    private static func invocation(in directory: String, _ subcommand: [String],
                                   diffFamily: Bool = false) -> GitInvocation {
        GitInvocation(
            arguments: ["-C", directory] + GitCommandBuilder.hardening + subcommand
                + (diffFamily ? GitCommandBuilder.diffProgramSuppression : []),
            environment: environmentOverrides
        )
    }
}

// MARK: - Live runner

extension GitUICommand {

    /// Upper bound per git call. `status` on a huge or network-mounted repo can stall; past this
    /// the panel reports a failure instead of spinning forever.
    static let timeout: TimeInterval = 30

    /// Runs `/usr/bin/git` through `ProcessRunner` off the caller's actor.
    static let liveRunner: GitCommandRunner = { invocation in
        try await Task.detached(priority: .utility) {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: executable)
            process.arguments = invocation.arguments
            process.environment = ProcessInfo.processInfo.environment
                .merging(invocation.environment) { _, override in override }
            let timed = try ProcessRunner.run(process, timeout: timeout)
            let result = timed.result
            return GitRunOutput(
                standardOutput: Data(result.standardOutput.utf8),
                standardError: result.standardError,
                exitCode: result.exitCode,
                isComplete: result.outputComplete && result.standardOutputElidedBytes == 0 && !timed.timedOut
            )
        }.value
    }

    /// Whether git can run without the Command Line Tools install dialog.
    ///
    /// `/usr/bin/git` is an `xcrun` shim: on a Mac without CLT, EVERY call pops the installer. So
    /// this is asked once per launch through `xcode-select -p` (exit 0 ⇔ a developer dir exists),
    /// which never triggers the dialog, and the panel shows an explainer instead of calling git.
    static let isGitAvailable: Bool = {
        do {
            let result = try ProcessRunner.run(executable: "/usr/bin/xcode-select", arguments: ["-p"])
            if !result.succeeded {
                logger.notice("[GitUI] xcode-select -p exited \(result.exitCode) — no developer tools. CONSEQUENCE: the Git Changes panel shows the install-tools explainer and never invokes git this launch.")
            }
            return result.succeeded
        } catch {
            logger.error("[GitUI] Could not run xcode-select: \(error.localizedDescription). CONSEQUENCE: git treated as unavailable this launch; the Git Changes panel shows the install-tools explainer.")
            return false
        }
    }()
}
