// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
//
//  SkillLibraryMigration.swift
//  Devgentic
//
//  Carrying V4/V5's folder-indexed skills across into the V6 library.
//
//  ## The one-window problem
//
//  V4/V5 stored an index: the database said a skill existed and named the folder holding its bytes.
//  V6 stores the bytes and has no folder at all. So the migration needs something the two shapes do
//  not share — the folder paths — and the rows holding them are exactly what the migration removes.
//
//  There is one moment when both facts are available: `willMigrate`, which runs against the OLD
//  shape. This file uses it for the narrowest possible job — read the paths, write them down, touch
//  nothing else — and leaves the actual ingest to a launch-time sweep.
//
//  ⚠️ **Deliberately NOT ingesting inside the hook.** Ingest reads every file of every skill, which
//  can be thousands of files on an unmounted volume or a network share. Doing that inside a
//  migration means an operation that can hang or half-fail while the store is mid-upgrade, with no
//  way to report which skill failed and no way for the user to retry. A migration should move
//  structure and get out. The sweep can take its time, skip what it cannot read, and say so.
//
//  ⚠️ The capture file is a HINT, not a record of truth. Losing it costs the user re-adding their
//  skills; acting on a corrupt one must cost nothing, so every path is re-validated at ingest.
//

import Foundation
import SwiftData
import os

private let logger = DGLogger(category: "SkillLibraryMigration")

enum SkillLibraryMigration {

    /// One pre-V6 skill, reduced to what the ingest needs.
    struct LegacySkillRef: Codable, Sendable, Equatable {
        let folderPath: String
        let name: String

        // ⚠️⚠️ `isAgentWritable` WAS REMOVED HERE (2026-09-15). It carried an agent-write permission
        // across the migration, and its only source was `SkillManifestSD.isAgentWritable` — a V5
        // attribute that never shipped. With the capture hook deleted, the sole remaining
        // construction site (`harvestLegacyFolders`) could only ever pass `false`, so the branch
        // that read it was unreachable and the field was a permission that could never be carried.
        //
        // ⚠️ A skill recovered from a pre-V6 profile therefore arrives NOT agent-writable, which is
        // the correct default anyway: `update_skill` is default-deny and the user re-grants it
        // deliberately. Nothing is silently granted by a migration.
    }

    /// Where the hint file lives. Overridable so tests never touch the real Application Support.
    nonisolated(unsafe) static var captureURLOverride: URL?

    static var captureURL: URL {
        if let captureURLOverride { return captureURLOverride }

        // ⚠️⚠️ REDIRECTED IN THE TEST HOST, and this was found in the field — on the developer's own
        // machine, not in a test.
        //
        // The write used to happen inside `willMigrate` (see below — that hook is gone), so ANY
        // test that opened a pre-V6 store wrote this file. `SchemaMigrationTests` migrated a
        // checked-in fixture containing a registry row, so an ordinary `test-without-building` run left
        // `~/Library/Application Support/Devgentic/pending-skill-import.json` pointing at
        // `/tmp/skills/fixture-skill`. The next REAL launch would have tried to import a phantom
        // skill, failed, written it back, and retried on every launch after that.
        //
        // The per-test override was not enough precisely because the write happened somewhere no
        // test explicitly called. The sweep writes it now, which is reachable — but the redirect
        // stays: it is what makes the test host structurally unable to touch real user data here. Redirecting on `TestHost.isRunning` covers the path nobody thought to
        // guard — which is the whole reason this codebase redirects persistence rather than trusting
        // every caller to remember. (Refuse outward effects; REDIRECT persistence.)
        if TestHost.isRunning {
            return FileManager.default.temporaryDirectory
                .appendingPathComponent("devgentic-testhost-pending-skill-import.json")
        }

        let appSupport = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Devgentic", isDirectory: true)
        return appSupport.appendingPathComponent("pending-skill-import.json")
    }

    // MARK: - The capture hook is gone

    // ⚠️⚠️ `captureLegacyFolderPaths` WAS DELETED WITH SCHEMA V5 (2026-09-15). It ran inside
    // `willMigrate` on the V5→V6 stage and read folder paths out of `SkillManifestSD` before that
    // entity was retired — and **it never once fired in the field**, because V4 and V5 only ever
    // existed in a development build. Every real store is at V3, where that table does not exist,
    // so the capture wrote nothing and the launch sweep, sourced from it, silently discarded every
    // upgrading user's skills.
    //
    // The addresses were never actually lost: they are in each profile's `skillSelections` as
    // `legacyFolderPath`, put there by `ProfileMigrator.migrateToV9` on the read path.
    // `SkillLibraryImportSweep.harvestLegacyFolders` reads them from there, which needs no
    // migration hook and no window during the upgrade.
    //
    // ⚠️ The file below SURVIVES, with a narrower job: it is now purely a record of folders the
    // last sweep could not read, so the Skills library can show them with a Retry. It is no longer
    // an input to the migration and nothing writes it during one.

    /// Reads the hint file WITHOUT clearing it. Returns an empty array when there is nothing pending.
    ///
    /// ⚠️ Read and clear are SEPARATE, and that split is the whole safety property. A single
    /// take-and-clear looked tidier and was wrong: the sweep ingests folders and then re-links every
    /// profile, and a crash between those two steps would leave the skills in the library, the
    /// profiles still pointing at nothing, and the only record of how to connect them already
    /// deleted. The sweep clears this only after the profile pass has finished.
    static func peekPendingImports() -> [LegacySkillRef] {
        let url = captureURL
        guard FileManager.default.fileExists(atPath: url.path) else { return [] }
        do {
            return try JSONDecoder().decode([LegacySkillRef].self, from: Data(contentsOf: url))
        } catch {
            logger.error("[SKILL_MIGRATE] The pending-import file could not be read: \(error.localizedDescription). CONSEQUENCE: pre-V6 skills are NOT imported — the file is left in place rather than deleted, so a fix to this build can still recover it, and the user is told their old skills need re-adding.")
            return []
        }
    }

    /// Replaces the hint file with `remaining`, or removes it when nothing is left.
    ///
    /// ⚠️ Failures are written BACK rather than discarded. A folder on a volume that was not mounted
    /// at this launch is the ordinary case, and dropping it would silently lose skills the user
    /// still has. What that costs is a retry every launch until it succeeds or the user clears it —
    /// which is why the outcome reports them, so the UI can offer exactly that.
    static func setPendingImports(_ remaining: [LegacySkillRef]) {
        let url = captureURL
        guard !remaining.isEmpty else {
            do { try FileManager.default.removeItem(at: url) }
            catch CocoaError.fileNoSuchFile {}
            catch {
                logger.error("[SKILL_MIGRATE] Could not remove the pending-import file at \(url.path): \(error.localizedDescription). CONSEQUENCE: the next launch will try to import the same skills again, which would DUPLICATE them in the library — delete the file by hand if duplicates appear.")
            }
            return
        }
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try encoder.encode(remaining).write(to: url, options: .atomic)
        } catch {
            logger.error("[SKILL_MIGRATE] Could not rewrite the pending-import file: \(error.localizedDescription). CONSEQUENCE: \(remaining.count) folder(s) that failed to import will NOT be retried on the next launch — the user must re-add them by hand.")
        }
    }
}
