// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
//
//  OrbConfigTests.swift
//  DevgenticTests
//
//  The Orb settings layer. Covers the two shapes the design review argued hardest for —
//  hold-to-talk as the DEFAULT, and endpointing as named steps whose floor is real — plus the
//  corrupt-defaults hardening that the QuickAccess config manager learned the hard way.
//
//  These touch UserDefaults.standard because that IS the backing store under test; every suite
//  snapshots and restores the exact keys it writes.
//

import XCTest
@testable import devgentic

// MARK: - Pure enum semantics

@MainActor
final class OrbActivationModeTests: XCTestCase {

    func testOnlyHoldShortcutKeepsTheMicrophoneClosedAtRest() {
        // This is the property the whole default rests on: the other two modes run a speech
        // model against the room for as long as the orb is open.
        XCTAssertFalse(OrbActivationMode.holdShortcut.listensContinuously)
        XCTAssertTrue(OrbActivationMode.wakeWord.listensContinuously)
        XCTAssertTrue(OrbActivationMode.clickOrb.listensContinuously)
    }

    func testEveryModeIsSelectableAndIdentifiable() {
        XCTAssertEqual(OrbActivationMode.allCases.count, 3)
        XCTAssertEqual(Set(OrbActivationMode.allCases.map(\.id)).count, 3)
    }
}

@MainActor
final class OrbEndpointingTests: XCTestCase {

    func testStepsAreOrderedAndDistinct() {
        XCTAssertLessThan(OrbEndpointing.quick.seconds, OrbEndpointing.normal.seconds)
        XCTAssertLessThan(OrbEndpointing.normal.seconds, OrbEndpointing.relaxed.seconds)
    }

    func testNoStepFallsBelowWhisperKitsOwnSilenceFloor() {
        // ⚠️ The load-bearing assertion. The effective end-of-speech is min(our window,
        // WhisperKit's ~1.5s VAD auto-stop), so any step below 1.5s would be silently inert —
        // a control the user can move that visibly does nothing. If someone lowers `quick`,
        // this fails and tells them why.
        let whisperKitSilenceFloor: TimeInterval = 1.5
        for step in OrbEndpointing.allCases {
            XCTAssertGreaterThanOrEqual(step.seconds, whisperKitSilenceFloor,
                                        "\(step.rawValue) would be preempted by WhisperKit's own VAD and do nothing")
        }
    }

    func testNormalPreservesThePreSettingsBehaviour() {
        // 2.2s was the hardcoded `commandSilenceCommit`. The default must not change what
        // existing users already feel.
        XCTAssertEqual(OrbEndpointing.normal.seconds, 2.2, accuracy: 0.001)
    }
}

// MARK: - Config manager

@MainActor
final class OrbConfigManagerTests: XCTestCase {

    private let keys = [
        AppSettings.orbEnabledKey, AppSettings.orbActivationModeKey,
        AppSettings.orbShortcutCodeKey, AppSettings.orbShortcutModifiersKey,
        AppSettings.orbEndpointingKey, AppSettings.orbNarratorVoiceKey,
        AppSettings.orbNarratorRateKey, AppSettings.orbProfileIDKey,
        OrbPanelController.originXKey, OrbPanelController.originYKey,
    ]
    private var saved: [String: Any] = [:]

    override func setUp() {
        super.setUp()
        saved = [:]
        for key in keys {
            if let value = UserDefaults.standard.object(forKey: key) { saved[key] = value }
            UserDefaults.standard.removeObject(forKey: key)
        }
    }

    override func tearDown() {
        for key in keys { UserDefaults.standard.removeObject(forKey: key) }
        for (key, value) in saved { UserDefaults.standard.set(value, forKey: key) }
        super.tearDown()
    }

    // MARK: Defaults

    func testDefaultActivationIsHoldShortcutNotWakeWord() {
        // The agreed product decision: always-on standby is an opt-in, not the default, because
        // it runs a speech model against the room for as long as the orb is open.
        XCTAssertEqual(OrbConfigManager.shared.activationMode, .holdShortcut)
    }

    func testDefaultsPreserveExistingBehaviourEverywhereElse() {
        let config = OrbConfigManager.shared
        XCTAssertTrue(config.isEnabled)
        XCTAssertEqual(config.endpointing, .normal)
        XCTAssertTrue(config.usesReadAloudVoice, "an unset voice must follow the chat Read Aloud voice, as it did before this pane existed")
        XCTAssertEqual(config.narratorRate, 0, "0 is the sentinel for 'same rate as Read Aloud'")
        XCTAssertNil(config.profileID)
    }

