// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
//
//  SkillRuntimeFiles.swift
//  Devgentic
//
//  Created by Raj Singh.
//

import Foundation

private let logger = DGLogger(category: "SkillRuntimeFiles")

/// Materialises a resolved skill version's bundled files into a real directory, so paths in its instructions resolve
/// and a granted shell tool can run them. A read-only projection of one immutable version, reused when it exists;
/// not a library cache or a writable copy. `update_skill` is the only path that writes a version.
enum SkillRuntimeFiles {

    /// Root of the per-run projection area, under the system temporary directory.
    /// It is derived data the OS may reclaim; losing it costs one re-materialisation.
    static var root: URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("devgentic-skill-files", isDirectory: true)
    }

    /// Writes a version's bundled files to disk and returns the directory holding them, or nil if it bundles nothing.
    /// Total: a write failure is logged with its consequence and yields nil, so the skill's instructions still load.
    @MainActor
    static func materialize(version: SkillVersionSD, name: String) -> URL? {
        guard !version.orderedFiles.isEmpty else { return nil }

        // Keyed by VERSION id, which is immutable — so this is content-addressed in practice and a
        // pinned older version never collides with `latest`.
        let parent = root.appendingPathComponent(version.id, isDirectory: true)
        let expected = parent.appendingPathComponent(name, isDirectory: true)

        // Already projected by an earlier call: versions are immutable, so what is there is what would be written.
        // Sound only because `SkillMaterializer.write` writes SKILL.md last; moving it above the file loop breaks this check.
        if FileManager.default.fileExists(atPath: expected.appendingPathComponent("SKILL.md").path) {
            return expected
        }

        do {
            let written = try SkillMaterializer.write(
                version: version,
                name: name,
                allowedTools: version.allowedTools,
                into: parent)
            logger.info("[SKILL_FILES] Materialised \(version.orderedFiles.count) bundled file(s) for '\(name)' at \(written.path). CONSEQUENCE: paths named in the instructions now resolve, so a granted shell tool can run them.")
            return written
        } catch {
            logger.error("[SKILL_FILES] Could not materialise bundled files for '\(name)': \(error.localizedDescription). CONSEQUENCE: the skill still loads and its instructions are returned in full, but any path they name (for example scripts/run.py) does NOT exist on disk — a shell command using one will fail with 'no such file'.")
            return nil
        }
    }
}
