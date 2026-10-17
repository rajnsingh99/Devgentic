// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
//
//  CodeProjectFollowUpTests.swift
//  DevgenticTests
//
//  Gaps found on device 2026-09-24 after the permanent-profile change:
//    #2 a run started for a conversation (wake, scheduler, resume) took the OPEN project's profile
//    #3 model unloading was decided by profile, and every Code session shares one
//    #4 unchanged settings still rewrote the profile row
//    #5 MCP servers saw both projects' folders for a moment on every switch
//  (#1, binding a session at creation, is wiring-only — see `CodeProjectWiringTests`.)
//

import XCTest
import SwiftData
@testable import devgentic

// MARK: - #2 A run uses its conversation's project

@MainActor
final class CodeRunProjectBindingTests: XCTestCase {

    private var defaults: UserDefaults!
    private var suiteName: String!
    private var root: URL!
    private var projectA: URL!
    private var projectB: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        suiteName = "CodeRunProjectBindingTests.\(UUID().uuidString)"
        defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        ProviderKeyStore.setStorageForTesting(ProgrammableKeychain())
        root = FileManager.default.temporaryDirectory.appendingPathComponent("CodeRunBinding-\(UUID().uuidString)")
        projectA = root.appendingPathComponent("project-a")
        projectB = root.appendingPathComponent("project-b")
        for dir in [projectA!, projectB!] {
            try FileManager.default.createDirectory(at: dir.appendingPathComponent(".devgentic"), withIntermediateDirectories: true)
        }
        try "B-PROJECT-CONTEXT".write(to: projectB.appendingPathComponent("AGENTS.md"), atomically: true, encoding: .utf8)
    }

    override func tearDownWithError() throws {
        ProviderKeyStore.setStorageForTesting(nil)
        try? FileManager.default.removeItem(at: root)
        defaults.removePersistentDomain(forName: suiteName)
        try super.tearDownWithError()
    }

    private let mcpTool = Tool(name: "github_search", description: "", sourceId: UUID(),
                               parameters: ToolParameters(type: "object", properties: [:], required: []))

    /// The shared row as it stands with project A open.
    private func rowWithAOpen() -> BackendProfileSnapshot {
        var config = AgentConfig(llmConfig: ProviderConfig(apiProvider: .ollama, modelName: "model-a"),
                                 tools: CodeToolPreset.defaultTools + [mcpTool], historyStrategy: .pointer)
        config.projectPath = projectA.path
        config.instructions = "PROMPT FOR A"
        config.maxIterations = 20
        return BackendProfileSnapshot(displayName: "Code Session", details: .code(config))
    }

    private func config(_ profile: BackendProfileSnapshot) throws -> AgentConfig {
        guard case .code(let config) = profile.details else { throw XCTSkip("not code") }
        return config
    }

    /// ⚠️ THE DEFECT. A wake for a B conversation while A is open got A's folder and prompt.
    func testARunForAnotherProjectGetsThatProjectsFolderAndPrompt() throws {
        let bound = CodeSessionManager.profile(rowWithAOpen(), forConversationProject: projectB.path, defaults: defaults)
        let config = try config(bound)

        XCTAssertEqual(config.projectPath, projectB.standardizedFileURL.path)
        XCTAssertTrue(config.instructions?.contains(projectB.standardizedFileURL.path) ?? false,
                      "the prompt still names the open project's folder")
        XCTAssertFalse(config.instructions?.contains("PROMPT FOR A") ?? true)
        // The project's own knowledge is appended when the run starts, from the bound folder.
        let knowledge = AgentConnect.codeProjectKnowledge(config, traceTag: "test")
        XCTAssertTrue(knowledge?.contains("B-PROJECT-CONTEXT") ?? false, "B's AGENTS.md did not reach the run's prompt")
    }

    func testARunForAnotherProjectGetsThatProjectsToolsLimitsAndModel() throws {
        var state = CodeProjectState()
        state.model = ProviderConfig(apiProvider: .ollama, modelName: "model-b")
        CodeQuickSettingsStore.saveProjectState(state, for: projectB.path, defaults: defaults, now: Date())
        var settings = CodeQuickSettings.default
        settings.maxIterations = 33
        CodeQuickSettingsStore.save(settings, for: projectB.path, defaults: defaults, now: Date())

        let config = try config(CodeSessionManager.profile(rowWithAOpen(), forConversationProject: projectB.path, defaults: defaults))

        XCTAssertEqual(config.llmConfig.modelName, "model-b")
        XCTAssertEqual(config.maxIterations, 33)
        XCTAssertFalse(config.tools.contains { $0.name == "github_search" }, "A's MCP tool leaked into B's run")
    }

    /// A project never captured gets the preset — never the open project's extra tools.
    func testANeverCapturedProjectGetsThePresetNotTheOpenProjectsTools() throws {
        let config = try config(CodeSessionManager.profile(rowWithAOpen(), forConversationProject: projectB.path, defaults: defaults))
        XCTAssertEqual(Set(config.tools.map(\.name)), Set(CodeToolPreset.defaultTools.map(\.name)))
    }

    /// Every composer send: the conversation's folder IS the open one. Nothing may change.
    func testTheOpenProjectIsLeftExactlyAsIs() {
        let row = rowWithAOpen()
        XCTAssertEqual(CodeSessionManager.profile(row, forConversationProject: projectA.path + "/", defaults: defaults), row)
    }

    func testUnboundAndNonCodeProfilesAreUntouched() {
        let row = rowWithAOpen()
        XCTAssertEqual(CodeSessionManager.profile(row, forConversationProject: nil, defaults: defaults), row)
        let bot = BackendProfileSnapshot(displayName: "Bot", details: .bot(BotConfig(llmConfig: ProviderConfig(apiProvider: .mlx, modelName: "m"))))
        XCTAssertEqual(CodeSessionManager.profile(bot, forConversationProject: projectB.path, defaults: defaults), bot)
    }

    /// A deleted folder must not fall back to the open project.
    func testAMissingFolderStillBindsTheRunToIt() throws {
        let gone = root.appendingPathComponent("deleted").path
        let config = try config(CodeSessionManager.profile(rowWithAOpen(), forConversationProject: gone, defaults: defaults))
        XCTAssertEqual(config.projectPath, gone)
    }
}

