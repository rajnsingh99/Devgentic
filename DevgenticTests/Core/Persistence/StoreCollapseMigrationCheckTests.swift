// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
//
//  StoreCollapseMigrationCheckTests.swift
//  devgenticTests
//
//  Can V4 and V5 be removed from the migration plan without breaking a real store?
//
//  ⚠️⚠️ THIS IS A GATE, NOT A UNIT TEST. V4 and V5 never shipped — the last released build is at V3
//  — so the tombstone entities, five frozen nested-model copies, the capture file and the whole
//  pre-V6 registry exist to serve stores that do not exist. Deleting them is cheap now and
//  permanent once the repo is published. The question this answers is whether a store that is
//  ALREADY at V6 (this developer's) still opens when the two intermediates are gone, and whether a
//  genuine pre-skills store migrates straight through.
//
//  ⚠️ Runs against COPIES of real stores taken from Application Support, not in-memory fixtures.
//  In-memory containers never exercise a version-stamped store at all, which is exactly why the
//  V6 migration reached this point having never completed against real data.
//
//  ⚠️ SKIPPED when the fixtures are absent, so this file is inert on any other machine. The skip is
//  inside each test, never in `setUp` — a skip there leaves `tearDown` unwinding unassigned state
//  and crashes the host (30s of interactive backtrace per test, learned the hard way).
//

import XCTest
import SwiftData
import SQLite3
@testable import devgentic

// ⚠️ The hypothetical "collapsed plan" this file used to define is GONE — it is
// `DevgenticMigrationPlan` now. The collapse shipped on 2026-09-15 and these tests assert against
// the real plan, because a second copy of it here would drift from production and keep passing.

/// Deliberately broken: omits V3, the version `preV3.store` is stamped at. The negative control.
enum PlanMissingV3UnderTest: SchemaMigrationPlan {
    static var schemas: [any VersionedSchema.Type] {
        [DevgenticSchemaV1.self, DevgenticSchemaV2.self, DevgenticSchemaV6.self]
    }
    static var stages: [MigrationStage] {
        [.lightweight(fromVersion: DevgenticSchemaV1.self, toVersion: DevgenticSchemaV2.self),
         .lightweight(fromVersion: DevgenticSchemaV2.self, toVersion: DevgenticSchemaV6.self)]
    }
}

final class StoreCollapseMigrationCheckTests: XCTestCase {

    /// The developer's real Application Support directory.
    ///
    /// ⚠️⚠️ READ ONLY, AND EVERY TEST COPIES BEFORE OPENING. Opening a store RUNS ITS MIGRATION and
    /// rewrites the file — pointing a `ModelContainer` at anything in here directly would silently
    /// upgrade this machine's real database as a side effect of running the test suite. `stagedCopy`
    /// is the only path to these files and it copies into the test's own temp directory first.
    /// Never change that.
    private static let fixtureRoot = URL(fileURLWithPath: NSHomeDirectory())
        .appendingPathComponent("Library/Application Support", isDirectory: true)

    private var work: URL!

    override func setUp() {
        super.setUp()
        work = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try? FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
    }

    override func tearDown() {
        // ⚠️ Optional-chained — a skipped test never assigned `work`.
        if let work { try? FileManager.default.removeItem(at: work) }
        super.tearDown()
    }

    /// A private copy, so a migration that rewrites the file cannot touch the investigation's copy.
    ///
    /// ⚠️ THE `-wal` AND `-shm` SIDECARS COME TOO. A SQLite database in WAL mode is the main file
    /// PLUS its write-ahead log; copying only `DevgenticSD.store` stages whatever was last
    /// checkpointed and silently drops everything committed since. This gate would then be reading a
    /// stale snapshot of the live store while claiming to read the live store — and it got away with
    /// it only because that WAL happened to be checkpointed. Copying them is also what lets the file
    /// be opened at all: WAL mode needs its shared-memory file, and without the sidecars SQLite
    /// fails with "unable to open database file". Absent sidecars are fine — a cleanly checkpointed
    /// fixture has none, and `copyItem` is simply skipped.
    private func stagedCopy(of name: String) throws -> URL {
        let source = Self.fixtureRoot.appendingPathComponent(name)
        try XCTSkipUnless(FileManager.default.fileExists(atPath: source.path),
                          "fixture \(name) absent — this gate only runs where the copies were made")
        let destination = work.appendingPathComponent(name)
        try FileManager.default.copyItem(at: source, to: destination)
        for suffix in ["-wal", "-shm"] {
            let sidecar = Self.fixtureRoot.appendingPathComponent(name + suffix)
            guard FileManager.default.fileExists(atPath: sidecar.path) else { continue }
            try FileManager.default.copyItem(at: sidecar, to: work.appendingPathComponent(name + suffix))
        }
        return destination
    }

    private enum FixtureReadError: Error { case open(String), query(String) }

