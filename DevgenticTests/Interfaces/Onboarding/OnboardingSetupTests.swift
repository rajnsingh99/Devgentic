// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
//
//  OnboardingSetupTests.swift
//  DevgenticTests
//
//  Created by Raj Singh.
//

import XCTest
@testable import devgentic

@MainActor
final class OnboardingSetupTests: XCTestCase {

    private let gb: UInt64 = 1_073_741_824

    private func makeViewModel(ramGB: UInt64 = 16) -> OnboardingViewModel {
        OnboardingViewModel(physicalMemoryBytes: ramGB * gb, checksInstallStatus: false,
                            systemSettings: FakeOnboardingSystemSettings())
    }

    // MARK: - Retry, then skip

    func testTwoRetriesAfterTheFirstFailureThenOnlySkip() {
        XCTAssertEqual(OnboardingViewModel.downloadRecovery(failedAttempts: 0), .none)
        XCTAssertEqual(OnboardingViewModel.downloadRecovery(failedAttempts: 1), .retry(remaining: 2))
        XCTAssertEqual(OnboardingViewModel.downloadRecovery(failedAttempts: 2), .retry(remaining: 1))
        XCTAssertEqual(OnboardingViewModel.downloadRecovery(failedAttempts: 3), .skipOnly)
        XCTAssertEqual(OnboardingViewModel.downloadRecovery(failedAttempts: 9), .skipOnly)
    }

    /// Wiring: the real view model refuses Continue and Skip until the retries are spent, and
    /// refuses another download once they are.
    func testSkipIsRefusedUntilTheRetriesAreUsedUp() {
        let vm = makeViewModel()
        XCTAssertFalse(vm.canContinueFromModelStep, "Continue must wait for the download")

        vm.skipModelDownload()
        XCTAssertFalse(vm.didSkipDownload, "skip with no failures")

        vm.recordDownloadFailure("network")
        vm.recordDownloadFailure("network")
        vm.skipModelDownload()
        XCTAssertFalse(vm.didSkipDownload, "skip with a retry still left")
        XCTAssertFalse(vm.canContinueFromModelStep)

        vm.recordDownloadFailure("network")
        XCTAssertEqual(vm.downloadRecovery, .skipOnly)
        vm.startModelDownload()
        XCTAssertFalse(vm.isDownloading, "a fourth download must not start once only Skip is offered")

        vm.skipModelDownload()
        XCTAssertTrue(vm.didSkipDownload)
        XCTAssertTrue(vm.canContinueFromModelStep)
        XCTAssertEqual(vm.currentStep, .behavior)
    }

    // MARK: - Starter models

    func testEachEngineOffersFiveModelsSmallestFirstWithinTheCeiling() {
        for (engine, list) in [("MLX", OnboardingStarterCatalog.mlxModels), ("Ollama", OnboardingStarterCatalog.ollamaModels)] {
            XCTAssertEqual(list.count, 5, engine)
            XCTAssertEqual(Set(list.map(\.id)).count, 5, "\(engine): duplicate ids")
            XCTAssertEqual(list.map(\.downloadBytes), list.map(\.downloadBytes).sorted(), "\(engine): not smallest first")
            for model in list {
                XCTAssertLessThanOrEqual(model.downloadBytes, OnboardingStarterCatalog.maxDownloadBytes, model.id)
            }
        }
        XCTAssertEqual(OnboardingStarterCatalog.maxDownloadBytes, 24_000_000_000)
    }

    /// Curation rule 3: mlx-community's copies of these models keep the chat template only in a
    /// `chat_template.jinja` sidecar, which `MLXTokenizerAnalyzer` does not read — they would route
    /// to "no tools". Remove this test when the analyzer reads the sidecar.
    func testMLXModelsAreUploadsWhoseTemplateTheAnalyzerCanRead() {
        for model in OnboardingStarterCatalog.mlxModels {
            XCTAssertTrue(model.id.hasPrefix("lmstudio-community/"), "\(model.id) — see OnboardingCatalog rule 3")
        }
        for model in OnboardingStarterCatalog.ollamaModels {
            XCTAssertEqual(model.id.split(separator: ":").count, 2, "\(model.id) must be an exact name:tag")
        }
    }

    func testTheRecommendationFitsTheMacsMemory() {
        func pick(_ ramGB: UInt64) -> String? {
            OnboardingStarterCatalog.recommended(for: .mlx, physicalMemoryBytes: ramGB * gb)?.sizeClass
        }
        XCTAssertEqual(pick(4), "Tiny", "below every minimum, fall back to the smallest")
        XCTAssertEqual(pick(8), "Small")
        XCTAssertEqual(pick(16), "Balanced")
        XCTAssertEqual(pick(24), "Capable")
        XCTAssertEqual(pick(64), "Medium")
    }

