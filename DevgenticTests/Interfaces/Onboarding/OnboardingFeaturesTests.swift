// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
//
//  OnboardingFeaturesTests.swift
//  DevgenticTests
//
//  The Features, Permissions and Privacy steps:
//    • the switches apply at once through the same path as Settings, and Cancel puts them back;
//    • only the permissions the user's choices need are offered, all optional, with live status;
//    • the update question has no pre-selected answer, and answers apply only on completion.
//

import XCTest
@testable import devgentic

@MainActor
final class OnboardingFeaturesTests: XCTestCase {

    private func make(_ settings: FakeOnboardingSystemSettings? = nil) -> OnboardingViewModel {
        OnboardingViewModel(physicalMemoryBytes: 16 * 1_073_741_824, checksInstallStatus: false,
                            systemSettings: settings ?? FakeOnboardingSystemSettings())
    }

    // MARK: - Flow

    func testFeaturesPermissionsAndPrivacyComeBetweenBehaviorAndTheme() {
        XCTAssertEqual(OnboardingViewModel.Step.allCases,
                       [.welcome, .profileSetup, .modelDownload, .behavior, .features, .permissions, .privacy, .themeCustomization, .ready])
        XCTAssertEqual(OnboardingViewModel.Step.features.progressLabel, "STEP 4 OF 7")
        XCTAssertEqual(OnboardingViewModel.Step.themeCustomization.progressLabel, "STEP 7 OF 7")
        XCTAssertNil(OnboardingViewModel.Step.ready.progressLabel)
    }

    /// Wiring: each screen's Continue/Back lands on its neighbour.
    func testEachNewStepNavigatesToItsNeighbours() throws {
        let expectations: [(file: String, steps: [String])] = [
            ("OnboardingBehaviorView", [".modelDownload", ".features"]),
            ("OnboardingFeaturesView", [".behavior", ".permissions"]),
            ("OnboardingPermissionsView", [".features", ".privacy"]),
            ("OnboardingPrivacyView", [".permissions", ".themeCustomization"]),
            ("OnboardingThemeView", [".privacy", ".ready"]),
        ]
        for (file, steps) in expectations {
            let text = try source("Devgentic/Interfaces/Onboarding/Views/\(file).swift")
            for step in steps {
                XCTAssertTrue(text.contains("viewModel.goToStep(\(step))"), "\(file) does not go to \(step)")
            }
        }
    }

    // MARK: - Features

    func testTheSwitchesApplyImmediately() {
        let settings = FakeOnboardingSystemSettings()
        let vm = make(settings)
        vm.setQuickAccessEnabled(false)
        vm.setOrbEnabled(true)
        XCTAssertFalse(settings.quickAccessEnabled)
        XCTAssertTrue(settings.orbEnabled)
    }

    func testAReRunStartsFromTheCurrentSwitchesAndAnswers() {
        let settings = FakeOnboardingSystemSettings()
        settings.quickAccessEnabled = false
        settings.orbEnabled = true
        settings.automaticUpdateChecks = true
        settings.diagnosticsEnabled = false
        let vm = make(settings)

        vm.adoptCurrentSettings()

        XCTAssertFalse(vm.quickAccessEnabled)
        XCTAssertTrue(vm.orbEnabled)
        XCTAssertEqual(vm.automaticUpdateChecks, true)
        XCTAssertFalse(vm.diagnosticsEnabled)
    }

    func testCancelPutsTheSwitchesBack() {
        let settings = FakeOnboardingSystemSettings()
        let vm = make(settings)
        vm.adoptCurrentSettings()
        vm.adoptCurrentTheme(from: ThemeManager())
        vm.setQuickAccessEnabled(false)
        vm.setOrbEnabled(true)

        vm.existingProfileNames = ["Research"]
        vm.cancelSetup(themeManager: ThemeManager()) { _ in }

        XCTAssertTrue(settings.quickAccessEnabled)
        XCTAssertFalse(settings.orbEnabled)
    }

    /// The live switches go through the same calls as the Settings panes.
    func testTheLiveSwitchesUseTheSettingsPanesPath() throws {
        let live = try source("Devgentic/Interfaces/Onboarding/OnboardingSystemSettings.swift")
        XCTAssertTrue(live.contains("QuickAccessConfigManager.shared.isEnabled = newValue\n            AppDelegate.shared?.applyHotkeyConfig()"))
        XCTAssertTrue(live.contains("OrbConfigManager.shared.isEnabled = newValue\n            AppDelegate.shared?.applyOrbHotkeyConfig()"))
        let container = try source("Devgentic/Interfaces/Onboarding/Views/OnboardingContainerView.swift")
        XCTAssertTrue(container.contains("viewModel.adoptCurrentSettings()"))
    }