    func testUnsetBooleanDefaultsToTrueRatherThanFalse() {
        // `defaults.bool(forKey:)` cannot distinguish unset from false, which is why the manager
        // uses `object(forKey:) as? Bool ?? true`. Pin it: a fresh install must have Orb on.
        XCTAssertNil(UserDefaults.standard.object(forKey: AppSettings.orbEnabledKey))
        XCTAssertTrue(OrbConfigManager.shared.isEnabled)
    }

    // MARK: Round-trips

    func testActivationModeRoundTrips() {
        OrbConfigManager.shared.activationMode = .wakeWord
        XCTAssertEqual(OrbConfigManager.shared.activationMode, .wakeWord)
    }

    func testEndpointingRoundTrips() {
        OrbConfigManager.shared.endpointing = .relaxed
        XCTAssertEqual(OrbConfigManager.shared.endpointing, .relaxed)
    }

    func testChoosingAVoiceBreaksTheReadAloudCoupling() {
        OrbConfigManager.shared.narratorVoiceID = "com.apple.voice.example"
        XCTAssertFalse(OrbConfigManager.shared.usesReadAloudVoice)
        OrbConfigManager.shared.narratorVoiceID = ""
        XCTAssertTrue(OrbConfigManager.shared.usesReadAloudVoice)
    }

    // MARK: Corrupt / externally-written defaults

    func testCorruptShortcutDefaultFallsBackInsteadOfTrapping() {
        // `defaults write … -1` must not crash-loop the app: this is read at launch and there is
        // no in-app recovery. The manager uses UInt32(exactly:) plus a fallback.
        UserDefaults.standard.set(-1, forKey: AppSettings.orbShortcutCodeKey)
        UserDefaults.standard.set(Int(UInt32.max) + 5, forKey: AppSettings.orbShortcutModifiersKey)
        XCTAssertEqual(OrbConfigManager.shared.carbonKeyCode, OrbConfigManager.defaultCombo.carbonKeyCode)
        XCTAssertEqual(OrbConfigManager.shared.carbonModifiers, OrbConfigManager.defaultCombo.carbonModifiers)
    }

    func testUnknownStoredEnumValuesFallBackToDefaults() {
        UserDefaults.standard.set("teleportation", forKey: AppSettings.orbActivationModeKey)
        UserDefaults.standard.set("instant", forKey: AppSettings.orbEndpointingKey)
        XCTAssertEqual(OrbConfigManager.shared.activationMode, .holdShortcut)
        XCTAssertEqual(OrbConfigManager.shared.endpointing, .normal)
    }

    func testNarratorRateIsClampedToASpeakableRange() {
        UserDefaults.standard.set(Float(99), forKey: AppSettings.orbNarratorRateKey)
        XCTAssertEqual(OrbConfigManager.shared.narratorRate, 2.0, accuracy: 0.001)
        UserDefaults.standard.set(Float(0.01), forKey: AppSettings.orbNarratorRateKey)
        XCTAssertEqual(OrbConfigManager.shared.narratorRate, 0.5, accuracy: 0.001)
        UserDefaults.standard.set(Float(-3), forKey: AppSettings.orbNarratorRateKey)
        XCTAssertEqual(OrbConfigManager.shared.narratorRate, 0, "a negative rate must read as the sentinel, never as speech")
    }

    // MARK: Reset

    func testResetAlsoClearsTheStrandedPanelPosition() {
        // The reason Reset is user-facing at all: the panel is borderless with no titlebar, so a
        // position saved from a since-disconnected display cannot be dragged back.
        OrbConfigManager.shared.activationMode = .wakeWord
        UserDefaults.standard.set(9999.0, forKey: OrbPanelController.originXKey)
        UserDefaults.standard.set(9999.0, forKey: OrbPanelController.originYKey)

        OrbConfigManager.shared.resetAll()

        XCTAssertEqual(OrbConfigManager.shared.activationMode, .holdShortcut)
        XCTAssertNil(UserDefaults.standard.object(forKey: OrbPanelController.originXKey))
        XCTAssertNil(UserDefaults.standard.object(forKey: OrbPanelController.originYKey))
    }
}

// MARK: - Experimental paths must default to the proven one

@MainActor
final class OrbExperimentalDefaultsTests: XCTestCase {

