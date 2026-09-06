//
//  JarvisConfigTests.swift
//  DevgenticTests
//
//  The Jarvis settings layer. Covers the two shapes the design review argued hardest for —
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
final class JarvisActivationModeTests: XCTestCase {

    func testOnlyHoldShortcutKeepsTheMicrophoneClosedAtRest() {
        // This is the property the whole default rests on: the other two modes run a speech
        // model against the room for as long as the orb is open.
        XCTAssertFalse(JarvisActivationMode.holdShortcut.listensContinuously)
        XCTAssertTrue(JarvisActivationMode.wakeWord.listensContinuously)
        XCTAssertTrue(JarvisActivationMode.clickOrb.listensContinuously)
    }

    func testEveryModeIsSelectableAndIdentifiable() {
        XCTAssertEqual(JarvisActivationMode.allCases.count, 3)
        XCTAssertEqual(Set(JarvisActivationMode.allCases.map(\.id)).count, 3)
    }
}

@MainActor
final class JarvisEndpointingTests: XCTestCase {

    func testStepsAreOrderedAndDistinct() {
        XCTAssertLessThan(JarvisEndpointing.quick.seconds, JarvisEndpointing.normal.seconds)
        XCTAssertLessThan(JarvisEndpointing.normal.seconds, JarvisEndpointing.relaxed.seconds)
    }

    func testNoStepFallsBelowWhisperKitsOwnSilenceFloor() {
        // ⚠️ The load-bearing assertion. The effective end-of-speech is min(our window,
        // WhisperKit's ~1.5s VAD auto-stop), so any step below 1.5s would be silently inert —
        // a control the user can move that visibly does nothing. If someone lowers `quick`,
        // this fails and tells them why.
        let whisperKitSilenceFloor: TimeInterval = 1.5
        for step in JarvisEndpointing.allCases {
            XCTAssertGreaterThanOrEqual(step.seconds, whisperKitSilenceFloor,
                                        "\(step.rawValue) would be preempted by WhisperKit's own VAD and do nothing")
        }
    }

    func testNormalPreservesThePreSettingsBehaviour() {
        // 2.2s was the hardcoded `commandSilenceCommit`. The default must not change what
        // existing users already feel.
        XCTAssertEqual(JarvisEndpointing.normal.seconds, 2.2, accuracy: 0.001)
    }
}

// MARK: - Config manager

@MainActor
final class JarvisConfigManagerTests: XCTestCase {

    private let keys = [
        AppSettings.jarvisEnabledKey, AppSettings.jarvisActivationModeKey,
        AppSettings.jarvisShortcutCodeKey, AppSettings.jarvisShortcutModifiersKey,
        AppSettings.jarvisEndpointingKey, AppSettings.jarvisNarratorVoiceKey,
        AppSettings.jarvisNarratorRateKey, AppSettings.jarvisProfileIDKey,
        JarvisPanelController.originXKey, JarvisPanelController.originYKey,
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
        XCTAssertEqual(JarvisConfigManager.shared.activationMode, .holdShortcut)
    }

    func testDefaultsPreserveExistingBehaviourEverywhereElse() {
        let config = JarvisConfigManager.shared
        XCTAssertTrue(config.isEnabled)
        XCTAssertEqual(config.endpointing, .normal)
        XCTAssertTrue(config.usesReadAloudVoice, "an unset voice must follow the chat Read Aloud voice, as it did before this pane existed")
        XCTAssertEqual(config.narratorRate, 0, "0 is the sentinel for 'same rate as Read Aloud'")
        XCTAssertNil(config.profileID)
    }

    func testUnsetBooleanDefaultsToTrueRatherThanFalse() {
        // `defaults.bool(forKey:)` cannot distinguish unset from false, which is why the manager
        // uses `object(forKey:) as? Bool ?? true`. Pin it: a fresh install must have Jarvis on.
        XCTAssertNil(UserDefaults.standard.object(forKey: AppSettings.jarvisEnabledKey))
        XCTAssertTrue(JarvisConfigManager.shared.isEnabled)
    }

    // MARK: Round-trips

