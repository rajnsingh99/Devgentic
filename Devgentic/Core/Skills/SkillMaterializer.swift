// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2026 Raj Singh
//
//  SkillMaterializer.swift
//  Devgentic
//
//  Writing a stored skill version back out as a real folder.
//
//  ## Why this exists at all
//
//  V6 made the library the only copy of a skill. That is the point — no dangling paths, no
//  reconciliation — but it means the user cannot get their own content back with Finder, and a
//  format whose whole appeal is "plain files you can read" must not become a one-way door. Export
//  is the escape hatch, and an escape hatch that loses fidelity is not one.
//
//  So this is the inverse of `SkillIngest`, and the pair has to round-trip:
//
//    - `SKILL.md` is REBUILT from the stored fields rather than stored whole, because the fields are
//      what the app actually edits. Rebuilding is what makes an exported file agree with what the
//      library showed.
//    - Every bundled file is written at its stored relative path, directories created as needed.
//    - The executable bit is restored. A `scripts/run.sh` that arrives runnable and leaves
//      non-runnable is a skill that worked before the round trip and does not after — a silent,
//      delayed failure with no visible cause.
//
//  ⚠️ EVERY path is re-validated here even though ingest validated it. A stored row is data, and
//  this is the moment it becomes a filesystem operation under a directory the user chose. `..` in a
//  stored `relativePath` would write outside the destination; the check costs nothing and the
//  alternative is trusting that no future write path ever inserts an unvalidated row.
//

import Foundation
import os

private let logger = DGLogger(category: "SkillMaterializer")

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

        // ⚠️ VALIDATE BEFORE BUILDING A PATH FROM IT, even though `name` is a stored database field
        // rather than archive content. This is the one place a skill name becomes a filesystem path
        // again, and it is the exact shape of a defect this codebase already shipped once: the old
        // importer derived a directory from an untrusted frontmatter `name` and handed it to
        // `removeItem`, so `name: ../../../../victim` deleted `/victim`. Ingest and the create sheet
        // both validate on the way in, so a stored name should already be safe — "should already be"
        // is precisely the assumption that failed last time, and the check costs nothing.
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
            try skillMarkdown(name: name,
                              description: version.skillDescription,
                              allowedTools: allowedTools,
                              body: version.body)
                .write(to: root.appendingPathComponent("SKILL.md"), atomically: true, encoding: .utf8)
        } catch {
            throw SkillMaterializeError.writeFailed(error.localizedDescription)
        }

        let rootPath = root.standardizedFileURL.path
        for file in version.orderedFiles {
            // ⚠️ TWO checks, and they catch different things — verified by mutation, because the
            // obvious reading is that this one is redundant. For a traversal like `../../x` the
            // prefix check below is what actually refuses it, since `appendingPathComponent`
            // contains the result under the root either way. What THIS one uniquely refuses is a
            // path that would be silently NORMALISED — `a/./b` writes to `a/b`, `/etc/x` writes to
            // `etc/x` — so the exported tree would no longer match the stored paths. Fidelity, not
            // confinement; the next check is the confinement.
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

        logger.info("[SKILL_EXPORT] Materialized '\(name)' (version \(version.id)) with \(version.files.count) file(s) at \(root.path).")
        return root
    }

    /// Rebuilds a SKILL.md from stored fields.
    ///
    /// ⚠️ Emits `description` as a QUOTED scalar when it needs to be, and `allowed-tools` as a flow
    /// sequence. `YAMLFrontmatterParser` must be able to read back what this writes — a description
    /// containing a colon, or starting with `[`, would otherwise export as a file the app itself
    /// cannot re-import. Pinned by the round-trip test.
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
    ///
    /// ⚠️ Conditional rather than always-quote, for the reason this codebase has been bitten by
    /// four times: a transform that rewrites content by shape-matching it. The overwhelming majority
    /// of descriptions are ordinary prose and must come back byte-identical.
    static func yamlScalar(_ value: String) -> String {
        let collapsed = value
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        let needsQuotes = collapsed.isEmpty
            || collapsed.contains(": ")
            || collapsed.hasSuffix(":")
            || collapsed.contains(" #")
            || "[]{}&*!|>'\"%@`,".contains(collapsed.first ?? "x")
        guard needsQuotes else { return collapsed }
        return "\"\(collapsed.replacingOccurrences(of: "\"", with: "'"))\""
    }
}
