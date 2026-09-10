// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2026 Raj Singh
//
//  ShellExitStatus.swift
//  Devgentic
//
//  One owner of the `Exit code: N` line the shell tools emit — the format AND the parse — so
//  the producer and the reader cannot drift apart.
//
//  Why a string contract at all: `DevgenticTool.call` returns `String`, and the mediator
//  receives `(output: String, artifacts: [MediaArtifact])`. There is no structured channel for
//  a tool to report metadata, so carrying an exit code the honest way would mean changing the
//  tool protocol and three layers beneath it. This confines the string to ONE emitter helper
//  and ONE parser, both ours, pinned by tests — a contract between our own components rather
//  than a heuristic over arbitrary payload. `ToolExecutionMediator.isSemanticFailure` is the
//  cautionary counter-example: sniffing untrusted output for "error"-ness, which three
//  different tool authors then defeated by choosing three different prefixes.
//
//  WHY THE EXIT CODE IS CARRIED AT ALL, when successful tool output is not:
//  a successful read is repeatable, so re-reading beats storing it. A verdict is not. Re-running
//  `swift build` after the agent edited the code answers a DIFFERENT question than the one the
//  original run answered, so "it exited 1" cannot be re-derived — the same argument that
//  justifies `<effect>` for writes.
//

import Foundation

enum ShellExitStatus {

    private static let prefix = "Exit code: "

    /// Prefixes output with the command's exit status. Shell tools call this instead of
    /// formatting the line themselves.
    static func annotate(_ output: String, exitCode: Int32) -> String {
        "\(prefix)\(exitCode)\n\(output)"
    }

    /// The exit status an annotated output carries, or nil when there is none.
    ///
    /// Deliberately strict: the prefix must open the string and be followed by digits on its
    /// own line. A tool that merely PRINTS something similar further down is not reporting a
    /// status, and must not be read as one.
    static func parse(_ output: String?) -> Int32? {
        guard let output, output.hasPrefix(prefix) else { return nil }
        let afterPrefix = output.dropFirst(prefix.count)
        let digits = afterPrefix.prefix { $0.isNumber || $0 == "-" }
        guard !digits.isEmpty,
              afterPrefix.dropFirst(digits.count).first?.isNewline ?? true,
              let code = Int32(digits) else { return nil }
        return code
    }
}
