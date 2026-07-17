//
//  VectorStoreSchemaGateTests.swift
//  devgenticTests
//
//  Created on 12/07/26.
//
//  Covers the schema-gate decision that replaced the UserDefaults-gated wipes:
//  the ONLY path that destroys the store is an on-disk schema that genuinely
//  can't be read. The historical failure this prevents: losing a preferences
//  flag (defaults reset, partial backup restore) silently wiped a healthy,
//  current-schema database — the store now holds every conversation's memory,
//  so that gate had to move into the data directory itself.
//

import XCTest
@testable import devgentic

final class VectorStoreSchemaGateTests: XCTestCase {

    private let current = VectorStoreService.currentSchemaVersion

    func testCurrentMarker_OpensAsIs_RegardlessOfFlags() {
        // The marker is the authority — preferences state is irrelevant once stamped.
        XCTAssertEqual(
            VectorStoreService.schemaGateAction(markerVersion: current, databaseExists: true, legacyPhase3Flag: false),
            .openAsIs,
            "THE fix: a healthy marked database survives losing its preferences flags"
        )
        XCTAssertEqual(
            VectorStoreService.schemaGateAction(markerVersion: current, databaseExists: true, legacyPhase3Flag: true),
            .openAsIs
        )
    }

    func testFreshInstall_StampsWithoutWiping() {
        XCTAssertEqual(
            VectorStoreService.schemaGateAction(markerVersion: nil, databaseExists: false, legacyPhase3Flag: false),
            .stampOnly
        )
    }

    func testLegacyFlaggedUpgrade_StampsWithoutWiping() {
        // Every existing install at rollout: database on the current schema
        // (Phase-3 flag proves its wipe ran), marker not yet written. Must NOT
        // wipe — this is the one-time migration onto the marker.
        XCTAssertEqual(
            VectorStoreService.schemaGateAction(markerVersion: nil, databaseExists: true, legacyPhase3Flag: true),
            .stampOnly
        )
    }

    func testUnmarkedUnflaggedDatabase_Wipes() {
        // Genuinely pre-Phase-3 schema (or unknowable) — the legitimate wipe.
        XCTAssertEqual(
            VectorStoreService.schemaGateAction(markerVersion: nil, databaseExists: true, legacyPhase3Flag: false),
            .wipeAndStamp
        )
    }

    func testOlderMarkedSchema_Wipes() {
        XCTAssertEqual(
            VectorStoreService.schemaGateAction(markerVersion: current - 1, databaseExists: true, legacyPhase3Flag: true),
            .wipeAndStamp,
            "an explicitly older schema rebuilds even when legacy flags linger"
        )
    }

    func testNewerMarkedSchema_Wipes() {
        // Downgrade: a future build's schema is just as unreadable as an old one.
        XCTAssertEqual(
            VectorStoreService.schemaGateAction(markerVersion: current + 1, databaseExists: true, legacyPhase3Flag: true),
            .wipeAndStamp
        )
    }
}