    func testActivationModeRoundTrips() {
        JarvisConfigManager.shared.activationMode = .wakeWord
        XCTAssertEqual(JarvisConfigManager.shared.activationMode, .wakeWord)
    }

    func testEndpointingRoundTrips() {
        JarvisConfigManager.shared.endpointing = .relaxed
        XCTAssertEqual(JarvisConfigManager.shared.endpointing, .relaxed)
    }

    func testChoosingAVoiceBreaksTheReadAloudCoupling() {
        JarvisConfigManager.shared.narratorVoiceID = "com.apple.voice.example"
        XCTAssertFalse(JarvisConfigManager.shared.usesReadAloudVoice)
        JarvisConfigManager.shared.narratorVoiceID = ""
        XCTAssertTrue(JarvisConfigManager.shared.usesReadAloudVoice)
    }

    // MARK: Corrupt / externally-written defaults

    func testCorruptShortcutDefaultFallsBackInsteadOfTrapping() {
        // `defaults write … -1` must not crash-loop the app: this is read at launch and there is
        // no in-app recovery. The manager uses UInt32(exactly:) plus a fallback.
        UserDefaults.standard.set(-1, forKey: AppSettings.jarvisShortcutCodeKey)
        UserDefaults.standard.set(Int(UInt32.max) + 5, forKey: AppSettings.jarvisShortcutModifiersKey)
        XCTAssertEqual(JarvisConfigManager.shared.carbonKeyCode, JarvisConfigManager.defaultCombo.carbonKeyCode)
        XCTAssertEqual(JarvisConfigManager.shared.carbonModifiers, JarvisConfigManager.defaultCombo.carbonModifiers)
    }

    func testUnknownStoredEnumValuesFallBackToDefaults() {
        UserDefaults.standard.set("teleportation", forKey: AppSettings.jarvisActivationModeKey)
        UserDefaults.standard.set("instant", forKey: AppSettings.jarvisEndpointingKey)
        XCTAssertEqual(JarvisConfigManager.shared.activationMode, .holdShortcut)
        XCTAssertEqual(JarvisConfigManager.shared.endpointing, .normal)
    }

    func testNarratorRateIsClampedToASpeakableRange() {
        UserDefaults.standard.set(Float(99), forKey: AppSettings.jarvisNarratorRateKey)
        XCTAssertEqual(JarvisConfigManager.shared.narratorRate, 2.0, accuracy: 0.001)
        UserDefaults.standard.set(Float(0.01), forKey: AppSettings.jarvisNarratorRateKey)
        XCTAssertEqual(JarvisConfigManager.shared.narratorRate, 0.5, accuracy: 0.001)
        UserDefaults.standard.set(Float(-3), forKey: AppSettings.jarvisNarratorRateKey)
        XCTAssertEqual(JarvisConfigManager.shared.narratorRate, 0, "a negative rate must read as the sentinel, never as speech")
    }

    // MARK: Reset

    func testResetAlsoClearsTheStrandedPanelPosition() {
        // The reason Reset is user-facing at all: the panel is borderless with no titlebar, so a
        // position saved from a since-disconnected display cannot be dragged back.
        JarvisConfigManager.shared.activationMode = .wakeWord
        UserDefaults.standard.set(9999.0, forKey: JarvisPanelController.originXKey)
        UserDefaults.standard.set(9999.0, forKey: JarvisPanelController.originYKey)

        JarvisConfigManager.shared.resetAll()

        XCTAssertEqual(JarvisConfigManager.shared.activationMode, .holdShortcut)
        XCTAssertNil(UserDefaults.standard.object(forKey: JarvisPanelController.originXKey))
        XCTAssertNil(UserDefaults.standard.object(forKey: JarvisPanelController.originYKey))
    }
}

// MARK: - Experimental paths must default to the proven one

@MainActor
final class JarvisExperimentalDefaultsTests: XCTestCase {