    // MARK: - Permissions

    func testOnlyThePermissionsTheChoicesNeedAreOffered() {
        let vm = make()
        vm.adoptCurrentSettings()
        XCTAssertEqual(vm.relevantPermissions, [.microphone, .calendar, .reminders, .screenRecording])

        vm.toggleTool("manage_calendar")
        XCTAssertFalse(vm.relevantPermissions.contains(.calendar), "calendar tool is off")

        vm.setQuickAccessEnabled(false)
        XCTAssertFalse(vm.relevantPermissions.contains(.screenRecording), "Quick Access is off")

        vm.selectProfileType(.bot)
        XCTAssertEqual(vm.relevantPermissions, [.microphone], "a chat bot has no tools")
    }

    func testRequestingAPermissionShowsTheAnswer() async {
        let settings = FakeOnboardingSystemSettings()
        settings.requestResults = [.calendar: .granted, .reminders: .denied]
        let vm = make(settings)

        await vm.requestPermission(.calendar)
        await vm.requestPermission(.reminders)

        XCTAssertEqual(vm.status(of: .calendar), .granted)
        XCTAssertEqual(vm.status(of: .reminders), .denied)
        XCTAssertEqual(settings.requested, [.calendar, .reminders])
    }

    /// macOS reports Screen Recording only as granted-or-not, so a refusal reads back as "not
    /// asked". A refresh must not turn the row back into an Allow button that does nothing.
    func testARefusedScreenRecordingStaysRefusedOnRefresh() async {
        let settings = FakeOnboardingSystemSettings()
        settings.requestResults = [.screenRecording: .denied]
        let vm = make(settings)

        await vm.requestPermission(.screenRecording)
        vm.refreshPermissionStatuses()

        XCTAssertEqual(vm.status(of: .screenRecording), .denied)
    }

    func testPermissionsNeverBlockContinue() throws {
        let view = try source("Devgentic/Interfaces/Onboarding/Views/OnboardingPermissionsView.swift")
        XCTAssertTrue(view.contains("OnboardingPrimaryButton(\"Continue\") {"), "Continue must not be gated on a permission")
    }

    // MARK: - Privacy

    func testTheUpdateQuestionHasNoPreselectedAnswer() {
        let vm = make()
        vm.adoptCurrentSettings()
        XCTAssertNil(vm.automaticUpdateChecks)
        XCTAssertFalse(vm.canContinueFromPrivacy)

        vm.automaticUpdateChecks = false
        XCTAssertTrue(vm.canContinueFromPrivacy, "\"only when I ask\" is a valid answer")
    }

    /// A refused completion (here, a duplicate name) applies no privacy answer.
    func testAnswersAreNotAppliedWhenCompletionIsRefused() {
        let settings = FakeOnboardingSystemSettings()
        let vm = make(settings)
        vm.automaticUpdateChecks = true
        vm.diagnosticsEnabled = false
        vm.fetchExistingProfileNames = { ["Research"] }
        vm.profileDisplayName = "Research"

        vm.completeOnboarding(themeManager: ThemeManager()) { _ in }

        XCTAssertTrue(settings.updateAnswersSet.isEmpty)
        XCTAssertTrue(settings.diagnosticsEnabled, "diagnostics changed by a refused completion")
    }

    /// Answers apply only after the profile is saved, so a failed save changes nothing either.
    func testAnswersAreAppliedAfterTheProfileIsSaved() throws {
        let vm = try source("Devgentic/Interfaces/Onboarding/OnboardingViewModel.swift")
        guard let save = vm.range(of: "try BackendProfileStore.shared.saveProfile("),
              let apply = vm.range(of: "systemSettings.setAutomaticUpdateChecks(automaticUpdateChecks)"),
              let diagnostics = vm.range(of: "systemSettings.diagnosticsEnabled = diagnosticsEnabled") else {
            return XCTFail("completion sequence moved")
        }
        XCTAssertLessThan(save.lowerBound, apply.lowerBound)
        XCTAssertLessThan(save.lowerBound, diagnostics.lowerBound)
    }

    /// PRIVACY.md is the full version of the promise the Privacy step makes.
    func testPrivacyPolicyMatchesTheSetupFlow() throws {
        let policy = try source("PRIVACY.md")
        XCTAssertTrue(policy.contains("The setup\nassistant **asks** whether to check automatically, with no answer pre-selected"))
        XCTAssertTrue(policy.contains("## What leaves your Mac — only when you choose it"))
    }

    private func source(_ path: String) throws -> String {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent()
        guard let text = try? String(contentsOf: root.appendingPathComponent(path), encoding: .utf8) else {
            throw XCTSkip("\(path) not reachable — running outside a checkout")
        }
        return text
    }
}
