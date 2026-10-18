// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
//
//  GitBranchReader.swift
//  Devgentic
//
//  Created by Raj Singh.
//

import Foundation

/// Reads the active Git branch from `.git/HEAD` for a repository directory without spawning a shell process.
enum GitBranchReader {
    /// Reads the current branch or short commit SHA for a project directory.
    static func branch(for directoryURL: URL) -> String? {
        let dotGitURL = directoryURL.appendingPathComponent(".git")
        var headURL = dotGitURL.appendingPathComponent("HEAD")

        // Handle git worktree or submodule where .git is a file containing "gitdir: <path>"
        var isDir: ObjCBool = false
        if FileManager.default.fileExists(atPath: dotGitURL.path, isDirectory: &isDir) {
            if !isDir.boolValue {
                guard let content = try? String(contentsOf: dotGitURL, encoding: .utf8) else { return nil }
                let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
                if trimmed.hasPrefix("gitdir:") {
                    let rawPath = trimmed.dropFirst("gitdir:".count).trimmingCharacters(in: .whitespaces)
                    let resolvedURL = URL(fileURLWithPath: rawPath, relativeTo: directoryURL).standardized
                    headURL = resolvedURL.appendingPathComponent("HEAD")
                }
            }
        } else {
            return nil
        }

        guard let headContent = try? String(contentsOf: headURL, encoding: .utf8) else { return nil }
        let trimmed = headContent.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix("ref: refs/heads/") {
            return String(trimmed.dropFirst("ref: refs/heads/".count))
        } else if trimmed.count >= 7 {
            return String(trimmed.prefix(7))
        }
        return nil
    }
}