    func testTheViewModelStartsOnTheRecommendedModelAndKeepsTheRungAcrossEngines() {
        let vm = makeViewModel(ramGB: 16)
        XCTAssertEqual(vm.selectedModelIdentifier, "lmstudio-community/Qwen3.5-9B-MLX-4bit")

        vm.selectBackend(.ollama)
        XCTAssertEqual(vm.selectedModelIdentifier, "qwen3.5:9b")

        vm.selectModel("not-a-starter-model")
        XCTAssertEqual(vm.selectedModelIdentifier, "qwen3.5:9b", "only listed models are selectable")
    }

    // MARK: - Starter tools

    func testTheTenStarterToolsAllExistInTheLibrary() {
        XCTAssertEqual(OnboardingToolPreset.tools.count, 10)
        let library = Set(NativeToolCatalog.libraryTools.map(\.name))
        for tool in OnboardingToolPreset.tools {
            XCTAssertTrue(library.contains(tool.id), "'\(tool.id)' is not a Tool Library tool")
        }
    }

    // MARK: - The profile the user lands on

    /// Wiring: what `completeOnboarding` saves is `makeProfileDetails()`, and by default that is an
    /// agent with all ten tools, every one enabled and asking first, plus the default prompt.
    func testTheDefaultProfileIsAnAgentWithTenAskingToolsAndAPrompt() throws {
        let vm = makeViewModel()
        guard case .agent(let config) = vm.makeProfileDetails() else { return XCTFail("default must be an agent") }

        XCTAssertEqual(config.tools.map(\.name), OnboardingToolPreset.tools.map(\.id))
        XCTAssertTrue(config.tools.allSatisfy(\.isEnabled))
        XCTAssertTrue(config.tools.allSatisfy(\.requiresConfirmation), "every starter tool must ASK by default")
        XCTAssertTrue(config.tools.allSatisfy { $0.sourceId == ToolSource.builtInSourceID })
        XCTAssertFalse(config.tools.first { $0.name == "run_command" }?.parameters.properties.isEmpty ?? true,
                       "schemas must come from the catalogue, not be left empty")
        XCTAssertEqual(config.instructions, OnboardingPromptDefaults.agent.trimmingCharacters(in: .whitespacesAndNewlines))
        XCTAssertEqual(config.llmConfig.modelName, vm.selectedModelIdentifier)
        XCTAssertEqual(config.llmConfig.apiProvider, .mlx)

        let vmSource = try source("Devgentic/Interfaces/Onboarding/OnboardingViewModel.swift")
        XCTAssertTrue(vmSource.contains("BackendProfileModel(displayName: finalName, details: makeProfileDetails())"),
                      "completeOnboarding no longer saves what makeProfileDetails builds")
    }

    func testToolChoicesCarryIntoTheProfile() {
        let vm = makeViewModel()
        vm.toggleTool("run_command")
        vm.setAutoApprove(true, for: "read_file")
        guard case .agent(let config) = vm.makeProfileDetails() else { return XCTFail() }

        let byName = Dictionary(uniqueKeysWithValues: config.tools.map { ($0.name, $0) })
        XCTAssertEqual(byName["run_command"]?.isEnabled, false)
        XCTAssertEqual(byName["read_file"]?.requiresConfirmation, false)
        XCTAssertEqual(byName["list_directory"]?.requiresConfirmation, true)
    }

