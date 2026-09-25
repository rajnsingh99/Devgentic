// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
//
//  CodeProjectSessionTests.swift
//  DevgenticTests
//
//  One permanent Code profile, everything else per project (2026-09-24).
//
//  ⚠️ THE DEFECT. Home used to DELETE the Code profile row, and every per-tool setting and every
//  MCP tool enabled for Code lived on that row and nowhere else — so a Home press silently threw
//  them away. Now the row is reset, never deleted, and each project's model, tools and limits are
//  captured to `CodeQuickSettingsStore` when the project is left and loaded when it is reopened.
//
//  These drive the REAL `CodeSessionManager` against an in-memory store and a private defaults
//  suite, as `CodeProfileSingletonTests` does.
//

import XCTest
import SwiftData
@testable import devgentic

@MainActor
final class CodeProjectSessionTests: XCTestCase {

    private var container: ModelContainer!
    private var defaults: UserDefaults!
    private var suiteName: String!
    private var keychain: ProgrammableKeychain!
    private var root: URL!
    private var projectA: URL!
    private var projectB: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        container = try ModelContainer(
            for: BackendProfile.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
        BackendProfileStore.shared.configureContainer(container)

        // Private suite, never `.standard` — that is the shipping app's domain under the test host.
        suiteName = "CodeProjectSessionTests.\(UUID().uuidString)"
        defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))

        // Never the real Keychain: these tests write keys.
        keychain = ProgrammableKeychain()
        ProviderKeyStore.setStorageForTesting(keychain)

        // Real folders — `openProject(forConversationPath:)` checks the folder exists.
        root = FileManager.default.temporaryDirectory.appendingPathComponent("CodeProjectSessionTests-\(UUID().uuidString)")
        projectA = root.appendingPathComponent("project-a")
        projectB = root.appendingPathComponent("project-b")
        try FileManager.default.createDirectory(at: projectA, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: projectB, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        ProviderKeyStore.setStorageForTesting(nil)
        try? FileManager.default.removeItem(at: root)
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
        container = nil
        keychain = nil
        try super.tearDownWithError()
    }

    // MARK: - Fixtures

    private func selectModel(_ name: String, provider: ApiProvider = .ollama, key: String? = nil,
                             on manager: CodeSessionManager) {
        manager.updateProvider(provider)
        manager.updateModel(name, provider: provider, cognitiveProfile: .cloudNative,
                            apiKey: key, baseURL: nil, thinkingEnabled: false)
    }

    private func row(_ manager: CodeSessionManager) throws -> AgentConfig {
        let id = try XCTUnwrap(manager.codeProfileID)
        let profile = try XCTUnwrap(try BackendProfileStore.shared.fetchProfile(byId: id))
        guard case .code(let config) = profile.details else { throw XCTSkip("not a code row") }
        return config
    }

    /// What the Tool Library does: writes the Code row's tool list.
    private func editRowTools(_ manager: CodeSessionManager, _ edit: (inout [Tool]) -> Void) throws {
        let id = try XCTUnwrap(manager.codeProfileID)
        var profile = try XCTUnwrap(try BackendProfileStore.shared.fetchProfile(byId: id))
        guard case .code(var config) = profile.details else { return XCTFail("not a code row") }
        edit(&config.tools)
        profile.details = .code(config)
        try BackendProfileStore.shared.saveProfile(profile)
    }

    private let mcpTool = Tool(name: "github_search", description: "an MCP tool", sourceId: UUID(),
                               parameters: ToolParameters(type: "object", properties: [:], required: []))

    private func hasMCPTool(_ config: AgentConfig) -> Bool {
        config.tools.contains { $0.name == "github_search" }
    }

    // MARK: - Home resets, never deletes

    func testHomeKeepsTheOneProfileRow() throws {
        let manager = CodeSessionManager(defaults: defaults)
        manager.updateProjectPath(projectA)
        selectModel("qwen", on: manager)
        let id = try XCTUnwrap(manager.codeProfileID)

        manager.resetSession()

        XCTAssertEqual(manager.codeProfileID, id, "Home replaced the permanent profile")
        XCTAssertNotNil(try BackendProfileStore.shared.fetchProfile(byId: id), "Home deleted the row")
        XCTAssertNil(manager.projectPath, "Home must return to 'no folder'")
        XCTAssertNil(try row(manager).projectPath)
    }

    func testHomeResetsTheRowToThePreset() throws {
        let manager = CodeSessionManager(defaults: defaults)
        manager.updateProjectPath(projectA)
        selectModel("qwen", on: manager)
        try editRowTools(manager) { $0.append(mcpTool) }

        manager.resetSession()

        let config = try row(manager)
        XCTAssertEqual(Set(config.tools.map(\.name)), Set(CodeToolPreset.defaultTools.map(\.name)),
                       "the next session would start with the previous project's tools")
        XCTAssertEqual(config.maxIterations, CodeSessionManager.presetMaxIterations)
    }

    func testHomeKeepsTheModelAsTheLastUsed() throws {
        let manager = CodeSessionManager(defaults: defaults)
        manager.updateProjectPath(projectA)
        selectModel("qwen", on: manager)

        manager.resetSession()

        XCTAssertEqual(manager.modelName, "qwen")
        XCTAssertEqual(try row(manager).llmConfig.modelName, "qwen")
    }

    // MARK: - ⚠️⚠️ The reported defect: settings survive Home

    func testAToolEnabledForAProjectComesBackAfterHome() throws {
        let manager = CodeSessionManager(defaults: defaults)
        manager.updateProjectPath(projectA)
        selectModel("qwen", on: manager)
        try editRowTools(manager) { $0.append(mcpTool) }

        manager.resetSession()
        XCTAssertFalse(hasMCPTool(try row(manager)), "precondition: Home cleared the row")

        manager.updateProjectPath(projectA)
        XCTAssertTrue(hasMCPTool(try row(manager)), "the project's MCP tool was lost on Home")
    }

    func testAPresetToolsSettingsComeBackAfterHome() throws {
        let manager = CodeSessionManager(defaults: defaults)
        manager.updateProjectPath(projectA)
        selectModel("qwen", on: manager)
        try editRowTools(manager) { tools in
            guard let i = tools.firstIndex(where: { $0.name == "run_command" }) else { return }
            tools[i].timeout = 42
            tools[i].cutStrategy = .keepStart
            tools[i].isFavorite = true
        }

        manager.resetSession()
        manager.updateProjectPath(projectA)

        let tool = try XCTUnwrap(try row(manager).tools.first { $0.name == "run_command" })
        XCTAssertEqual(tool.timeout, 42)
        XCTAssertEqual(tool.cutStrategy, .keepStart)
        XCTAssertTrue(tool.isFavorite)
    }

    /// A setting cleared back to "none" must come back as none, not as the preset's value.
    func testAClearedTimeoutStaysCleared() throws {
        let preset = try XCTUnwrap(CodeToolPreset.defaultTools.first)
        var changed = preset
        changed.timeout = preset.timeout == nil ? 30 : nil
        let override = try XCTUnwrap(CodeToolOverride(preset: preset, current: changed))
        let decoded = try JSONDecoder().decode(CodeToolOverride.self, from: JSONEncoder().encode(override))
        XCTAssertEqual(decoded.applied(to: preset).timeout, changed.timeout)
    }

    // MARK: - Per project, no leaks

    func testAProjectsToolsDoNotLeakIntoAnotherProject() throws {
        let manager = CodeSessionManager(defaults: defaults)
        manager.updateProjectPath(projectA)
        selectModel("qwen", on: manager)
        try editRowTools(manager) { $0.append(mcpTool) }

        manager.updateProjectPath(projectB)
        XCTAssertFalse(hasMCPTool(try row(manager)), "project A's MCP tool leaked into project B")

        manager.updateProjectPath(projectA)
        XCTAssertTrue(hasMCPTool(try row(manager)), "project A's MCP tool did not come back")
    }

    /// Tools enabled on the welcome screen, before any folder, belong to the first project opened.
    func testToolsEnabledBeforeAFolderIsOpenAreKept() throws {
        let manager = CodeSessionManager(defaults: defaults)
        manager.ensureCodeProfile()
        selectModel("qwen", on: manager)
        try editRowTools(manager) { $0.append(mcpTool) }

        manager.updateProjectPath(projectA)

        XCTAssertTrue(hasMCPTool(try row(manager)))
    }

    func testEachProjectRemembersItsModel() throws {
        let manager = CodeSessionManager(defaults: defaults)
        manager.updateProjectPath(projectA)
        selectModel("model-a", on: manager)
        manager.updateProjectPath(projectB)
        selectModel("model-b", on: manager)

        manager.updateProjectPath(projectA)
        XCTAssertEqual(manager.modelName, "model-a")
        XCTAssertEqual(try row(manager).llmConfig.modelName, "model-a", "the cache and the row disagree")

        manager.updateProjectPath(projectB)
        XCTAssertEqual(manager.modelName, "model-b")
    }

    func testANewProjectStartsWithTheLastUsedModel() throws {
        let manager = CodeSessionManager(defaults: defaults)
        manager.updateProjectPath(projectA)
        selectModel("model-a", on: manager)

        manager.updateProjectPath(projectB)

        XCTAssertEqual(manager.modelName, "model-a")
    }

    // MARK: - Keys

    /// ⚠️ The profile holds ONE key. Without the per-provider slot, returning to an Anthropic
    /// project after an OpenAI one restores the model with no key, and the first send fails on auth.
    func testACloudKeyFollowsItsProjectAcrossProviders() throws {
        let manager = CodeSessionManager(defaults: defaults)
        manager.updateProjectPath(projectA)
        selectModel("claude-x", provider: .anthropic, key: "key-anthropic", on: manager)
        manager.updateProjectPath(projectB)
        selectModel("gpt-x", provider: .openAI, key: "key-openai", on: manager)

        manager.updateProjectPath(projectA)

        XCTAssertEqual(manager.provider, .anthropic)
        XCTAssertEqual(manager.apiKey, "key-anthropic")
        XCTAssertEqual(try row(manager).llmConfig.apiKey, "key-anthropic")
    }

    func testKeysNeverReachUserDefaults() throws {
        let manager = CodeSessionManager(defaults: defaults)
        manager.updateProjectPath(projectA)
        selectModel("claude-x", provider: .anthropic, key: "sk-secret-123", on: manager)
        manager.updateProjectPath(projectB)

        let blob = try XCTUnwrap(defaults.data(forKey: CodeQuickSettingsStore.defaultsKey))
        XCTAssertFalse(String(decoding: blob, as: UTF8.self).contains("sk-secret-123"),
                       "an API key was written to UserDefaults in plain text")
        XCTAssertEqual(CodeQuickSettingsStore.projectState(for: projectA.path, defaults: defaults)?.model?.modelName,
                       "claude-x", "premise: the model WAS remembered")
    }

    // MARK: - The popover's Reset

    /// "Reset" in quick settings resets the limits — it must not forget the project's model or tools.
    func testQuickSettingsResetKeepsTheProjectState() throws {
        let manager = CodeSessionManager(defaults: defaults)
        manager.updateProjectPath(projectA)
        selectModel("model-a", on: manager)
        var settings = CodeQuickSettings.default
        settings.maxIterations = 40
        manager.updateQuickSettings(settings)

        manager.updateQuickSettings(.default)

        XCTAssertEqual(CodeQuickSettingsStore.projectState(for: projectA.path, defaults: defaults)?.model?.modelName,
                       "model-a")
    }

    // MARK: - Conversations reopen their folder

    func testSelectingAConversationReopensItsFolder() {
        let manager = CodeSessionManager(defaults: defaults)
        manager.updateProjectPath(projectB)

        XCTAssertEqual(manager.openProject(forConversationPath: projectA.path), .restored)
        XCTAssertEqual(manager.projectPath?.standardizedFileURL.path, projectA.standardizedFileURL.path)
        XCTAssertEqual(manager.openProject(forConversationPath: projectA.path), .alreadyOpen)
    }

    func testAConversationWithoutAFolderLeavesTheOpenOne() {
        let manager = CodeSessionManager(defaults: defaults)
        manager.updateProjectPath(projectB)

        XCTAssertEqual(manager.openProject(forConversationPath: nil), .noRecordedFolder)
        XCTAssertEqual(manager.projectPath?.lastPathComponent, "project-b")
    }

    /// A moved or deleted folder must not be "opened" — the send gate then refuses, rather than
    /// the session carrying on inside whichever folder is open.
    func testAMissingFolderIsNotOpened() {
        let manager = CodeSessionManager(defaults: defaults)
        manager.updateProjectPath(projectB)

        let gone = root.appendingPathComponent("deleted-project").path
        XCTAssertEqual(manager.openProject(forConversationPath: gone), .folderMissing)
        XCTAssertEqual(manager.projectPath?.lastPathComponent, "project-b")
    }

    // MARK: - The conversation's folder is persisted

    func testTheStoreRecordsAConversationsFolder() throws {
        let chatContainer = try ModelContainer(
            for: ConversationSD.self, ChatMessageSD.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
        ChatPersistenceStore.shared.configureContainer(chatContainer)
        let conversation = ConversationSD()
        chatContainer.mainContext.insert(conversation)

        ChatPersistenceStore.shared.updateProjectPath(for: conversation.id, projectPath: projectA.path)

        XCTAssertEqual(ChatPersistenceStore.shared.getConversation(withId: conversation.id)?.projectPath, projectA.path)
    }
}

