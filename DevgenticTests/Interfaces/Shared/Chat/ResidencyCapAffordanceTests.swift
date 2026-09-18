// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
//
//  ResidencyCapAffordanceTests.swift
//  DevgenticTests
//
//  Register CF-36 — what the top-of-transcript pagination slot shows, as a pure static on
//  `ChatHistoryView` (the WF-UI5 shape). The pill used to render on `canLoadMorePages`
//  alone, which deliberately stays TRUE at the residency cap, so at the cap it stayed
//  enabled and inert under a tooltip promising auto-load. The rendering half (button vs
//  caption) is a ViewBuilder switch and is not reachable from a unit test; these pin the
//  decision it consumes.
//

import XCTest
@testable import devgentic

final class ResidencyCapAffordanceTests: XCTestCase {

    /// ⚠️ THE CF-36 PIN. `canLoadMore` is TRUE at the cap by design (the store has more; the
    /// history resolver depends on the distinction) — the cap must still win over the button.
    func testAtTheCapTheSlotIsANoticeNotAButton() {
        XCTAssertEqual(ChatHistoryView.loadEarlierAffordance(canLoadMore: true, atCap: true, isLoading: false),
                       .capNotice)
    }

    /// Unreachable in practice (`loadMoreMessages` returns before it sets `isLoadingPage` once
    /// capped), but if the two ever coincide the cap is the state the user can act on.
    func testCapOutranksLoading() {
        XCTAssertEqual(ChatHistoryView.loadEarlierAffordance(canLoadMore: true, atCap: true, isLoading: true),
                       .capNotice)
    }

    func testBelowTheCapTheButtonRendersIdle() {
        XCTAssertEqual(ChatHistoryView.loadEarlierAffordance(canLoadMore: true, atCap: false, isLoading: false),
                       .button(loading: false))
    }

    func testBelowTheCapTheButtonShowsItsSpinner() {
        XCTAssertEqual(ChatHistoryView.loadEarlierAffordance(canLoadMore: true, atCap: false, isLoading: true),
                       .button(loading: true))
    }

    /// History exhausted: nothing to load and nothing to explain, whatever the other flags say.
    func testExhaustedHistoryHidesTheSlot() {
        for atCap in [false, true] {
            for isLoading in [false, true] {
                XCTAssertEqual(ChatHistoryView.loadEarlierAffordance(canLoadMore: false, atCap: atCap, isLoading: isLoading),
                               .hidden, "atCap=\(atCap) isLoading=\(isLoading)")
            }
        }
    }
}
