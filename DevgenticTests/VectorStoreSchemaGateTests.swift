// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
//
//  VectorStoreSchemaGateTests.swift
//  DevgenticTests
//
//  Created by Raj Singh.
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

    /// RAG-31: a downgrade must leave a NEWER build's store alone. Quarantining it ("just as
    /// unreadable as an old one") parked it in the single `-superseded` slot, and the upgrade back
    /// then quarantined the empty v1 store over it — losing the original permanently.
    func testNewerMarkedSchema_IsLeftUntouched() {
        XCTAssertEqual(
            VectorStoreService.schemaGateAction(markerVersion: current + 1, databaseExists: true),
            .leaveNewerUntouched
        )
        XCTAssertEqual(
            VectorStoreService.schemaGateAction(markerVersion: current + 7, databaseExists: false),
            .leaveNewerUntouched,
            "a newer marker is never re-stamped down, even with no data beside it"
        )
    }
}