    func testABotGetsThePromptAndNoTools() {
        let vm = makeViewModel()
        vm.selectProfileType(.bot)
        guard case .bot(let config) = vm.makeProfileDetails() else { return XCTFail("expected a bot") }
        XCTAssertEqual(config.instructions, OnboardingPromptDefaults.bot.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    func testSwitchingTypeSwapsTheDefaultPromptButNeverAnEditedOne() {
        let vm = makeViewModel()
        vm.selectProfileType(.bot)
        XCTAssertEqual(vm.systemPrompt, OnboardingPromptDefaults.bot)

        vm.systemPrompt = "Be terse."
        vm.selectProfileType(.agent)
        XCTAssertEqual(vm.systemPrompt, "Be terse.")
    }

    // MARK: - Profile name

    func testTheNameIsRequiredAndStartsEmpty() {
        let vm = makeViewModel()
        XCTAssertEqual(vm.profileDisplayName, "", "no auto-filled name — it duplicated on every re-run")
        XCTAssertNotNil(vm.profileNameProblem)

        vm.profileDisplayName = "   "
        XCTAssertNotNil(vm.profileNameProblem, "whitespace is not a name")

        vm.profileDisplayName = String(repeating: "a", count: ProfileValidationLimits.maxDisplayNameLength + 1)
        XCTAssertNotNil(vm.profileNameProblem, "over the validator's limit")

        vm.profileDisplayName = "  Research  "
        XCTAssertNil(vm.profileNameProblem)
        XCTAssertEqual(vm.trimmedProfileName, "Research")
    }

    /// Wiring: the profile step re-reads names from the store on Continue and holds on a duplicate,
    /// ignoring case and surrounding whitespace on both sides.
    func testTheProfileStepHoldsOnANameThatAlreadyExists() {
        let vm = makeViewModel()
        vm.fetchExistingProfileNames = { [" research "] }
        vm.profileDisplayName = "Research"

        vm.proceedFromProfileSetup()

        XCTAssertEqual(vm.currentStep, .welcome, "must not advance past a duplicate name")
        XCTAssertTrue(vm.profileNameProblem?.contains("already") == true)
    }

    /// A failed name lookup is shown, not silently treated as "no duplicates".
    func testAFailedNameLookupIsReported() {
        struct LookupFailed: Error {}
        let vm = makeViewModel()
        vm.fetchExistingProfileNames = { throw LookupFailed() }
        vm.refreshExistingProfileNames()
        XCTAssertNotNil(vm.profileNamesLoadError)
    }

    /// Wiring: completion re-reads the store, so a name taken since the profile step is refused
    /// and onboarding stays open.
    func testCompletionRefusesANameTakenSinceTheProfileStep() {
        let vm = makeViewModel()
        vm.fetchExistingProfileNames = { [] }
        vm.profileDisplayName = "Research"
        vm.refreshExistingProfileNames()
        XCTAssertNil(vm.profileNameProblem)

        vm.fetchExistingProfileNames = { ["Research"] }
        var completed = false
        vm.completeOnboarding(themeManager: ThemeManager()) { _ in completed = true }

        XCTAssertFalse(completed)
        XCTAssertTrue(vm.completionErrorMessage?.contains("already") == true)
    }

    // MARK: - Re-run

    func testTheThemeStepStartsFromTheUsersCurrentTheme() {
        let themeManager = ThemeManager()
        let vm = makeViewModel()
        vm.selectedThemeID = "not-the-current-theme"
        vm.selectedSurfaceStyle = themeManager.surfaceStyle == .solid ? .glassmorphic : .solid

        vm.adoptCurrentTheme(from: themeManager)

        XCTAssertEqual(vm.selectedThemeID, themeManager.baseTheme.id)
        XCTAssertEqual(vm.selectedAccentColor, themeManager.selectedAccentColor)
        XCTAssertEqual(vm.selectedSurfaceStyle, themeManager.surfaceStyle)
    }

    /// Wiring: the container adopts the theme on appear, and the app reloads its profile list when
    /// onboarding completes (the service outlives a re-run).
    func testTheRerunWiringIsInPlace() throws {
        let container = try source("Devgentic/Interfaces/Onboarding/Views/OnboardingContainerView.swift")
        guard let appear = container.range(of: ".onAppear {") else { return XCTFail("no onAppear") }
        XCTAssertTrue(container[appear.upperBound...].prefix(200).contains("viewModel.adoptCurrentTheme(from: themeManager)"),
                      "the container no longer adopts the current theme when it appears")

        let app = try source("Devgentic/DevgenticApp.swift")
        guard let onboarding = app.range(of: "OnboardingContainerView(onComplete: { createdProfileID in"),
              let reload = app.range(of: "OnboardingCompletion.apply(\n                            createdProfileID: createdProfileID,\n                            profileService: backendProfileService,", range: onboarding.upperBound..<app.endIndex),
              let flag = app.range(of: "isOnboardingComplete = true", range: onboarding.upperBound..<app.endIndex) else {
            return XCTFail("the onboarding completion no longer reloads profiles")
        }
        XCTAssertLessThan(reload.lowerBound, flag.lowerBound, "reload must happen inside the completion, before the switch")
    }

    /// A failed save must leave onboarding open, not land the user in the app with no profile.
    func testAFailedSaveReturnsBeforeOnboardingIsMarkedComplete() throws {
        let vmSource = try source("Devgentic/Interfaces/Onboarding/OnboardingViewModel.swift")
        guard let failure = vmSource.range(of: "completionErrorMessage = String(localized: \"Couldn't save your profile"),
              // The NEXT completion-flag write after the save error (cancelSetup has its own, earlier).
              let flag = vmSource.range(of: "TestHost.defaults.set(true, forKey: GlobalConstants.isOnboardingComplete)",
                                        range: failure.upperBound..<vmSource.endIndex) else {
            return XCTFail("completion sequence moved")
        }
        let between = vmSource[failure.upperBound..<flag.lowerBound]
        XCTAssertTrue(between.contains("return\n"), "the catch must return before the completion flag is set")
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
