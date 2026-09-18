// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
//
//  OrbAccessibilityTests.swift
//  DevgenticTests
//
//  The orb as a CONTROL rather than a decoration.
//
//  ⚠️ WHAT WAS WRONG. The orb is the whole feature's only affordance — click-to-speak, send-now,
//  and the only way to interrupt an answer — and to VoiceOver it was an unlabelled shape carrying
//  an `onTapGesture`. Its state (STANDBY vs LISTENING vs WAITING ON YOU) was carried by colour and
//  an unlabelled capsule, and every recovery action, including "Repair Audio…" for a wedged
//  `coreaudiod`, lived exclusively behind a right-click, which needs a pointer.
//
//  ⚠️ WHAT IS STILL TRUE, so nobody reads this file as a clean bill of health: the panel is a
//  `.nonactivatingPanel` that deliberately does NOT take focus (it must not steal it from the chat
//  composer behind it — see `OrbPanelController.show`). Full keyboard-only operation would mean
//  reversing that decision, which is a product call, not a bug fix. VoiceOver reaches the orb and
//  all of its actions; the keyboard reaches them once the panel is key.
//

import XCTest
@testable import devgentic

@MainActor
final class OrbAccessibilityTests: XCTestCase {

    private let everyStage: [OrbStage] = [
        .selectingProfile, .welcoming, .passiveListening, .commandCapture,
        .followUpWindow, .executing, .awaitingApproval, .announcing,
        .voiceUnavailable(reason: "Microphone access is denied."),
    ]

    private func status(_ stage: OrbStage, micTrouble: Bool = false) -> String {
        OrbFloatingView.accessibilityStatus(stage: stage, micTrouble: micTrouble)
    }

    /// ⚠️ EVERY stage must say something. A stage that returns "" is a stage where a VoiceOver user
    /// is told the orb exists and nothing about what it is doing — which for a voice assistant is
    /// the entire information content.
    func testEveryStageAnnouncesSomething() {
        for stage in everyStage {
            XCTAssertFalse(status(stage).trimmingCharacters(in: .whitespaces).isEmpty,
                           "\(OrbSessionController.name(of: stage)) announces nothing")
        }
    }

    /// The stages a user must be able to tell apart by ear — being listened to, being worked for,
    /// and being waited on — must not share a phrase.
    func testTheStagesAUserMustDistinguishAreDistinct() {
        let mustDiffer: [OrbStage] = [.passiveListening, .commandCapture, .executing,
                                         .awaitingApproval, .announcing]
        let spoken = mustDiffer.map { status($0) }
        XCTAssertEqual(Set(spoken).count, spoken.count,
                       "Two stages announce identically, so they cannot be told apart: \(spoken)")
    }

    /// ⚠️ A dead microphone must be audible, not just amber. This is the state whose only remedy —
    /// "Repair Audio…" — is offered nowhere else, so a user who cannot see the colour change has to
    /// hear that something is wrong.
    func testATroubledMicrophoneIsAnnouncedDifferentlyFromStandby() {
        XCTAssertNotEqual(status(.passiveListening, micTrouble: true),
                          status(.passiveListening, micTrouble: false),
                          "NO AUDIO and STANDBY must not sound identical.")
        XCTAssertTrue(status(.passiveListening, micTrouble: true).lowercased().contains("audio"),
                      "The trouble state should name what is wrong: \(status(.passiveListening, micTrouble: true))")
    }

    /// ⚠️ Sentence case, deliberately. The capsule is styled in capitals for the HUD, and a screen
    /// reader is entitled to spell capitals out letter by letter — "W-A-I-T-I-N-G O-N Y-O-U".
    func testTheSpokenStatusIsNotTheCapitalisedHudText() {
        for stage in everyStage {
            let value = status(stage)
            XCTAssertNotEqual(value, value.uppercased(),
                              "\(value) is all capitals; a screen reader may spell it out.")
        }
    }
}

/// The wiring, read from the source — SwiftUI's accessibility modifiers have no runtime surface a
/// unit test can inspect, and rendering the orb needs a live session controller.
final class OrbAccessibilityWiringTests: XCTestCase {

    private func viewSource() throws -> String {
        let repoRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let file = repoRoot.appendingPathComponent("Devgentic/Orb/OrbFloatingView.swift")
        guard FileManager.default.fileExists(atPath: file.path) else {
            throw XCTSkip("OrbFloatingView.swift not reachable from \(repoRoot.path)")
        }
        return try String(contentsOf: file, encoding: .utf8)
    }

    /// ⚠️ THE TRAIT ALONE IS NOT ENOUGH. VoiceOver's activate does not reliably fire a bare
    /// `onTapGesture` on a shape, so the orb needs an explicit action as well as the button trait —
    /// otherwise it announces itself as a button that cannot be pressed.
    func testTheOrbIsAButtonThatCanActuallyBeActivated() throws {
        let source = try viewSource()
        XCTAssertTrue(source.contains(".accessibilityAddTraits(.isButton)"),
                      "The orb must announce itself as a button.")
        XCTAssertTrue(source.contains(".accessibilityAction { handleOrbTap() }"),
                      "The orb must be activatable — the trait without an action is a button that does nothing.")
        XCTAssertTrue(source.contains(".accessibilityLabel(Text(\"Orb\"))"),
                      "The orb must have a name.")
    }

    /// ⚠️⚠️ ONE LIST, TWO SURFACES. The recovery actions must reach the Actions rotor and the
    /// right-click menu from the SAME builder. Written twice they drift, and the copy that drifts
    /// is always the one nobody is looking at — here, the accessible one.
    func testTheMenuAndTheActionsRotorShareOneList() throws {
        let source = try viewSource()
        XCTAssertTrue(source.contains(".accessibilityActions { orbActions }"),
                      "The context-menu actions must also be exposed to VoiceOver.")
        XCTAssertTrue(source.contains(".contextMenu { orbActions }"),
                      "The right-click menu must come from the same builder, or the two drift.")
        // Exactly one place builds them.
        XCTAssertEqual(source.components(separatedBy: "private var orbActions").count - 1, 1,
                       "There should be exactly one orbActions builder.")
    }

    /// The capsule repeats the orb's own value; announcing it as a separate element makes every
    /// stage change read twice.
    func testTheStatusCapsuleIsNotAnnouncedTwice() throws {
        let source = try viewSource()
        guard let capsule = source.range(of: "private var statusCapsule: some View {") else {
            return XCTFail("could not locate statusCapsule")
        }
        let rest = source[capsule.upperBound...]
        guard let end = rest.range(of: "\n    }") else { return XCTFail("unterminated statusCapsule") }
        XCTAssertTrue(rest[..<end.lowerBound].contains(".accessibilityHidden(true)"),
                      "The status capsule duplicates the orb's accessibility value and should be hidden.")
    }
}
