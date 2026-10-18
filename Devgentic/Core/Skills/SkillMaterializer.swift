// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
//
//  SkillMaterializer.swift
//  Devgentic
//
//  Created by Raj Singh.
//

import Foundation
import os

private let logger = DGLogger(category: "SkillMaterializer")

/// Errors from writing a stored skill version back out as a real folder, the inverse of `SkillIngest`.
/// Every path is re-validated before it becomes a filesystem operation under the destination.
enum SkillMaterializeError: LocalizedError {
    case unsafePath(String)
    case writeFailed(String)

    var errorDescription: String? {
        switch self {
        case .unsafePath(let path): return "This skill contains a file with an unusable path: \(path)"
        case .writeFailed(let detail): return "Could not write the skill: \(detail)"
        }
    }
}

enum SkillMaterializer {

    /// Writes `version` as a skill folder named `name` inside `parent`, returning the folder.
    @MainActor
    static func write(
        version: SkillVersionSD,
        name: String,
        allowedTools: [String]?,
        into parent: URL
    ) throws -> URL {
        let fm = FileManager.default

        // Validates the name before building a path from it: this is where a skill name becomes a filesystem path again,
        // and a stored name should be safe but is not trusted.
        do { try SkillFolderScanner.validateSkillNameShape(name) }
        catch { throw SkillMaterializeError.unsafePath(name) }

        let root = parent.appendingPathComponent(name, isDirectory: true)
        guard root.standardizedFileURL.path.hasPrefix(
            parent.standardizedFileURL.path.hasSuffix("/")
                ? parent.standardizedFileURL.path
                : parent.standardizedFileURL.path + "/") else {
            throw SkillMaterializeError.unsafePath(name)
        }

        do {
            try fm.createDirectory(at: root, withIntermediateDirectories: true)
        } catch {
            throw SkillMaterializeError.writeFailed(error.localizedDescription)
        }

        let rootPath = root.standardizedFileURL.path
        for file in version.orderedFiles {
            // Two checks catch different things: this one refuses paths that would be silently normalised (`a/./b`, `/etc/x`),
            // so the exported tree matches the stored paths; the prefix check below is the actual confinement.
            guard SkillIngest.isSafeRelativePath(file.relativePath) else {
                throw SkillMaterializeError.unsafePath(file.relativePath)
            }
            let destination = root.appendingPathComponent(file.relativePath)
            // Belt and braces: the path check above should make this unreachable, and it is here so
            // that if it ever is reachable the write does not happen.
            guard destination.standardizedFileURL.path.hasPrefix(rootPath) else {
                throw SkillMaterializeError.unsafePath(file.relativePath)
            }
            do {
                try fm.createDirectory(at: destination.deletingLastPathComponent(),
                                       withIntermediateDirectories: true)
                try file.content.write(to: destination, options: .atomic)
                if file.isExecutable {
                    try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: destination.path)
                }
            } catch {
                throw SkillMaterializeError.writeFailed("\(file.relativePath): \(error.localizedDescription)")
            }
        }

        // SKILL.md is written last: its presence is how `SkillRuntimeFiles.materialize` detects a fully projected skill,
        // so writing it first would let a failed bundled write look complete. Retrying over a partial tree is safe.
        do {
            try skillMarkdown(name: name,
                              description: version.skillDescription,
                              allowedTools: allowedTools,
                              body: version.body)
                .write(to: root.appendingPathComponent("SKILL.md"), atomically: true, encoding: .utf8)
        } catch {
            throw SkillMaterializeError.writeFailed("SKILL.md: \(error.localizedDescription)")
        }

        logger.info("[SKILL_EXPORT] Materialized '\(name)' (version \(version.id)) with \(version.files.count) file(s) at \(root.path).")
        return root
    }

    /// Rebuilds a SKILL.md from stored fields.
    /// Quotes `description` when needed and emits `allowed-tools` as a flow sequence so the app can re-import the file.
    static func skillMarkdown(
        name: String,
        description: String,
        allowedTools: [String]?,
        body: String
    ) -> String {
        var lines = ["---", "name: \(name)", "description: \(yamlScalar(description))"]
        if let allowedTools {
            let elements = allowedTools.map(yamlScalar).joined(separator: ", ")
            lines.append("allowed-tools: [\(elements)]")
        }
        lines.append("---")
        lines.append("")
        lines.append(body)
        return lines.joined(separator: "\n") + "\n"
    }

    /// Quotes a scalar only when leaving it bare would change how it parses.
    /// Conditional rather than always-quote so ordinary prose descriptions come back byte-identical.
    static func yamlScalar(_ value: String) -> String {
        let collapsed = value
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        // Leading `#`, `-` and `?` need quotes: `#` opens a comment (reads back empty), `- ` a sequence, `? ` a complex key.
        // Over-quoting is harmless since the `''` escape is reversible; under-quoting loses content.
        let needsQuotes = collapsed.isEmpty
            || collapsed.contains(": ")
            || collapsed.hasSuffix(":")
            || collapsed.contains(" #")
            || "[]{}&*!|>'\"%@`,#-?".contains(collapsed.first ?? "x")
        guard needsQuotes else { return collapsed }

        // Single-quoted, with `''` as the escape: `YAMLFrontmatterParser` processes no escapes in double-quoted scalars.
        // `SkillFolderScanner.unquote` must collapse `''` on the way back in; the two halves are one encoding.
        return "'\(collapsed.replacingOccurrences(of: "'", with: "''"))'"
    }
}
