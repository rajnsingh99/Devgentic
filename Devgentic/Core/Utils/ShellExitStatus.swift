// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
//
//  ShellExitStatus.swift
//  Devgentic
//
//  Created by Raj Singh.
//

import Foundation

/// The single owner of the `Exit code: N` line the shell tools emit, both format and parse, so they cannot drift.
/// A string contract because `DevgenticTool.call` returns `String`: one emitter helper and one parser, both tested.
enum ShellExitStatus {

    private static let prefix = "Exit code: "

    /// Prefixes output with the command's exit status. Shell tools call this instead of
    /// formatting the line themselves.
    static func annotate(_ output: String, exitCode: Int32) -> String {
        "\(prefix)\(exitCode)\n\(output)"
    }

    /// The exit status an annotated output carries, or nil when there is none.
    /// Strict: the prefix must open the string and be followed by digits on its own line; similar text printed further down
    /// is not a status.
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
