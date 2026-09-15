// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2026 Raj Singh
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
    private func stagedCopy(of name: String) throws -> URL {
        let source = Self.fixtureRoot.appendingPathComponent(name)
        try XCTSkipUnless(FileManager.default.fileExists(atPath: source.path),
                          "fixture \(name) absent — this gate only runs where the copies were made")
        let destination = work.appendingPathComponent(name)
        try FileManager.default.copyItem(at: source, to: destination)
        return destination
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

    /// Control. If this fails, the fixture or the harness is wrong and the other two prove nothing.
    func testTheLiveV6StoreOpensUnderTheCurrentPlan() throws {
        let store = try stagedCopy(of: "DevgenticSD.store")
        let counts = try openAndRead(store, plan: DevgenticMigrationPlan.self)
        XCTAssertEqual(counts.profiles, 9, "the live store holds 9 profiles — pinned so a silent loss is visible")
        XCTAssertEqual(counts.unreadable, [], "every profile blob must still decode")
    }

    /// ⚠️⚠️ THE QUESTION THE COLLAPSE TURNED ON, now a permanent regression guard. Removing a
    /// version from `schemas` is the documented route to `NSCocoaErrorDomain 134504 "Cannot use
    /// staged migration with an unknown model version"`. A store stamped V6 must keep opening.
    func testTheLiveV6StoreStillOpensAfterV4AndV5AreRemoved() throws {
        let store = try stagedCopy(of: "DevgenticSD.store")
        let counts = try openAndRead(store, plan: DevgenticMigrationPlan.self)
        XCTAssertEqual(counts.profiles, 9,
                       "a store already at V6 must survive the intermediates being deleted, with every row")
        XCTAssertEqual(counts.unreadable, [],
                       "and with every configuration blob still decodable")
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
    /// stamped at throws `loadIssueModelContainer`. Without this, all four results above would be
    /// consistent with a harness that opens anything — and `preV3.store` being stamped at V3 (rather
    /// than V1 or V2) is precisely what makes keeping V3 in the collapsed plan load-bearing.
    func testAPlanMissingTheStoresOwnVersionIsRejected() throws {
        let store = try stagedCopy(of: "DevgenticSD.store.pre-schemaV3-backup")
        XCTAssertThrowsError(try openAndRead(store, plan: PlanMissingV3UnderTest.self),
                             "if this opens, the gate above proves nothing")
    }
}
