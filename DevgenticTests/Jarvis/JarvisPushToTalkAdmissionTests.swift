// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2026 Raj Singh
//
//  JarvisPushToTalkAdmissionTests.swift
//  DevgenticTests
//
//  The push-to-talk entry path — which had NO test coverage of any kind until this file, and is
//  where the production-readiness P1 lived: on a cold open the shortcut arrived in `.welcoming`,
//  which the guard rejected silently, so the default activation mode lost the whole first
//  utterance on every single cold open.
//
//  ⚠️ WHY THE POLICY IS A PURE STATIC. The full path opens a real microphone (`startListeningLoop`
//  → permission prompt → `AVAudioEngine`), so it cannot run headlessly. Extracting the DECISION
//  keeps the part that was actually wrong testable, and `testEveryStageBeginCanLeaveBehindIsUsable`
//  below pins the coupling that broke — between what `begin()` produces and what the entry guard
//  accepts — which is the half a pure test of the guard alone would still have missed.
//

import XCTest
@testable import devgentic

@MainActor
final class JarvisPushToTalkAdmissionTests: XCTestCase {

    // MARK: - The regression

    /// ⚠️⚠️ THE P1, PINNED. `AppDelegate.jarvisPushToTalkDown` calls `show()` and then
    /// `beginPushToTalk()` in consecutive statements; `show()` runs `begin()` synchronously and
    /// `begin()` goes straight to `selectProfile`, which sets `.welcoming` on its first line. So
    /// `.welcoming` is the stage a cold-open press actually arrives in — not an edge case.
    func testAPressDuringTheGreetingArmsInsteadOfBeingDropped() {
        XCTAssertEqual(JarvisSessionController.pushToTalkAdmission(stage: .welcoming),
                       .cutGreetingAndArm,
                       "A cold open arrives in .welcoming. Refusing here loses the first utterance.")
    }

    /// ⚠️ THE COUPLING THAT BROKE, not just the guard. `begin()` can leave the controller in
    /// exactly two stages — `.selectingProfile` (no remembered profile) and `.welcoming` (one
    /// resolved) — and the shortcut press lands immediately afterwards. Every stage `begin()` can
    /// produce must therefore be one push-to-talk can act on, with the single defensible exception
    /// of the picker, where there is genuinely nothing to send to.
    func testEveryStageBeginCanLeaveBehindIsUsable() {
        for stage in [JarvisStage.selectingProfile, .welcoming] {
            switch JarvisSessionController.pushToTalkAdmission(stage: stage) {
            case .arm, .cutGreetingAndArm:
                continue
            case .refuse:
                XCTAssertEqual(stage, .selectingProfile,
                               "Only the profile picker may refuse a cold-open press: \(stage)")
            }
        }
    }

    // MARK: - The rest of the stage machine

    func testTheIdleStagesArmDirectly() {
        XCTAssertEqual(JarvisSessionController.pushToTalkAdmission(stage: .passiveListening), .arm)
        XCTAssertEqual(JarvisSessionController.pushToTalkAdmission(stage: .commandCapture), .arm)
    }

    /// A press mid-turn must not start a second one on top of it.
    func testAnInFlightTurnRefuses() {
        for stage in [JarvisStage.executing, .announcing, .awaitingApproval] {
            guard case .refuse = JarvisSessionController.pushToTalkAdmission(stage: stage) else {
                return XCTFail("\(stage) should refuse — a turn is already running")
            }
        }
    }

    /// ⚠️ Every refusal must carry a reason, because the whole defect was that refusing said
    /// NOTHING. A blank reason would put an empty clause in the log line and reintroduce it.
    func testEveryRefusalExplainsItself() {
        let refusing: [JarvisStage] = [
            .selectingProfile, .executing, .announcing, .awaitingApproval,
            .voiceUnavailable(reason: "Microphone access is denied."),
        ]
        for stage in refusing {
            guard case .refuse(let reason) = JarvisSessionController.pushToTalkAdmission(stage: stage) else {
                return XCTFail("\(stage) should refuse")
            }
            XCTAssertFalse(reason.trimmingCharacters(in: .whitespaces).isEmpty,
                           "\(stage) refused with no reason to log")
        }
    }

