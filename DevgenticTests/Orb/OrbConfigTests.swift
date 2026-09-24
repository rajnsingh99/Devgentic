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
//  ⚠️⚠️ These now go through `TestHost.defaults`, NOT `TestHost.defaults`. Under a test host
//  `.standard` is the shipping app's own domain: this file cleared, rewrote and restored the
//  developer's real Orb settings on every run, and `OrbWakeWordTests` — which has no such
//  save/restore — read them and failed on the author's machine while passing everywhere else.
//  `TestHost.defaults` is an isolated suite under XCTest and `.standard` in the app, so the
//  manager and these tests still share one backing store; it is simply no longer the user's.
//
//  These touch the defaults store directly because that IS the backing store under test; every suite
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
        AppSettings.orbWakeWordKey,
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
            if let value = TestHost.defaults.object(forKey: key) { saved[key] = value }
            TestHost.defaults.removeObject(forKey: key)
        }
    }

    override func tearDown() {
        for key in keys { TestHost.defaults.removeObject(forKey: key) }
        for (key, value) in saved { TestHost.defaults.set(value, forKey: key) }
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
        XCTAssertNil(TestHost.defaults.object(forKey: AppSettings.orbEnabledKey))
        XCTAssertTrue(OrbConfigManager.shared.isEnabled)
    }

    // MARK: The wake word reaches the matcher

    /// ⚠️⚠️ THE WIRING TEST. Every other wake-word test passes the word explicitly, so all of them
    /// would still pass if `OrbSessionController.wakeWord` went back to being a hardcoded
    /// `static let` — which is exactly what it was until 2026-09-19, and exactly why the setting
    /// could not have existed before. These four go through the NO-ARGUMENT call shape the
    /// controller itself uses, so cutting the wire fails the build.

    func testAConfiguredWakeWordReachesTheMatcherWithNoArgument() {
        OrbConfigManager.shared.wakeWordRaw = "zephyr"
        XCTAssertEqual(OrbSessionController.wakeWord, "zephyr")
        XCTAssertNotNil(OrbSessionController.wakeWordRange(in: "zephyr run the tests"))
        XCTAssertNil(OrbSessionController.wakeWordRange(in: "orb run the tests"),
                     "the shipped default must not still be listening alongside the configured word")
    }

    func testExtractionUsesTheConfiguredWordWithNoArgument() {
        // End to end through the exact call the controller makes on every transcript update.
        OrbConfigManager.shared.wakeWordRaw = "Hey Orb"
        XCTAssertEqual(OrbSessionController.extractCommand(from: "Hey orb, write an essay on technology."),
                       "write an essay on technology")
    }

    func testTheDefaultIsInForceWhenNothingIsStored() {
        XCTAssertNil(TestHost.defaults.object(forKey: AppSettings.orbWakeWordKey))
        XCTAssertEqual(OrbSessionController.wakeWord, OrbConfigManager.defaultWakeWord)
        XCTAssertNotNil(OrbSessionController.wakeWordRange(in: "orb run the tests"))
    }

    func testAnUnusableEntryLeavesAWorkingOrbNotADeafOne() {
        // A half-typed word must never leave the user with an orb that cannot be woken at all.
        OrbConfigManager.shared.wakeWordRaw = "z"
        XCTAssertEqual(OrbSessionController.wakeWord, OrbConfigManager.defaultWakeWord)
        XCTAssertNotNil(OrbSessionController.wakeWordRange(in: "orb run the tests"))
        // ...and the raw text is kept verbatim, so the field does not fight the user mid-word.
        XCTAssertEqual(OrbConfigManager.shared.wakeWordRaw, "z")
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
        TestHost.defaults.set(-1, forKey: AppSettings.orbShortcutCodeKey)
        TestHost.defaults.set(Int(UInt32.max) + 5, forKey: AppSettings.orbShortcutModifiersKey)
        XCTAssertEqual(OrbConfigManager.shared.carbonKeyCode, OrbConfigManager.defaultCombo.carbonKeyCode)
        XCTAssertEqual(OrbConfigManager.shared.carbonModifiers, OrbConfigManager.defaultCombo.carbonModifiers)
    }

    func testUnknownStoredEnumValuesFallBackToDefaults() {
        TestHost.defaults.set("teleportation", forKey: AppSettings.orbActivationModeKey)
        TestHost.defaults.set("instant", forKey: AppSettings.orbEndpointingKey)
        XCTAssertEqual(OrbConfigManager.shared.activationMode, .holdShortcut)
        XCTAssertEqual(OrbConfigManager.shared.endpointing, .normal)
    }

    func testNarratorRateIsClampedToASpeakableRange() {
        TestHost.defaults.set(Float(99), forKey: AppSettings.orbNarratorRateKey)
        XCTAssertEqual(OrbConfigManager.shared.narratorRate, 2.0, accuracy: 0.001)
        TestHost.defaults.set(Float(0.01), forKey: AppSettings.orbNarratorRateKey)
        XCTAssertEqual(OrbConfigManager.shared.narratorRate, 0.5, accuracy: 0.001)
        TestHost.defaults.set(Float(-3), forKey: AppSettings.orbNarratorRateKey)
        XCTAssertEqual(OrbConfigManager.shared.narratorRate, 0, "a negative rate must read as the sentinel, never as speech")
    }

    // MARK: Reset

    func testResetAlsoClearsTheStrandedPanelPosition() {
        // The reason Reset is user-facing at all: the panel is borderless with no titlebar, so a
        // position saved from a since-disconnected display cannot be dragged back.
        OrbConfigManager.shared.activationMode = .wakeWord
        TestHost.defaults.set(9999.0, forKey: OrbPanelController.originXKey)
        TestHost.defaults.set(9999.0, forKey: OrbPanelController.originYKey)

        OrbConfigManager.shared.resetAll()

        XCTAssertEqual(OrbConfigManager.shared.activationMode, .holdShortcut)
        XCTAssertNil(TestHost.defaults.object(forKey: OrbPanelController.originXKey))
        XCTAssertNil(TestHost.defaults.object(forKey: OrbPanelController.originYKey))
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
        let saved = TestHost.defaults.object(forKey: AppSettings.orbDuplexAudioKey)
        TestHost.defaults.removeObject(forKey: AppSettings.orbDuplexAudioKey)
        defer { if let saved { TestHost.defaults.set(saved, forKey: AppSettings.orbDuplexAudioKey) } }
        XCTAssertFalse(OrbConfigManager.shared.duplexAudioEnabled)
    }

    func testSpeechLocaleDefaultsToTheSystemAndRoundTrips() {
        // ⚠️ Empty is the sentinel for "follow the system". It matters that this is an EXPLICIT
        // choice: Apple ships one model per locale and `SpeechTranscriber` runs DEGRADED, without
        // erroring, when that model was never installed — which is exactly how the 2026-09-04
        // device test produced "write an SM technology" from "write an essay on technology".
        let saved = TestHost.defaults.object(forKey: AppSettings.orbSpeechLocaleKey)
        TestHost.defaults.removeObject(forKey: AppSettings.orbSpeechLocaleKey)
        defer {
            TestHost.defaults.removeObject(forKey: AppSettings.orbSpeechLocaleKey)
            if let saved { TestHost.defaults.set(saved, forKey: AppSettings.orbSpeechLocaleKey) }
        }
        XCTAssertEqual(OrbConfigManager.shared.speechLocaleIdentifier, "")
        XCTAssertEqual(OrbConfigManager.shared.speechLocale.identifier, Locale.current.identifier)

        OrbConfigManager.shared.speechLocaleIdentifier = "en_US"
        XCTAssertEqual(OrbConfigManager.shared.speechLocale.identifier, "en_US")
    }

    func testRecognizerDefaultsToTheDeviceProvenOne() {
        let saved = TestHost.defaults.object(forKey: AppSettings.orbRecognizerKey)
        TestHost.defaults.removeObject(forKey: AppSettings.orbRecognizerKey)
        defer { if let saved { TestHost.defaults.set(saved, forKey: AppSettings.orbRecognizerKey) } }
        XCTAssertEqual(OrbConfigManager.shared.recognizer, .whisperKit)
        XCTAssertFalse(OrbConfigManager.shared.recognizer.isAppleSpeech)
    }

    func testAnUnknownStoredRecognizerFallsBackToWhisperKit() {
        let saved = TestHost.defaults.object(forKey: AppSettings.orbRecognizerKey)
        TestHost.defaults.set("nextGenThing", forKey: AppSettings.orbRecognizerKey)
        defer {
            TestHost.defaults.removeObject(forKey: AppSettings.orbRecognizerKey)
            if let saved { TestHost.defaults.set(saved, forKey: AppSettings.orbRecognizerKey) }
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
