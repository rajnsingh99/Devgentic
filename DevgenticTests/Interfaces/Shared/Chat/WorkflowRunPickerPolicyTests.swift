// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
//
//  WorkflowRunPickerPolicyTests.swift
//  DevgenticTests
//
//  Register XUI-3 — the run picker's state words and badge precedence, as pure statics on
//  `WorkflowDedicatedView` (the `finalOutcomeTagLabel` shape). The wiring half — that the
//  "Live Run" button assigns `executionState?.runRecordID` instead of nil — is a @State write
//  inside a Menu closure and is NOT reachable from a unit test; these pin the decisions the
//  wiring consumes.
//

import XCTest
@testable import devgentic

final class WorkflowRunPickerPolicyTests: XCTestCase {

    // MARK: - Badge precedence

    /// ⚠️ THE XUI-3 BADGE PIN. The live run's `.running` stub is in `runHistory`, so the position
    /// ALWAYS resolves during a live run — a position-first check made the "Live" badge dead code
    /// and dressed the live run as "1/N".
    func testLiveOutranksPosition() {
        XCTAssertEqual(WorkflowDedicatedView.runBadge(isLive: true, position: (index: 1, total: 4)), .live)
    }

    func testHistoricalSelectionShowsItsPosition() {
        XCTAssertEqual(WorkflowDedicatedView.runBadge(isLive: false, position: (index: 2, total: 4)),
                       .position(index: 2, total: 4))
    }

    func testLiveWithNoHistoryPositionIsStillLive() {
        XCTAssertEqual(WorkflowDedicatedView.runBadge(isLive: true, position: nil), .live)
    }

    func testNoSelectionShowsNothing() {
        XCTAssertEqual(WorkflowDedicatedView.runBadge(isLive: false, position: nil), .none)
    }

    // MARK: - "Live Run" item visibility

    /// The item exists to JUMP BACK to an in-flight run. It used to render whenever any selection
    /// existed — including with nothing running, where pressing it dumped the user into the
    /// history list under a label promising a live run.
    func testItemShowsOnlyWhileAwayFromALiveRun() {
        XCTAssertTrue(WorkflowDedicatedView.showsLiveRunItem(liveRunInFlight: true, viewingLive: false))
        XCTAssertFalse(WorkflowDedicatedView.showsLiveRunItem(liveRunInFlight: true, viewingLive: true),
                       "already on screen — the item is noise")
        XCTAssertFalse(WorkflowDedicatedView.showsLiveRunItem(liveRunInFlight: false, viewingLive: false),
                       "nothing is running — a 'Live Run' item is a lie")
        XCTAssertFalse(WorkflowDedicatedView.showsLiveRunItem(liveRunInFlight: false, viewingLive: true))
    }
}
