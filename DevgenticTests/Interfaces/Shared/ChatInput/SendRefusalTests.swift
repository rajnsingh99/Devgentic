// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2026 Raj Singh
//
//  SendRefusalTests.swift
//  DevgenticTests
//
//  Created on 07/08/26.
//
//  Register A32 — the send BUTTON did nothing visible when the selected profile had been deleted,
//  while ENTER opened the backend picker for the identical condition.
//
//  The two entry points implemented the send action separately and drifted; they now share
//  `ChatInputAreaView.attemptSend`. A SwiftUI view method is not directly reachable from a unit
//  test, so what is asserted here is the seam the fix turns on: `resolveRequestConfig()` reporting
//  WHY a send cannot be configured. Before this, all three reasons collapsed into one `nil` and one
//  log line, which is why neither entry point could say anything useful — and why a store failure
//  was indistinguishable from a deletion.
//

import XCTest
@testable import devgentic

@MainActor
final class SendRefusalTests: XCTestCase {

    private func makeConfiguration(selecting id: UUID?) -> BackendConfiguration {
        let configuration = BackendConfiguration()
        configuration.selectedProfileID = id
        return configuration
    }

    // MARK: - The three reasons are distinguishable

    func testNoSelectionIsReportedAsNoProfileSelected() {
        let result = makeConfiguration(selecting: nil).resolveRequestConfig()

        guard case .failure(let reason) = result else {
            return XCTFail("expected a failure when nothing is selected")
        }
        XCTAssertEqual(reason, .noProfileSelected)
    }

    /// ⚠️ The A32 scenario. A selected id the store answers cleanly for — with "not there" — is a
    /// DELETED profile, and the caller has to be able to tell, because this is the one case where
    /// clearing the composer's selection is correct.
    func testASelectedButAbsentProfileIsReportedAsDeleted() {
        let ghost = UUID()
        let result = makeConfiguration(selecting: ghost).resolveRequestConfig()

        guard case .failure(let reason) = result else {
            return XCTFail("expected a failure for a profile that is not in the store")
        }
        XCTAssertEqual(reason, .profileDeleted(ghost),
                       "the id has to travel with the reason — the caller clears that exact selection")
    }

    /// Deletion is permanent, so retrying is pointless and the selection should go. A store fault is
    /// transient, so the selection must be KEPT. Getting this backwards discards a valid choice over
    /// a hiccup, which is what the old `try?` made unavoidable by erasing the difference.
    func testOnlyAStoreFailureIsClassifiedTransient() {
        XCTAssertFalse(BackendConfigUnavailability.noProfileSelected.isTransient)
        XCTAssertFalse(BackendConfigUnavailability.profileDeleted(UUID()).isTransient)
        XCTAssertTrue(BackendConfigUnavailability.storeUnavailable(UUID(), "I/O error").isTransient)
    }

    func testDeletionAndStoreFailureAreNotEqual() {
        let id = UUID()
        XCTAssertNotEqual(BackendConfigUnavailability.profileDeleted(id),
                          BackendConfigUnavailability.storeUnavailable(id, "I/O error"),
                          "these were the same nil before the fix; they must never collapse again")
    }

    // MARK: - The existing optional API is unchanged

    /// Five other callers still use `getRequestConfig()` and only need "config or nothing".
    /// It is now a wrapper, so it has to keep answering exactly as it did.
    func testGetRequestConfigStillReturnsNilForEveryFailureReason() {
        XCTAssertNil(makeConfiguration(selecting: nil).getRequestConfig())
        XCTAssertNil(makeConfiguration(selecting: UUID()).getRequestConfig())
    }

    /// ⚠️ Coverage gap, deliberate: the `.storeUnavailable` arm is not reachable from a test.
    /// `resolveRequestConfig` reads `BackendProfileStore.shared`, which IS container-backed in the
    /// test process, and making it throw means un-configuring a singleton every other suite in this
    /// target depends on. The arm's CLASSIFICATION is covered above; its trigger is not.
    func testStoreUnavailableIsCoveredByClassificationOnly() throws {
        throw XCTSkip("Documents an unreachable arm — see the comment above; not a pending test.")
    }
}
