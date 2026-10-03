// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
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

    func testCurrentMarker_OpensAsIs() {
        XCTAssertEqual(
            VectorStoreService.schemaGateAction(markerVersion: current, databaseExists: true),
            .openAsIs
        )
    }

    func testFreshInstall_StampsWithoutWiping() {
        XCTAssertEqual(
            VectorStoreService.schemaGateAction(markerVersion: nil, databaseExists: false),
            .stampOnly
        )
    }

    func testUnmarkedDatabase_Wipes() {
        // No marker means a schema of unknown age; nothing upgrades it.
        XCTAssertEqual(
            VectorStoreService.schemaGateAction(markerVersion: nil, databaseExists: true),
            .wipeAndStamp
        )
    }

    func testOlderMarkedSchema_Wipes() {
        XCTAssertEqual(
            VectorStoreService.schemaGateAction(markerVersion: current - 1, databaseExists: true),
            .wipeAndStamp
        )
    }

    func testNewerMarkedSchema_Wipes() {
        // Downgrade: a future build's schema is just as unreadable as an old one.
        XCTAssertEqual(
            VectorStoreService.schemaGateAction(markerVersion: current + 1, databaseExists: true),
            .wipeAndStamp
        )
    }
}
