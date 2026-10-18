// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
//
//  CodeQuickSettingsTests.swift
//  DevgenticTests
//
//  Created by Raj Singh.
//

import XCTest
import SwiftData
@testable import devgentic

@MainActor
final class CodeQuickSettingsTests: XCTestCase {

    private var container: ModelContainer!
    private var defaults: UserDefaults!
    private var suiteName: String!
    private var projectA: URL!
    private var projectB: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()

        container = try ModelContainer(
            for: BackendProfile.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
        BackendProfileStore.shared.configureContainer(container)

        // A private suite, never `.standard` — under the test host that IS the shipping app's
        // domain, so this would rewrite the developer's own settings. Same reason as
        // `CodeProfileSingletonTests`.
        suiteName = "CodeQuickSettingsTests.\(UUID().uuidString)"
        defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))

        projectA = URL(fileURLWithPath: "/tmp/devgentic-tests/project-a")
        projectB = URL(fileURLWithPath: "/tmp/devgentic-tests/project-b")
    }

    override func tearDownWithError() throws {
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
        suiteName = nil
        container = nil
        projectA = nil
        projectB = nil
        try super.tearDownWithError()
    }

    /// Selects a model on the manager.
    ///
    /// ⚠️ Required, not incidental: `BackendProfileStore.saveProfile` rejects a profile with no
    /// model ("A model must be selected"), so `refreshInstructionsOnProfile()` silently writes
    /// nothing without one. A real send cannot reach that code path modelless either —
    /// `ChatInputAreaView.attemptSend` intercepts on `modelName.isEmpty` — so a test without a
    /// model is testing a state the app never sends in.
    private func selectModel(on manager: CodeSessionManager) {
        manager.updateModel(
            "qwen2.5-coder:7b",
            provider: .ollama,
            cognitiveProfile: CognitiveProfile(capability: .parallelActions, dialect: .heuristicJson),
            apiKey: nil,
            baseURL: nil,
            thinkingEnabled: false
        )
    }

    // MARK: - Scope: per project

    func testSettingsAreScopedToTheirProject() {
        var a = CodeQuickSettings.default
        a.maxIterations = 45
        CodeQuickSettingsStore.save(a, for: projectA.path, defaults: defaults, now: Date())

        let readA = CodeQuickSettingsStore.settings(for: projectA.path, defaults: defaults)
        let readB = CodeQuickSettingsStore.settings(for: projectB.path, defaults: defaults)

        XCTAssertEqual(readA.maxIterations, 45)

        XCTAssertEqual(readB, .default,
                       "Project B inherited project A's settings.")
    }

    func testTrailingSlashIsTheSameProject() {
        var settings = CodeQuickSettings.default
        settings.maxIterations = 33
        CodeQuickSettingsStore.save(settings, for: projectA.path, defaults: defaults, now: Date())

        let viaSlash = CodeQuickSettingsStore.settings(for: projectA.path + "/", defaults: defaults)

        XCTAssertEqual(viaSlash.maxIterations, 33,
                       "A trailing slash keyed a second entry for the same folder, so the same "
                       + "project would show different settings depending on how its path was built.")
    }

    func testNoProjectPathYieldsDefaults() {
        XCTAssertEqual(CodeQuickSettingsStore.settings(for: nil, defaults: defaults), .default)
        XCTAssertEqual(CodeQuickSettingsStore.settings(for: "  ", defaults: defaults), .default)
    }

    // MARK: - Applying onto AgentConfig

    private func agentConfig() -> AgentConfig {
        AgentConfig(
            llmConfig: ProviderConfig(apiProvider: .ollama, modelName: "qwen2.5-coder:7b"),
            tools: CodeToolPreset.defaultTools,
            maxIterations: 20,
            executionTimeout: 300
        )
    }

    func testApplyMapsEveryFieldOntoTheConfig() {
        var settings = CodeQuickSettings.default
        settings.maxIterations = 60
        settings.executionTimeout = 900
        settings.thinkingEnabled = true

        var config = agentConfig()
        CodeSessionManager.apply(settings, to: &config)

        XCTAssertEqual(config.maxIterations, 60)
        XCTAssertEqual(config.executionTimeout, 900)
        XCTAssertTrue(config.llmConfig.thinkingEnabled)
    }

    func testUnsetFieldsRestoreThePreset() {
        // `nil` means "inherit the preset" — and it must ASSIGN that preset, not skip.
        var config = agentConfig()
        CodeSessionManager.apply(.default, to: &config)

        XCTAssertEqual(config.maxIterations, CodeSessionManager.presetMaxIterations)
        XCTAssertEqual(config.executionTimeout, CodeSessionManager.presetExecutionTimeout)
        XCTAssertFalse(config.llmConfig.thinkingEnabled)
    }

    func testClearingAnOverrideRestoresThePreset() {
        // ⚠️⚠️ THE ONE-WAY DOOR. `apply` used to skip on nil, so this sequence was unrecoverable:
        // the user pressed Remove in the limits panel (stored 0 → written as nil = unbounded), then
        // reset the setting back to "inherit", and nothing ever rewrote 300 s. A run observed
        // 2026-09-20 logged "[EXEC_LIMITS] No execution timeout configured" from exactly this.
        var config = agentConfig()

        var noLimit = CodeQuickSettings.default
        noLimit.executionTimeout = 0
        CodeSessionManager.apply(noLimit, to: &config)
        XCTAssertNil(config.executionTimeout, "0 must mean explicitly unbounded.")

        CodeSessionManager.apply(.default, to: &config)
        XCTAssertEqual(config.executionTimeout, CodeSessionManager.presetExecutionTimeout,
                       "Clearing the override must restore the preset budget. Without this, "
                       + "'Reset to defaults' silently leaves the run unbounded forever.")
    }

    func testLoweringThenClearingMaxIterationsRestoresThePreset() {
        var config = agentConfig()
        var raised = CodeQuickSettings.default
        raised.maxIterations = 60
        CodeSessionManager.apply(raised, to: &config)
        XCTAssertEqual(config.maxIterations, 60)

        CodeSessionManager.apply(.default, to: &config)
        XCTAssertEqual(config.maxIterations, CodeSessionManager.presetMaxIterations)
    }

    func testApplyIsIdempotent() {
        // Applying twice must not drift — the per-send hook runs it on every message.
        var a = agentConfig(), b = agentConfig()
        var s = CodeQuickSettings.default
        s.maxIterations = 42
        s.executionTimeout = 900
        CodeSessionManager.apply(s, to: &a)
        CodeSessionManager.apply(s, to: &b)
        CodeSessionManager.apply(s, to: &b)

        XCTAssertEqual(a.maxIterations, b.maxIterations)
        XCTAssertEqual(a.executionTimeout, b.executionTimeout)
    }

    func testZeroTimeoutMeansNoLimitNotInstantTimeout() {
        // The UI's "Remove" stores 0. If that reached the config as `.some(0)` the sentinel would
        // fire immediately and every run would die at once.
        var settings = CodeQuickSettings.default
        settings.executionTimeout = 0

        var config = agentConfig()
        CodeSessionManager.apply(settings, to: &config)

        XCTAssertNil(config.executionTimeout,
                     "A 0 timeout must become nil (unbounded), never a zero-second budget.")
    }

    /// Ask/Auto is set in the Tool Library now (2026-09-25), on the profile's tool. Applying the
    /// quick settings must carry it through untouched — this popover no longer has an opinion.
    func testApplyKeepsTheAskAutoChoiceTheLibraryMade() {
        var config = agentConfig()
        let idx = try? XCTUnwrap(config.tools.firstIndex { $0.name == "edit_code_single" })
        guard let idx else { return XCTFail("edit_code_single missing from the preset") }
        config.tools[idx].requiresConfirmation = false

        CodeSessionManager.apply(.default, to: &config)

        XCTAssertEqual(config.tools.first { $0.name == "edit_code_single" }?.requiresConfirmation, false,
                       "applying the quick settings overwrote the Tool Library's Auto Run choice")
    }

    func testApplyKeepsEveryPresetTool() {
        var config = agentConfig()
        CodeSessionManager.apply(.default, to: &config)

        XCTAssertEqual(Set(config.tools.map(\.name)),
                       Set(CodeToolPreset.defaultTools.map(\.name)),
                       "Applying settings dropped or added a preset tool.")
    }

    // MARK: - ⚠️⚠️ The reason storage is not on the profile

    func testSettingsSurviveResetSession() throws {
        let manager = CodeSessionManager(defaults: defaults)
        manager.updateProjectPath(projectA)
        _ = manager.ensureCodeProfile()
        selectModel(on: manager)

        var settings = CodeQuickSettings.default
        settings.maxIterations = 50
        manager.updateQuickSettings(settings)

        // The Home button. Resets the row to the preset — see `CodeProjectSessionTests`.
        manager.resetSession()

        manager.updateProjectPath(projectA)
        let newProfileID = manager.ensureCodeProfile()
        selectModel(on: manager)

        XCTAssertEqual(manager.quickSettings.maxIterations, 50,
                       "The iteration cap did not survive a Home press. This is the whole reason "
                       + "quick settings live in UserDefaults instead of on the profile row.")

        // And they must reach the freshly minted profile, not just the store.
        manager.refreshInstructionsOnProfile()
        let profile = try XCTUnwrap(try BackendProfileStore.shared.fetchProfile(byId: newProfileID))
        guard case .code(let config) = profile.details else {
            return XCTFail("Expected a .code profile")
        }

        XCTAssertEqual(config.maxIterations, 50,
                       "Settings survived in UserDefaults but never reached the new profile — the "
                       + "run would still use the hardcoded 20.")
    }

    func testSettingsReachTheProfileOnEverySend() throws {
        // `refreshInstructionsOnProfile()` is the per-send hook. If settings are not applied there,
        // a change made between sends never takes effect.
        let manager = CodeSessionManager(defaults: defaults)
        manager.updateProjectPath(projectA)
        let profileID = manager.ensureCodeProfile()
        selectModel(on: manager)

        var settings = CodeQuickSettings.default
        settings.maxIterations = 77
        CodeQuickSettingsStore.save(settings, for: projectA.path, defaults: defaults, now: Date())

        manager.refreshInstructionsOnProfile()

        let profile = try XCTUnwrap(try BackendProfileStore.shared.fetchProfile(byId: profileID))
        guard case .code(let config) = profile.details else {
            return XCTFail("Expected a .code profile")
        }
        XCTAssertEqual(config.maxIterations, 77)
    }

    func testSwitchingProjectSwitchesSettings() {
        let manager = CodeSessionManager(defaults: defaults)

        manager.updateProjectPath(projectA)
        var a = CodeQuickSettings.default
        a.maxIterations = 40
        manager.updateQuickSettings(a)

        manager.updateProjectPath(projectB)

        XCTAssertEqual(manager.quickSettings, .default,
                       "Switching project carried the previous project's settings across.")

        manager.updateProjectPath(projectA)
        XCTAssertEqual(manager.quickSettings.maxIterations, 40,
                       "Returning to a configured project did not restore its settings.")
    }

    // MARK: - Housekeeping

    func testResettingToDefaultsRemovesTheEntry() {
        var settings = CodeQuickSettings.default
        settings.maxIterations = 25
        CodeQuickSettingsStore.save(settings, for: projectA.path, defaults: defaults, now: Date())
        CodeQuickSettingsStore.save(.default, for: projectA.path, defaults: defaults, now: Date())

        XCTAssertEqual(CodeQuickSettingsStore.settings(for: projectA.path, defaults: defaults), .default)
    }

    func testIsDefaultTracksEveryField() {
        XCTAssertTrue(CodeQuickSettings.default.isDefault)

        var s = CodeQuickSettings.default
        s.maxIterations = 20
        XCTAssertFalse(s.isDefault, "maxIterations is not counted by isDefault.")

        s = .default; s.executionTimeout = 300
        XCTAssertFalse(s.isDefault, "executionTimeout is not counted by isDefault.")

        s = .default; s.thinkingEnabled = false
        XCTAssertFalse(s.isDefault, "thinkingEnabled is not counted by isDefault.")

        s = .default; s.contextTokens = 16_384
        XCTAssertFalse(s.isDefault, "contextTokens is not counted by isDefault.")
    }

    func testRetentionCapKeepsTheMostRecentlyChangedProjects() {
        let overflow = CodeQuickSettingsStore.maxRetainedProjects + 10
        let base = Date(timeIntervalSince1970: 1_700_000_000)

        for i in 0..<overflow {
            var s = CodeQuickSettings.default
            s.maxIterations = i + 3
            CodeQuickSettingsStore.save(
                s,
                for: "/tmp/devgentic-tests/p\(i)",
                defaults: defaults,
                now: base.addingTimeInterval(Double(i))
            )
        }

        // Oldest evicted, newest kept.
        XCTAssertEqual(CodeQuickSettingsStore.settings(for: "/tmp/devgentic-tests/p0", defaults: defaults),
                       .default, "The oldest project should have been pruned.")
        XCTAssertEqual(
            CodeQuickSettingsStore.settings(for: "/tmp/devgentic-tests/p\(overflow - 1)", defaults: defaults).maxIterations,
            overflow + 2,
            "The most recently changed project was pruned."
        )
    }

    func testCorruptStoredBlobFallsBackWithoutDestroyingIt() {
        defaults.set(Data("not json".utf8), forKey: CodeQuickSettingsStore.defaultsKey)

        XCTAssertEqual(CodeQuickSettingsStore.settings(for: projectA.path, defaults: defaults), .default,
                       "An unreadable blob must degrade to defaults, not crash.")
        XCTAssertNotNil(defaults.data(forKey: CodeQuickSettingsStore.defaultsKey),
                        "The unreadable blob was deleted on a READ path. A later build that "
                        + "understands it could have recovered it; clearing it makes the loss permanent.")
    }
}
