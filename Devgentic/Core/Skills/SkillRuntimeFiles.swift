// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2026 Raj Singh
//
//  SkillRuntimeFiles.swift
//  Devgentic
//
//  Putting a skill's bundled files somewhere a shell command can actually reach them.
//
//  ## Why this exists
//
//  ⚠️⚠️ A SKILL COULD BUNDLE `scripts/analyze.py`, SAY "run `python scripts/analyze.py`", AND HAVE
//  NO FILE ANYWHERE ON DISK. Since V6 a skill's files live in the database as `SkillFileSD.content`
//  blobs. `load_skill` handed the model their TEXT and nothing more, so the instruction named a path
//  that did not exist. Worse, the presence of `scripts/` is one of the two triggers that offers the
//  profile a shell tool (`SkillCapabilityHints`) — so the app asked the user to grant shell access
//  for scripts it had not written down. The offer was real and the file was not.
//
//  This materialises a resolved version to a real directory and hands back the root, so the paths in
//  the instructions resolve and the granted shell tool has something to run.
//
//  ## What it is NOT
//
//  ⚠️ Not a cache of the library and not a writable working copy. It is a read-oriented projection
//  of ONE immutable version. Versions never change, so a directory that already exists for a version
//  id is already correct and is reused rather than rewritten — which is also what keeps repeated
//  `load_skill` calls in one conversation cheap.
//
//  ⚠️ Nothing reads these files back into the library. An agent that edits a materialised file has
//  changed a projection, not the skill; `update_skill` remains the only path that writes a version.
//

import Foundation

private let logger = DGLogger(category: "SkillRuntimeFiles")

enum SkillRuntimeFiles {

    /// Root of the per-run projection area.
    ///
    /// ⚠️ Under the system temporary directory on purpose: it is derived data that the OS may
    /// reclaim, and losing it costs one re-materialisation rather than any user content.
    static var root: URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("devgentic-skill-files", isDirectory: true)
    }

    /// Writes a version's bundled files to disk and returns the directory holding them.
    ///
    /// Returns nil when the version bundles nothing — there is no directory to name, and naming an
    /// empty one would invite the model to look for files that do not exist.
    ///
    /// ⚠️ TOTAL. A skill whose files cannot be written must still load: the instructions are the
    /// part that matters, and refusing the whole skill because a projection failed would turn a
    /// degraded run into no run. The failure is logged with its consequence and the caller simply
    /// gets nil.
    @MainActor
    static func materialize(version: SkillVersionSD, name: String) -> URL? {
        guard !version.orderedFiles.isEmpty else { return nil }

        // Keyed by VERSION id, which is immutable — so this is content-addressed in practice and a
        // pinned older version never collides with `latest`.
        let parent = root.appendingPathComponent(version.id, isDirectory: true)
        let expected = parent.appendingPathComponent(name, isDirectory: true)

        // Already projected by an earlier call in this run (or an earlier run): versions are
        // immutable, so what is there is what we would write.
        //
        // ⚠️⚠️ THIS CHECK IS ONLY SOUND BECAUSE `SkillMaterializer.write` WRITES SKILL.md LAST.
        // It used to be written FIRST, which made this a sentinel that lied: a write that threw on
        // a bundled file left SKILL.md behind, and this branch then handed the caller a directory
        // containing nothing else — so the first call returned nil honestly and the second claimed
        // success, silently, for a tree whose `scripts/run.py` did not exist. If anyone moves that
        // write back above the file loop, this returns to being a bug; `SkillMaterializerTests`
        // guards the ordering.
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