    /// ⚠️ Both of these ship untested against real audio hardware, and both fail in ways that look
    /// like nothing: a duplex engine that opens and hears silence, and an Apple-Speech session that
    /// transcribes zero results because a hand-rolled format conversion was wrong. A default that
    /// drifted to the experimental path would hand every user a silently broken microphone.
    func testDuplexAudioDefaultsOff() {
        let saved = UserDefaults.standard.object(forKey: AppSettings.jarvisDuplexAudioKey)
        UserDefaults.standard.removeObject(forKey: AppSettings.jarvisDuplexAudioKey)
        defer { if let saved { UserDefaults.standard.set(saved, forKey: AppSettings.jarvisDuplexAudioKey) } }
        XCTAssertFalse(JarvisConfigManager.shared.duplexAudioEnabled)
    }

    func testSpeechLocaleDefaultsToTheSystemAndRoundTrips() {
        // ⚠️ Empty is the sentinel for "follow the system". It matters that this is an EXPLICIT
        // choice: Apple ships one model per locale and `SpeechTranscriber` runs DEGRADED, without
        // erroring, when that model was never installed — which is exactly how the 2026-09-04
        // device test produced "write an SM technology" from "write an essay on technology".
        let saved = UserDefaults.standard.object(forKey: AppSettings.jarvisSpeechLocaleKey)
        UserDefaults.standard.removeObject(forKey: AppSettings.jarvisSpeechLocaleKey)
        defer {
            UserDefaults.standard.removeObject(forKey: AppSettings.jarvisSpeechLocaleKey)
            if let saved { UserDefaults.standard.set(saved, forKey: AppSettings.jarvisSpeechLocaleKey) }
        }
        XCTAssertEqual(JarvisConfigManager.shared.speechLocaleIdentifier, "")
        XCTAssertEqual(JarvisConfigManager.shared.speechLocale.identifier, Locale.current.identifier)

        JarvisConfigManager.shared.speechLocaleIdentifier = "en_US"
        XCTAssertEqual(JarvisConfigManager.shared.speechLocale.identifier, "en_US")
    }

    func testRecognizerDefaultsToTheDeviceProvenOne() {
        let saved = UserDefaults.standard.object(forKey: AppSettings.jarvisRecognizerKey)
        UserDefaults.standard.removeObject(forKey: AppSettings.jarvisRecognizerKey)
        defer { if let saved { UserDefaults.standard.set(saved, forKey: AppSettings.jarvisRecognizerKey) } }
        XCTAssertEqual(JarvisConfigManager.shared.recognizer, .whisperKit)
        XCTAssertFalse(JarvisConfigManager.shared.recognizer.isAppleSpeech)
    }

    func testAnUnknownStoredRecognizerFallsBackToWhisperKit() {
        let saved = UserDefaults.standard.object(forKey: AppSettings.jarvisRecognizerKey)
        UserDefaults.standard.set("nextGenThing", forKey: AppSettings.jarvisRecognizerKey)
        defer {
            UserDefaults.standard.removeObject(forKey: AppSettings.jarvisRecognizerKey)
            if let saved { UserDefaults.standard.set(saved, forKey: AppSettings.jarvisRecognizerKey) }
        }
        XCTAssertEqual(JarvisConfigManager.shared.recognizer, .whisperKit)
    }
}

// MARK: - Diagnostic bundle export

final class JarvisPreferenceExportTests: XCTestCase {

    func testJarvisSettingsReachDiagnosticBundles() {
        // The reason the deletability contract was retired: a voice bug report is undebuggable
        // without knowing how the user had activation and endpointing configured.
        let allowlist = Set(BundleExporter.exportablePreferenceKeys)
        for key in [AppSettings.jarvisEnabledKey, AppSettings.jarvisActivationModeKey,
                    AppSettings.jarvisEndpointingKey, AppSettings.jarvisNarratorVoiceKey,
                    AppSettings.jarvisNarratorRateKey] {
            XCTAssertTrue(allowlist.contains(key), "\(key) should be exportable")
        }
    }

    func testTheShortcutItselfIsNotExported() {
        // Not secret, but it carries no diagnostic value and its key names would trip the
        // allowlist's secret-shaped-name guard. Documented here so nobody "fixes" the omission.
        let allowlist = Set(BundleExporter.exportablePreferenceKeys)
        XCTAssertFalse(allowlist.contains(AppSettings.jarvisShortcutCodeKey))
        XCTAssertFalse(allowlist.contains(AppSettings.jarvisProfileIDKey))
    }
}