    /// ⚠️ Both of these ship untested against real audio hardware, and both fail in ways that look
    /// like nothing: a duplex engine that opens and hears silence, and an Apple-Speech session that
    /// transcribes zero results because a hand-rolled format conversion was wrong. A default that
    /// drifted to the experimental path would hand every user a silently broken microphone.
    func testDuplexAudioDefaultsOff() {
        let saved = UserDefaults.standard.object(forKey: AppSettings.orbDuplexAudioKey)
        UserDefaults.standard.removeObject(forKey: AppSettings.orbDuplexAudioKey)
        defer { if let saved { UserDefaults.standard.set(saved, forKey: AppSettings.orbDuplexAudioKey) } }
        XCTAssertFalse(OrbConfigManager.shared.duplexAudioEnabled)
    }

    func testSpeechLocaleDefaultsToTheSystemAndRoundTrips() {
        // ⚠️ Empty is the sentinel for "follow the system". It matters that this is an EXPLICIT
        // choice: Apple ships one model per locale and `SpeechTranscriber` runs DEGRADED, without
        // erroring, when that model was never installed — which is exactly how the 2026-09-04
        // device test produced "write an SM technology" from "write an essay on technology".
        let saved = UserDefaults.standard.object(forKey: AppSettings.orbSpeechLocaleKey)
        UserDefaults.standard.removeObject(forKey: AppSettings.orbSpeechLocaleKey)
        defer {
            UserDefaults.standard.removeObject(forKey: AppSettings.orbSpeechLocaleKey)
            if let saved { UserDefaults.standard.set(saved, forKey: AppSettings.orbSpeechLocaleKey) }
        }
        XCTAssertEqual(OrbConfigManager.shared.speechLocaleIdentifier, "")
        XCTAssertEqual(OrbConfigManager.shared.speechLocale.identifier, Locale.current.identifier)

        OrbConfigManager.shared.speechLocaleIdentifier = "en_US"
        XCTAssertEqual(OrbConfigManager.shared.speechLocale.identifier, "en_US")
    }

    func testRecognizerDefaultsToTheDeviceProvenOne() {
        let saved = UserDefaults.standard.object(forKey: AppSettings.orbRecognizerKey)
        UserDefaults.standard.removeObject(forKey: AppSettings.orbRecognizerKey)
        defer { if let saved { UserDefaults.standard.set(saved, forKey: AppSettings.orbRecognizerKey) } }
        XCTAssertEqual(OrbConfigManager.shared.recognizer, .whisperKit)
        XCTAssertFalse(OrbConfigManager.shared.recognizer.isAppleSpeech)
    }

    func testAnUnknownStoredRecognizerFallsBackToWhisperKit() {
        let saved = UserDefaults.standard.object(forKey: AppSettings.orbRecognizerKey)
        UserDefaults.standard.set("nextGenThing", forKey: AppSettings.orbRecognizerKey)
        defer {
            UserDefaults.standard.removeObject(forKey: AppSettings.orbRecognizerKey)
            if let saved { UserDefaults.standard.set(saved, forKey: AppSettings.orbRecognizerKey) }
        }
        XCTAssertEqual(OrbConfigManager.shared.recognizer, .whisperKit)
    }
}

// MARK: - Diagnostic bundle export

final class OrbPreferenceExportTests: XCTestCase {

    func testOrbSettingsReachDiagnosticBundles() {
        // The reason the deletability contract was retired: a voice bug report is undebuggable
        // without knowing how the user had activation and endpointing configured.
        let allowlist = Set(BundleExporter.exportablePreferenceKeys)
        for key in [AppSettings.orbEnabledKey, AppSettings.orbActivationModeKey,
                    AppSettings.orbEndpointingKey, AppSettings.orbNarratorVoiceKey,
                    AppSettings.orbNarratorRateKey] {
            XCTAssertTrue(allowlist.contains(key), "\(key) should be exportable")
        }
    }

    func testTheShortcutItselfIsNotExported() {
        // Not secret, but it carries no diagnostic value and its key names would trip the
        // allowlist's secret-shaped-name guard. Documented here so nobody "fixes" the omission.
        let allowlist = Set(BundleExporter.exportablePreferenceKeys)
        XCTAssertFalse(allowlist.contains(AppSettings.orbShortcutCodeKey))
        XCTAssertFalse(allowlist.contains(AppSettings.orbProfileIDKey))
    }
}