// MARK: - #3 Unload by model in Code — SUPERSEDED
//
// The model-aware switch-unload rule (`ConversationSwitchCoordinator.shouldUnloadModels`) is gone: a
// conversation switch unloads nothing (local inference coordinator, decision D10). The on-device
// complaints it answered — two Code projects on different models both staying resident, and a fresh
// session unloading the model its next send needed — are answered by residency at lock handover:
// the next run to take the local lock unloads what it does not use, and only then. Pinned by
// `LocalResidencyWiringTests.testAConversationSwitchUnloadsNothing`.

// MARK: - #4 No write when nothing changed

@MainActor
final class CodeRedundantWriteTests: XCTestCase {

    private var container: ModelContainer!
    private var defaults: UserDefaults!
    private var suiteName: String!
    private var root: URL!
    private var project: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        container = try ModelContainer(for: BackendProfile.self, configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        BackendProfileStore.shared.configureContainer(container)
        suiteName = "CodeRedundantWriteTests.\(UUID().uuidString)"
        defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        root = FileManager.default.temporaryDirectory.appendingPathComponent("CodeRedundant-\(UUID().uuidString)")
        project = root.appendingPathComponent("p")
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
        defaults.removePersistentDomain(forName: suiteName)
        container = nil
        try super.tearDownWithError()
    }

    private func pickModel(_ manager: CodeSessionManager) {
        manager.updateModel("qwen", provider: .ollama,
                            cognitiveProfile: CognitiveProfile(capability: .parallelActions, dialect: .heuristicJson),
                            apiKey: nil, baseURL: nil, thinkingEnabled: false)
    }

    private func configured() -> CodeSessionManager {
        let manager = CodeSessionManager(defaults: defaults)
        pickModel(manager)
        manager.updateProjectPath(project)
        return manager
    }

    private func stamp(_ manager: CodeSessionManager) throws -> Date? {
        try XCTUnwrap(BackendProfileStore.shared.fetchProfile(byId: XCTUnwrap(manager.codeProfileID))).lastSelected
    }

    func testReopeningTheSameFolderDoesNotWrite() throws {
        let manager = configured()
        let before = try stamp(manager)
        manager.updateProjectPath(project)
        XCTAssertEqual(try stamp(manager), before)
    }

    /// The popover commits on open and on close with the stored values.
    func testQuickSettingsCommittedUnchangedDoNotWrite() throws {
        let manager = configured()
        let before = try stamp(manager)
        manager.updateQuickSettings(manager.quickSettings)
        XCTAssertEqual(try stamp(manager), before)
    }

    func testRePickingTheSameModelDoesNotWrite() throws {
        let manager = configured()
        let before = try stamp(manager)
        pickModel(manager)
        XCTAssertEqual(try stamp(manager), before)
    }

    /// The guard must not swallow a real change.
    func testARealQuickSettingChangeStillWrites() throws {
        let manager = configured()
        let before = try stamp(manager)
        var settings = manager.quickSettings
        settings.maxIterations = 42
        manager.updateQuickSettings(settings)
        XCTAssertNotEqual(try stamp(manager), before)
        let config = try XCTUnwrap(BackendProfileStore.shared.fetchProfile(byId: XCTUnwrap(manager.codeProfileID))).details.agentConfig
        XCTAssertEqual(config?.maxIterations, 42)
    }
}