    /// The profile row count read straight out of the file — no `ModelContainer`, no migration.
    ///
    /// ⚠️ THE BASELINE COMES FROM THE FIXTURE, NEVER FROM A NUMBER TYPED HERE. The two live-store
    /// assertions below used to read `XCTAssertEqual(counts.profiles, 9)` — a snapshot of one
    /// developer's database taken on the day it was written. `DevgenticSD.store` is that
    /// developer's REAL store: it changes whenever they add or remove a profile, so the gate went
    /// red for reasons with nothing to do with migration (it was red on the day this replaced it,
    /// because an unrelated defect had minted two duplicate profiles) and correcting the literal
    /// would only have re-armed it for the next profile — or, as it happened, for the fix that
    /// removed the duplicates again.
    ///
    /// Reading the count from the same copy the container is about to open keeps the invariant that
    /// was always the point — MIGRATION LOSES NOTHING — and drops the one that was never true.
    /// It also makes the gate meaningful on a machine other than this one.
    private func rawProfileRowCount(_ url: URL) throws -> Int {
        var db: OpaquePointer?
        defer { sqlite3_close(db) }
        // ⚠️ READWRITE, on purpose. `url` is this test's private copy in its own temp directory, and
        // a WAL-mode database cannot be opened read-only without write access to its shared-memory
        // file. SwiftData is about to open the same copy read-write anyway. The fixture itself is
        // never opened — see `stagedCopy` and `fixtureRoot`.
        guard sqlite3_open_v2(url.path, &db, SQLITE_OPEN_READWRITE, nil) == SQLITE_OK else {
            throw FixtureReadError.open(String(cString: sqlite3_errmsg(db)))
        }
        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }
        guard sqlite3_prepare_v2(db, "SELECT COUNT(*) FROM ZBACKENDPROFILE", -1, &statement, nil) == SQLITE_OK,
              sqlite3_step(statement) == SQLITE_ROW else {
            throw FixtureReadError.query(String(cString: sqlite3_errmsg(db)))
        }
        return Int(sqlite3_column_int64(statement, 0))
    }

    /// Opens a store and proves its CONTENT survived, not merely that the file opened.
    ///
    /// ⚠️ Row counts alone are not enough and would have made this whole gate shallow. A profile's
    /// configuration is a JSON blob the schema knows nothing about, so a migration can leave the row
    /// count perfect while every blob decodes to the `.bot` placeholder that
    /// `configurationUnreadableReason` reports — the same silent degradation the sweep guards
    /// against. Decoding every profile is what makes "migrated" mean something here.
    @discardableResult
    private func openAndRead(_ url: URL, plan: any SchemaMigrationPlan.Type) throws -> (profiles: Int, skills: Int, unreadable: [String]) {
        let container = try ModelContainer(
            for: DevgenticSchema.schema,
            migrationPlan: plan,
            configurations: ModelConfiguration(DevgenticSchema.configurationName,
                                               schema: DevgenticSchema.schema, url: url))
        let context = ModelContext(container)
        let profiles = try context.fetch(FetchDescriptor<BackendProfile>())
        let unreadable = profiles
            .filter { $0.configurationUnreadableReason != nil }
            .map(\.displayName)
        // Touch each profile's details so a decode failure surfaces here rather than at first use.
        for profile in profiles { _ = profile.details }
        let skills = try context.fetch(FetchDescriptor<SkillSD>()).count
        return (profiles.count, skills, unreadable)
    }

    // MARK: - The gate

    /// ⚠️⚠️ THE QUESTION THE COLLAPSE TURNED ON, and the control for the other two. Removing a
    /// version from `schemas` is the documented route to `NSCocoaErrorDomain 134504 "Cannot use
    /// staged migration with an unknown model version"` — so a store already stamped at V6 must
    /// keep opening under a plan that no longer carries the intermediates. If this fails, the
    /// fixture or the harness is wrong and the other two prove nothing.
    ///
    /// ⚠️ This absorbed `testTheLiveV6StoreStillOpensAfterV4AndV5AreRemoved`, which asked exactly
    /// that question against a hypothetical collapsed plan. The collapse SHIPPED on 2026-09-15:
    /// `DevgenticMigrationPlan` is that plan now and `DevgenticSchemaV4`/`V5` no longer exist as
    /// types, so there was no second plan left to contrast with and the two tests had become the
    /// same call on the same fixture with the same assertions. Do not re-split them — restoring the
    /// contrast would mean resurrecting the deleted versions, which is the thing the collapse was
    /// for.
    func testTheLiveV6StoreOpensUnderTheCurrentPlan() throws {
        let store = try stagedCopy(of: "DevgenticSD.store")
        let onDisk = try rawProfileRowCount(store)
        XCTAssertGreaterThan(onDisk, 0, "an empty fixture would make the decode assertion below vacuous")

        let counts = try openAndRead(store, plan: DevgenticMigrationPlan.self)

        XCTAssertEqual(counts.profiles, onDisk,
                       "a store already at V6 must survive the intermediates being deleted, with every row")
        XCTAssertEqual(counts.unreadable, [], "every profile blob must still decode")
    }

    /// The real upgrade path a released user takes: a pre-skills store straight to V6, with no V4 or
    /// V5 to step through and no `.custom` hook anywhere in the chain.
    func testAPreSkillsStoreMigratesStraightToV6UnderTheCollapsedPlan() throws {
        let store = try stagedCopy(of: "DevgenticSD.store.pre-schemaV3-backup")
        let counts = try openAndRead(store, plan: DevgenticMigrationPlan.self)
        XCTAssertEqual(counts.profiles, 9, "the user's profiles must survive a direct V3→V6 migration")
        XCTAssertEqual(counts.unreadable, [], "and their configurations must still decode")
        XCTAssertEqual(counts.skills, 0, "a pre-skills store has no library rows to find")
    }

    /// ⚠️ THE HARNESS MUST BE ABLE TO FAIL. Probed: a plan missing a version the store is actually
    /// stamped at throws `loadIssueModelContainer`. Without this, every result above would be
    /// consistent with a harness that opens anything — and `preV3.store` being stamped at V3 (rather
    /// than V1 or V2) is precisely what makes keeping V3 in the collapsed plan load-bearing.
    func testAPlanMissingTheStoresOwnVersionIsRejected() throws {
        let store = try stagedCopy(of: "DevgenticSD.store.pre-schemaV3-backup")
        XCTAssertThrowsError(try openAndRead(store, plan: PlanMissingV3UnderTest.self),
                             "if this opens, the gate above proves nothing")
    }
}
