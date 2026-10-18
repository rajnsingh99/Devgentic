// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
//
//  TestIsolationObserver.swift
//  DevgenticTests
//
//  Created by Raj Singh.
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