// MARK: - #5 One roots notification per switch

@MainActor
final class CodeWorkspaceRootsTests: XCTestCase {

    private var root: URL!

    override func setUp() async throws {
        try await super.setUp()
        root = FileManager.default.temporaryDirectory.appendingPathComponent("CodeRoots-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root.appendingPathComponent("a"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("b"), withIntermediateDirectories: true)
        await MCPRootsProvider.setCodeProjectRoot(nil)
        await MCPRootsProvider.setExplorerRoot(nil)
    }

    override func tearDown() async throws {
        await MCPRootsProvider.setCodeProjectRoot(nil)
        await MCPRootsProvider.setExplorerRoot(nil)
        try? FileManager.default.removeItem(at: root)
        try await super.tearDown()
    }

    /// ⚠️ Seen on device: every switch published [A, B] then [B] — two notifications, and a moment
    /// in which a server's boundary included the project just left.
    func testASwitchPublishesOnceAndNeverBothProjects() async {
        let a = root.appendingPathComponent("a"), b = root.appendingPathComponent("b")
        // Both slots on A, set the ordinary way — the state a switch starts from.
        await MCPRootsProvider.setCodeProjectRoot(a)
        await MCPRootsProvider.setExplorerRoot(a)
        let start = MCPRootsProvider.publishCount

        // What a switch does: the combined call first, then each slot's own publish.
        await MCPRootsProvider.setWorkspace(b)
        await MCPRootsProvider.setExplorerRoot(b)
        await MCPRootsProvider.setCodeProjectRoot(b)

        XCTAssertEqual(MCPRootsProvider.publishCount - start, 1, "a project switch notified servers more than once")
        XCTAssertEqual(MCPRootsProvider.roots.map(\.lastPathComponent), ["b"])
    }
}

// MARK: - #7 "+" reuses only an empty session that belongs here

final class EmptyConversationReuseTests: XCTestCase {

    private let code = ProfileType.code.rawValue
    private let workflow = ProfileType.workflow.rawValue

    private func reusable(_ raw: String?, _ path: String?, _ mode: MainApplicationViewModel.InterfaceMode,
                          open: String? = "/p/a") -> Bool {
        ConversationManagementCoordinator.isReusableEmptyConversation(profileTypeRaw: raw, projectPath: path, mode: mode, openFolder: open)
    }

    func testCodeReusesItsOwnProjectsEmptySession() {
        XCTAssertTrue(reusable(code, "/p/a/", .code))
        XCTAssertTrue(reusable(code, nil, .code), "an unbound empty Code session is free to take")
    }

    /// ⚠️ Seen on device: "+" in one project could take another project's empty session.
    func testCodeNeverTakesAnotherProjectsSession() {
        XCTAssertFalse(reusable(code, "/p/b", .code))
    }

    func testCodeNeverTakesAChatOrWorkflowConversation() {
        XCTAssertFalse(reusable(nil, nil, .code))
        XCTAssertFalse(reusable(workflow, nil, .code))
    }

    func testChatAndWorkflowKeepToTheirOwn() {
        XCTAssertTrue(reusable(nil, nil, .chat))
        XCTAssertFalse(reusable(code, "/p/a", .chat), "Chat took an empty Code session")
        XCTAssertFalse(reusable(workflow, nil, .chat))
        XCTAssertTrue(reusable(workflow, nil, .workflow))
        XCTAssertFalse(reusable(code, nil, .workflow))
    }
}

// MARK: - #6 The Tool Library names the project it edits

@MainActor
final class ToolLibraryCodeScopeTests: XCTestCase {

    func testTheLabelNamesTheOpenProject() {
        XCTAssertEqual(ToolLibraryContainerView.codeScopeLabel(profileName: "Code Session",
                                                               projectFolder: URL(fileURLWithPath: "/w/Devgentic")),
                       "Code Session · Devgentic")
    }

    func testWithNoFolderTheLabelSaysSo() {
        XCTAssertTrue(ToolLibraryContainerView.codeScopeLabel(profileName: "Code Session", projectFolder: nil)
            .hasSuffix("No Project Selected"))
    }

    func testTheHelpSaysWhereChangesGo() {
        XCTAssertTrue(ToolLibraryContainerView.codeScopeHelp(projectFolder: URL(fileURLWithPath: "/w/java")).contains("java"))
        XCTAssertTrue(ToolLibraryContainerView.codeScopeHelp(projectFolder: nil).contains("next project"))
    }
}