    /// The unavailable reason is user-facing text already shown in the orb tooltip; the log line
    /// should carry it rather than inventing a second wording that can drift from it.
    func testTheUnavailableRefusalQuotesTheRealReason() {
        let reason = "The microphone opened but delivered no audio."
        guard case .refuse(let logged) = JarvisSessionController
            .pushToTalkAdmission(stage: .voiceUnavailable(reason: reason)) else {
            return XCTFail("voiceUnavailable should refuse")
        }
        XCTAssertTrue(logged.contains(reason), logged)
    }

    // MARK: - Wiring

    /// ⚠️ Proves `beginPushToTalk` actually CONSULTS the policy rather than carrying its own copy
    /// of the stage set — the exact drift that caused the original bug, where the inner loop
    /// guards were updated and the entry guard was not. A fresh controller starts in
    /// `.selectingProfile`, which the policy refuses, so the stage must be unchanged afterwards.
    ///
    /// Deliberately the REFUSING case: the arming cases reach `startListeningLoop()` and would ask
    /// for microphone permission in a unit test.
    func testTheEntryPointHonoursTheRefusal() {
        let controller = JarvisSessionController()
        XCTAssertEqual(JarvisSessionController.name(of: controller.stage), "selectingProfile",
                       "a fresh controller should start at the picker")

        controller.beginPushToTalk()

        XCTAssertEqual(JarvisSessionController.name(of: controller.stage), "selectingProfile",
                       "A press at the picker must not arm capture — there is no profile to send to.")
        XCTAssertFalse(controller.isExecuting)
    }

    /// A refused press must not latch the held flag, or the NEXT press — the one that would have
    /// worked — is swallowed by `guard !pushToTalkHeld`.
    func testARefusedPressDoesNotBlockTheNextOne() {
        let controller = JarvisSessionController()
        controller.beginPushToTalk()
        controller.beginPushToTalk()
        XCTAssertEqual(JarvisSessionController.name(of: controller.stage), "selectingProfile")
    }

    /// ⚠️⚠️ THE TEST THAT WOULD ACTUALLY HAVE CAUGHT THE BUG, and the reason the two above are
    /// not enough: the ORIGINAL guard refused `.selectingProfile` too, so
    /// `testTheEntryPointHonoursTheRefusal` passes against the broken code. Only driving the real
    /// cold-open sequence distinguishes them.
    ///
    /// This reproduces `AppDelegate.jarvisPushToTalkDown` on a machine with a remembered profile:
    /// `begin()` resolves it straight into `selectProfile`, and the press lands one statement
    /// later. If `beginPushToTalk` ever goes back to hard-coding the idle stages, this fails.
    func testAColdOpenPressArmsCaptureForReal() {
        let savedProfile = UserDefaults.standard.string(forKey: AppSettings.jarvisProfileIDKey)
        let savedEarcons = UserDefaults.standard.string(forKey: AppSettings.jarvisEarconsKey)
        defer {
            restore(savedProfile, forKey: AppSettings.jarvisProfileIDKey)
            restore(savedEarcons, forKey: AppSettings.jarvisEarconsKey)
        }
        // Keep the run silent: arming plays the "listening" earcon.
        JarvisConfigManager.shared.earcons = .off

        let controller = JarvisSessionController()
        controller.selectProfile(Self.testProfile())
        XCTAssertEqual(JarvisSessionController.name(of: controller.stage), "welcoming",
                       "selectProfile is exactly what begin() calls for a remembered profile")

        controller.beginPushToTalk()

        XCTAssertEqual(JarvisSessionController.name(of: controller.stage), "commandCapture",
                       "The cold-open press MUST arm capture. Refusing here is the P1 — the whole "
                       + "first utterance is captured by nothing, and nothing is logged about it.")
        controller.teardown()
    }

    // MARK: - Helpers

    private func restore(_ value: String?, forKey key: String) {
        if let value {
            UserDefaults.standard.set(value, forKey: key)
        } else {
            UserDefaults.standard.removeObject(forKey: key)
        }
    }

    /// The cheapest profile `selectProfile` will accept. Nothing here reaches a backend — the
    /// controller only reads `id` and `displayName` before the stage transition under test.
    private static func testProfile() -> BackendProfileModel {
        BackendProfileModel(
            displayName: "Push-to-talk test bot",
            details: .bot(BotConfig(
                llmConfig: ProviderConfig(
                    apiProvider: .openAI,
                    modelName: "test-model",
                    apiKey: nil,
                    baseURL: nil,
                    advancedConfiguration: nil
                ),
                instructions: nil,
                knowledgeSources: nil
            ))
        )
    }
}
