// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
//
//  OrbSettingsConsistencyTests.swift
//  DevgenticTests
//
//  Created by Raj Singh.
//

import XCTest
@testable import devgentic

@MainActor
final class OrbFollowUpPromiseTests: XCTestCase {

    /// ⚠️ #68 — THE PRODUCT PROMISE. The activation row sells hold-to-talk as "keeps the
    /// microphone closed until you press it", and it is the default on a laptop. A follow-up
    /// window opens the microphone for seconds after EVERY answer with nothing held down.
    /// Two defaults that were each defensible alone combined into a claim the app did not honour.
    func testHoldToTalkNeverOpensAFollowUpWindow() {
        for followUp in OrbFollowUp.allCases {
            XCTAssertNil(
                OrbSessionController.followUpSeconds(activationMode: .holdShortcut, followUp: followUp),
                "Hold-to-talk must keep the microphone closed — \(followUp) must not open a window."
            )
        }
    }

    /// The listening modes already hold the microphone, so a follow-up window costs nothing there
    /// and is the whole point of the feature.
    func testListeningModesStillHonourTheFollowUpSetting() {
        for mode in OrbActivationMode.allCases where mode.listensContinuously {
            for followUp in OrbFollowUp.allCases {
                XCTAssertEqual(
                    OrbSessionController.followUpSeconds(activationMode: mode, followUp: followUp),
                    followUp.seconds,
                    "\(mode) should pass the follow-up setting through unchanged."
                )
            }
        }
    }

    /// "Off" must mean off in every mode — the guard above must not accidentally resurrect it.
    func testFollowUpOffIsAlwaysOff() {
        for mode in OrbActivationMode.allCases {
            let off = OrbFollowUp.allCases.first { $0.seconds == nil }
            guard let off else { return XCTFail("No 'off' case in OrbFollowUp — the setting cannot be disabled.") }
            XCTAssertNil(OrbSessionController.followUpSeconds(activationMode: mode, followUp: off))
        }
    }
}
