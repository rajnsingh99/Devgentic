// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
//
//  OrbEntryPointTests.swift
//  DevgenticTests
//
//  Created by Raj Singh.
//

import XCTest
@testable import devgentic

@MainActor
final class OrbEntryPointTests: XCTestCase {

    private var savedEarcons: String?

    override func setUp() async throws {
        try await super.setUp()
        savedEarcons = TestHost.defaults.string(forKey: AppSettings.orbEarconsKey)
        OrbConfigManager.shared.earcons = .off
    }

    override func tearDown() async throws {
        if let savedEarcons {
            TestHost.defaults.set(savedEarcons, forKey: AppSettings.orbEarconsKey)
        } else {
            TestHost.defaults.removeObject(forKey: AppSettings.orbEarconsKey)
        }
        try await super.tearDown()
    }

    private func stage(_ controller: OrbSessionController) -> String {
        OrbSessionController.name(of: controller.stage)
    }

    /// `retryVoice()` is the cheapest way into `.passiveListening`: it sets the stage synchronously
    /// and its warm is refused immediately in hold-to-talk, the default mode.
    private func listeningController() -> OrbSessionController {
        let controller = OrbSessionController()
        controller.retryVoice()
        return controller
    }

    // MARK: - Click to speak

    /// ⚠️ THE SAFETY NET FOR A WAKE WORD WHISPER NEVER RENDERS. If this stops arming, the orb
    /// offers a hot-mic appearance and captures nothing — the same shape as the push-to-talk P1.
    func testClickingTheOrbArmsCapture() {
        let controller = listeningController()
        XCTAssertEqual(stage(controller), "passiveListening")

        controller.armManualCapture()

        XCTAssertEqual(stage(controller), "commandCapture",
                       "A click must arm capture; without it the orb looks live and hears nothing.")
        controller.teardown()
    }

    /// It must only arm from standby — arming on top of a run would capture over it.
    func testClickingDoesNothingOutsideStandby() {
        let controller = OrbSessionController()   // starts at the profile picker
        controller.armManualCapture()
        XCTAssertEqual(stage(controller), "selectingProfile",
                       "There is no profile chosen yet, so there is nothing to capture into.")
        controller.teardown()
    }

    // MARK: - Cancelling

    /// ⚠️ THE ABORT PATH. A tap on the orb SENDS, so this is the only way to stop a
    /// mis-transcription reaching a profile with shell and filesystem tools.
    func testCancellingAnArmedCaptureReturnsToStandby() {
        let controller = listeningController()
        controller.armManualCapture()
        XCTAssertEqual(stage(controller), "commandCapture")

        controller.cancelCapture()

        XCTAssertEqual(stage(controller), "passiveListening",
                       "Cancel must discard the capture and re-arm, not leave the orb hot.")
        controller.teardown()
    }

    func testCancellingWhenNothingIsArmedIsHarmless() {
        let controller = listeningController()
        controller.cancelCapture()
        XCTAssertEqual(stage(controller), "passiveListening")
        controller.teardown()
    }

    // MARK: - Committing

    /// `commitCaptureNow` requires a live session — with none open it must do nothing rather than
    /// dispatch an empty command.
    func testCommittingWithNoLiveSessionSendsNothing() {
        let controller = listeningController()
        controller.armManualCapture()

        controller.commitCaptureNow()

        XCTAssertEqual(stage(controller), "commandCapture",
                       "With no microphone session open there is nothing to commit; the stage must not advance.")
        XCTAssertFalse(controller.isExecuting)
        controller.teardown()
    }

    // MARK: - Barge-in

    /// Interrupting is only meaningful while Orb is speaking; from anywhere else it must be a
    /// no-op rather than yanking the stage machine sideways.
    func testBargeInDoesNothingOutsideAnAnswer() {
        let controller = listeningController()
        controller.armManualCapture()
        XCTAssertEqual(stage(controller), "commandCapture")

        controller.bargeIn()

        XCTAssertEqual(stage(controller), "commandCapture",
                       "Barge-in outside .announcing must not cancel an armed capture.")
        controller.teardown()
    }

    // MARK: - Teardown

    /// ⚠️ Teardown must be safe from every stage, because the panel can be closed at any moment —
    /// and it is the primary release path for an audio engine that wedges `coreaudiod` if it
    /// outlives the process.
    func testTeardownIsSafeFromEveryReachableStage() {
        for arm in [false, true] {
            let controller = listeningController()
            if arm { controller.armManualCapture() }
            controller.teardown()
            XCTAssertFalse(controller.isExecuting)
        }
    }

    /// After teardown the entry points must refuse — a dismissed controller acting on a click
    /// would open a microphone for a panel that is gone.
    func testEntryPointsRefuseAfterTeardown() {
        let controller = listeningController()
        controller.teardown()

        controller.armManualCapture()
        controller.beginPushToTalk()

        XCTAssertNotEqual(stage(controller), "commandCapture",
                          "A torn-down controller must not arm capture.")
    }
}
