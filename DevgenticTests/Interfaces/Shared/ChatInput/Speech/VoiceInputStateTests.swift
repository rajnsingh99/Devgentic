// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
//
//  VoiceInputStateTests.swift
//  DevgenticTests
//
//  Created by Raj Singh.
//

import XCTest
@testable import devgentic

final class VoiceInputStateTests: XCTestCase {

    // MARK: - isSessionActive

    func testActiveStates() {
        let activeStates: [VoiceInputState] = [
            .recording, .processing, .modelLoading, .modelPreparing, .finalizingSilence
        ]
        for state in activeStates {
            XCTAssertTrue(state.isSessionActive, "\(state.description) should be session-active")
        }
    }

    func testInactiveStates() {
        let inactiveStates: [VoiceInputState] = [
            .idle, .requestingPermissions, .permissionsDeniedMic, .available, .error("test")
        ]
        for state in inactiveStates {
            XCTAssertFalse(state.isSessionActive, "\(state.description) should NOT be session-active")
        }
    }

    // MARK: - isErrorState

    func testErrorStateIsTrue() {
        let state = VoiceInputState.error("something failed")
        XCTAssertTrue(state.isErrorState)
    }

    func testNonErrorStatesAreFalse() {
        let states: [VoiceInputState] = [
            .idle, .requestingPermissions, .permissionsDeniedMic, .available,
            .recording, .processing, .modelLoading, .modelPreparing, .finalizingSilence
        ]
        for state in states {
            XCTAssertFalse(state.isErrorState, "\(state.description) should not be an error state")
        }
    }

    // MARK: - needsModelSelection

    func testIdleNeedsModelSelection() {
        XCTAssertTrue(VoiceInputState.idle.needsModelSelection)
    }

    func testErrorNeedsModelSelection() {
        XCTAssertTrue(VoiceInputState.error("load failed").needsModelSelection)
    }

    func testAvailableDoesNotNeedModelSelection() {
        XCTAssertFalse(VoiceInputState.available.needsModelSelection)
    }

    func testRecordingDoesNotNeedModelSelection() {
        XCTAssertFalse(VoiceInputState.recording.needsModelSelection)
    }

    // MARK: - description

    func testDescriptionForAllStates() {
        XCTAssertEqual(VoiceInputState.idle.description, "idle")
        XCTAssertEqual(VoiceInputState.recording.description, "recording")
        XCTAssertEqual(VoiceInputState.processing.description, "processing")
        XCTAssertEqual(VoiceInputState.available.description, "available")
        XCTAssertEqual(VoiceInputState.modelLoading.description, "modelLoading")
        XCTAssertEqual(VoiceInputState.modelPreparing.description, "modelPreparing")
        XCTAssertEqual(VoiceInputState.finalizingSilence.description, "finalizingSilence")
        XCTAssertEqual(VoiceInputState.requestingPermissions.description, "requestingPermissions")
        XCTAssertEqual(VoiceInputState.permissionsDeniedMic.description, "permissionsDeniedMic")
    }

    func testErrorDescriptionTruncatesLongMessages() {
        let longMessage = String(repeating: "x", count: 100)
        let description = VoiceInputState.error(longMessage).description
        XCTAssertTrue(description.hasPrefix("error("))
        // .prefix(30) truncates the message
        XCTAssertTrue(description.count < 50, "Description should truncate the error message")
    }

    // MARK: - Equatable

    func testEquatable() {
        XCTAssertEqual(VoiceInputState.idle, VoiceInputState.idle)
        XCTAssertEqual(VoiceInputState.error("a"), VoiceInputState.error("a"))
        XCTAssertNotEqual(VoiceInputState.error("a"), VoiceInputState.error("b"))
        XCTAssertNotEqual(VoiceInputState.idle, VoiceInputState.available)
    }
}