// MARK: - Sidebar grouping

final class CodeProjectGroupingTests: XCTestCase {

    private struct Session { let path: String?; let date: Date }
    private func at(_ seconds: TimeInterval) -> Date { Date(timeIntervalSince1970: seconds) }

    private func group(_ sessions: [Session], missing: Set<String> = []) -> [CodeProjectGrouping.Group<Session>] {
        CodeProjectGrouping.groups(sessions, path: \.path, date: \.date, folderExists: { !missing.contains($0) })
    }

    func testProjectsAreOrderedByTheirMostRecentSession() {
        let groups = group([
            Session(path: "/p/old", date: at(100)),
            Session(path: "/p/new", date: at(50)),
            Session(path: "/p/new", date: at(300)),
        ])
        XCTAssertEqual(groups.map(\.title), ["new", "old"])
        XCTAssertEqual(groups.first?.items.map(\.date), [at(300), at(50)], "sessions must be newest first")
    }

    func testNoProjectIsAlwaysLast() {
        let groups = group([
            Session(path: nil, date: at(999)),
            Session(path: "/p/a", date: at(1)),
        ])
        XCTAssertEqual(groups.map(\.path), ["/p/a", nil])
    }

    func testTheSameFolderWrittenTwoWaysIsOneProject() {
        let groups = group([
            Session(path: "/p/a/", date: at(1)),
            Session(path: "/p/x/../a", date: at(2)),
        ])
        XCTAssertEqual(groups.count, 1)
        XCTAssertEqual(groups.first?.items.count, 2)
    }

