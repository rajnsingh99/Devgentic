// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2026 Raj Singh
//
//  JarvisDuplexAudioTests.swift
//  DevgenticTests
//
//  Pins the admission policy for the panel-scoped duplex engine. Every clause here is a bug that
//  already happened on device, so these are regression pins, not coverage.
//

import XCTest
@testable import devgentic

final class JarvisDuplexAudioAdmissionTests: XCTestCase {

    private func refusal(duplex: Bool = true,
                         recognizer: JarvisRecognizer = .whisperKit,
                         activation: JarvisActivationMode = .wakeWord,
                         owner: VoiceSurface? = nil) -> String? {
        JarvisDuplexAudio.refusal(
            duplexEnabled: duplex,
            recognizer: recognizer,
            activationMode: activation,
            activeVoiceOwner: owner
        )
    }

    func testWarmsWhenEveryGateIsSatisfied() {
        XCTAssertNil(refusal(), "Wake-word + WhisperKit + duplex on + free microphone is the one configuration that should warm.")
    }

    func testDoesNotWarmWhenTheFeatureIsOff() {
        XCTAssertNotNil(refusal(duplex: false))
    }

    /// Apple Speech builds its own engine through the same builder, and AVAudioNode allows one tap
    /// per bus. Two input engines on one device is what breaks capture.
    func testDoesNotWarmForAppleSpeech() {
        let reason = refusal(recognizer: .appleSpeech)
        XCTAssertNotNil(reason)
        XCTAssertTrue(reason!.lowercased().contains("own engine"), "The reason must name the cause: \(reason!)")
    }

    /// ⚠️ THE PRODUCT PROMISE. Hold-to-talk exists to keep the microphone closed at rest; a warm
    /// engine holds the input device — and macOS's orange indicator — for the whole session.
    func testDoesNotWarmInHoldToTalk() {
        let reason = refusal(activation: .holdShortcut)
        XCTAssertNotNil(reason, "Hold-to-talk must never pre-warm — it would hold the mic in the one mode that promises not to.")
        XCTAssertTrue(reason!.lowercased().contains("hold-to-talk"), "The reason must name the cause: \(reason!)")
    }

    /// The engine used to be built AFTER VoiceSessionLedger.begin — the app's only capture
    /// serialisation. Warming at panel open happens before it, so this gate replaces it.
    func testDoesNotWarmWhileAnotherSurfaceHoldsTheMicrophone() {
        for owner in [VoiceSurface.mainComposer, .quickAccess] {
            let reason = refusal(owner: owner)
            XCTAssertNotNil(reason, "\(owner.rawValue) holding the mic must block warming.")
            XCTAssertTrue(reason!.contains(owner.rawValue), "The reason must name the holder: \(reason!)")
        }
    }

    /// Jarvis holding its own slot is not a reason to refuse a rebuild for some other surface —
    /// but it IS still a second engine, so the gate is deliberately owner-agnostic.
    func testEvenJarvisHoldingTheSlotBlocksASecondEngine() {
        XCTAssertNotNil(refusal(owner: .jarvis))
    }

    /// Order matters for the log: the most actionable cause should win.
    func testTheFeatureFlagIsReportedBeforeAnyOtherCause() {
        let reason = refusal(duplex: false, recognizer: .appleSpeech, activation: .holdShortcut, owner: .mainComposer)
        XCTAssertEqual(reason, "duplex audio is off in Settings")
    }
}
