// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
//
//  TestIsolationObserver.swift
//  DevgenticTests
//
//  The test bundle's principal class (`NSPrincipalClass`, set by `INFOPLIST_KEY_NSPrincipalClass`):
//  XCTest creates one instance when the bundle loads, before any test runs.
//
//  ⚠️ For process-wide state that NO test class can isolate on its own, because the leak crosses
//  classes: a test's setUp cannot clean up after a class that ran earlier and never knew it needed
//  to. Add a reset here only for state of that kind — everything else belongs in the owning test's
//  setUp/tearDown.
//

import XCTest
@testable import devgentic

final class TestIsolationObserver: NSObject, XCTestObservation {

    override init() {
        super.init()
        XCTestObservationCenter.shared.addTestObserver(self)
    }

    func testCaseWillStart(_ testCase: XCTestCase) {
        // One key per provider: a test that stores an "anthropic" key would otherwise hand it to
        // every later test that creates an Anthropic profile.
        GlobalProviderKeys.resetForTestIsolation()
        // The per-profile key cache is process-wide too, and Code mode's provider slots use FIXED
        // ids, so one test's slot answer would otherwise reach the next.
        ProviderKeyStore.discardCache()
    }
}