    func testAMissingFolderIsFlagged() {
        let groups = group([Session(path: "/p/gone", date: at(1))], missing: ["/p/gone"])
        XCTAssertEqual(groups.first?.isMissing, true)
    }
}

// MARK: - Wiring

/// ⚠️ Every test above passes with the app never calling any of it. These fail if a call site is cut.
final class CodeProjectWiringTests: XCTestCase {

    private func source(_ relative: String) throws -> String {
        // FOUR components: file → Code → Interfaces → DevgenticTests → root.
        var root = URL(fileURLWithPath: #filePath)
        for _ in 0..<4 { root = root.deletingLastPathComponent() }
        let url = root.appendingPathComponent(relative)
        try XCTSkipUnless(FileManager.default.fileExists(atPath: url.path), "running outside a checkout")
        return try String(contentsOf: url, encoding: .utf8)
            .components(separatedBy: "\n")
            .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
            .joined(separator: "\n")
    }

    func testHomeNoLongerDeletesTheProfile() throws {
        let code = try source("Devgentic/Interfaces/Code/CodeSessionManager.swift")
        let reset = try XCTUnwrap(code.range(of: "func resetSession()"))
        let body = code[reset.upperBound...].prefix(1500)
        XCTAssertFalse(body.contains("deleteProfile"), "Home deletes the Code profile again")
    }

    func testTheFirstSendBindsTheConversationToItsFolder() throws {
        let code = try source("Devgentic/Interfaces/Main/MessagingCoordinator.swift")
        XCTAssertTrue(code.contains("persistenceService.updateProjectPath(for: conversationIDToUse"))
    }

    func testSelectingAConversationReopensItsFolder() throws {
        let code = try source("Devgentic/Interfaces/Main/ConversationSwitchCoordinator.swift")
        XCTAssertTrue(code.contains("restoreCodeProjectForSelectedConversation()"))
    }

    func testTheComposerRoutesFolderPicksAndRefusesAMismatchedSend() throws {
        let code = try source("Devgentic/Interfaces/Shared/ChatInput/ChatInputAreaView.swift")
        XCTAssertTrue(code.contains("mainViewModel.codeSendRefusal(openFolder:"), "a session can run in another project's folder")
        XCTAssertTrue(code.contains("mainViewModel.chooseCodeFolder(url)"), "a folder pick re-points a bound session")
        let welcome = try source("Devgentic/Interfaces/Code/CodeDedicatedView.swift")
        XCTAssertTrue(welcome.contains("viewModel.chooseCodeFolder(url)"))
    }

    /// #1: a session is bound when it is CREATED with a folder open, and may be re-pointed while empty.
    func testASessionIsBoundAtCreationAndFollowsTheFolderWhileEmpty() throws {
        let code = try source("Devgentic/Interfaces/Main/ConversationManagementCoordinator.swift")
        XCTAssertTrue(code.contains("persistenceService.updateProjectPath(for: conversationID, projectPath: folder)"),
                      "a new session is not bound at creation — the sidebar lists it under 'No project'")
        XCTAssertTrue(code.contains("persistenceService.updateProjectPath(for: conversationID, projectPath: url.path)"),
                      "an empty session no longer follows a folder pick")
    }

    /// #2: every run passes through `startMessageStream`, which binds a Code run to its conversation.
    func testEveryRunIsBoundToItsConversationsProject() throws {
        let code = try source("Devgentic/Core/Utils/ActiveStreamManager.swift")
        XCTAssertTrue(code.contains("CodeSessionManager.profile("), "Code runs take the open project's profile again")
        // The condition too — a guard that never matches leaves the call in place and binds nothing.
        XCTAssertTrue(code.contains("let config = config.profile.profileType == .code"),
                      "the binding no longer applies to Code runs")
        XCTAssertTrue(code.contains("forConversationProject: persistenceService.getConversation(withId: conversationID)?.projectPath"))
    }

    /// #3: the switch decides unloading with the model-aware rule.
    func testTheSwitchUsesTheModelAwareUnloadRule() throws {
        let code = try source("Devgentic/Interfaces/Main/ConversationSwitchCoordinator.swift")
        XCTAssertTrue(code.contains("Self.shouldUnloadModels(codeModelBefore: codeModelBefore"))
        XCTAssertTrue(code.contains("let codeModelBefore = Self.codeModelKey(vm)"))
    }

    /// #5: the combined roots publish is queued BEFORE the Explorer's own.
    func testOpeningAProjectPublishesRootsOnce() throws {
        let code = try source("Devgentic/Interfaces/Main/ConversationManagementCoordinator.swift")
        let combined = try XCTUnwrap(code.range(of: "Task { await MCPRootsProvider.setWorkspace(url) }"))
        let explorer = try XCTUnwrap(code.range(of: "vm.explorerViewModel.selectedRootURL = url"))
        XCTAssertLessThan(combined.lowerBound, explorer.lowerBound,
                          "the Explorer's publish is queued first, so a switch notifies servers twice")
    }

    /// #7: new-session reuse goes through the mode- and project-aware rule.
    func testEmptyConversationReuseUsesTheRule() throws {
        let code = try source("Devgentic/Interfaces/Main/ConversationManagementCoordinator.swift")
        XCTAssertTrue(code.contains("Self.isReusableEmptyConversation(profileTypeRaw: $0.profileTypeRaw, projectPath: $0.projectPath,"),
                      "any recent empty conversation can be taken over again")
    }

    /// #6: the Tool Library shows the project for the Code profile.
    func testTheToolLibraryShowsTheProject() throws {
        let code = try source("Devgentic/Interfaces/Main/Views/ToolLibraryContainerView.swift")
        XCTAssertTrue(code.contains("Text(profileLabel)"), "the Library label is a bare profile name again")
        XCTAssertTrue(code.contains("Self.codeScopeLabel(profileName: profile.displayName, projectFolder: codeSessionManager.projectPath)"))
        XCTAssertTrue(code.contains("Self.codeScopeHelp(projectFolder: codeSessionManager.projectPath)"))
    }

    func testTheSidebarGroupsCodeByProject() throws {
        let code = try source("Devgentic/Interfaces/Main/Views/Conversation/ConversationSidebarView.swift")
        XCTAssertTrue(code.contains("CodeProjectGrouping.groups(codeSessions"))
        XCTAssertTrue(code.contains("viewModel.startNewCodeSession(in:"))
    }
}
