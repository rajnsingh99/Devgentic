// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
//
//  LiveModelDetectionTests.swift
//  DevgenticTests
//
//  Created by Raj Singh.
//

import XCTest
@testable import devgentic

@MainActor
final class LiveModelDetectionTests: XCTestCase {

    private var savedModels: [LocalModel] = []

    override func setUp() {
        super.setUp()
        savedModels = OllamaService.shared.localModels
        LiveModelDetection.resetForTesting()
    }

    override func tearDown() {
        OllamaService.shared.localModels = savedModels
        LiveModelDetection.resetForTesting()
        super.tearDown()
    }

    private func ollamaModel(_ name: String, capabilities: [String]) -> LocalModel {
        LocalModel(name: name, response: OllamaShowResponse(
            license: nil, modelfile: nil, parameters: nil, template: nil,
            details: nil, capabilities: capabilities, modelInfo: nil))
    }

    private func agent(_ config: ProviderConfig) -> BackendProfileModel {
        BackendProfileSnapshot(displayName: "Local", details: .agent(AgentConfig(llmConfig: config, tools: [])))
    }

    private func toolCapable() -> LocalModel { ollamaModel("llama3.1:8b", capabilities: ["completion", "tools"]) }

    // MARK: - Runs use the detected value

    /// ⚠️ THE ONBOARDING SHAPE: a profile stored with the bare defaults (Text Only) for a model
    /// that can call tools. Before, its runs took the text-only prompted path.
    func testAStaleTextOnlyProfileRunsWithTheDetectedCapability() async {
        let model = toolCapable()
        XCTAssertNotEqual(model.cognitiveCapability, ModelCognitiveCapability.none, "precondition: the fixture is tool-capable")
        OllamaService.shared.localModels = [model]

        let stored = ProviderConfig(apiProvider: .ollama, modelName: "llama3.1:8b")
        XCTAssertEqual(stored.cognitiveCapability, ModelCognitiveCapability.none, "precondition: stored as Text Only")

        let resolved = await LiveModelDetection.resolving(agent(stored))
        XCTAssertEqual(resolved.details.llmProviderConfig?.cognitiveCapability, model.cognitiveCapability)
        XCTAssertEqual(resolved.details.llmProviderConfig?.modelDialect, model.modelDialect)
    }

    /// The reverse matters just as much: a stored "Parallel Actions" for a model that cannot call
    /// tools (a typed name that kept the previous model's values) must not be trusted.
    func testAStoredCapabilityTheModelLacksIsCorrected() async {
        OllamaService.shared.localModels = [ollamaModel("plain:7b", capabilities: ["completion"])]
        var stored = ProviderConfig(apiProvider: .ollama, modelName: "plain:7b")
        stored.cognitiveCapability = .parallelActions

        let resolved = await LiveModelDetection.resolving(agent(stored))
        XCTAssertEqual(resolved.details.llmProviderConfig?.cognitiveCapability, ModelCognitiveCapability.none)
    }

    func testAnUntaggedNameMatchesLatest() {
        OllamaService.shared.localModels = [ollamaModel("mistral:latest", capabilities: ["completion", "tools"])]
        XCTAssertNotNil(LiveModelDetection.detectedFromCache(ProviderConfig(apiProvider: .ollama, modelName: "mistral")))
    }

    /// A model the lookup cannot find keeps the stored values — never a guessed default.
    func testAnUnknownModelKeepsTheStoredValues() async {
        OllamaService.shared.localModels = [toolCapable()]
        var stored = ProviderConfig(apiProvider: .ollama, modelName: "not-installed:1b")
        stored.cognitiveCapability = .singleAction

        let profile = agent(stored)
        let resolved = await LiveModelDetection.resolving(profile)
        XCTAssertEqual(resolved, profile)
    }

    func testCloudProfilesAreUntouched() async {
        var stored = ProviderConfig(apiProvider: .anthropic, modelName: "claude-opus-5")
        stored.cognitiveCapability = .none
        let profile = agent(stored)
        let resolved = await LiveModelDetection.resolving(profile)
        XCTAssertEqual(resolved, profile, "cloud runs never consult the capability; nothing to resolve")
    }

    /// Measurements only — a preference the user set survives.
    func testAUserPreferenceIsNeverOverwritten() async {
        OllamaService.shared.localModels = [toolCapable()]
        var stored = ProviderConfig(apiProvider: .ollama, modelName: "llama3.1:8b")
        stored.thinkingEnabled = true
        let resolved = await LiveModelDetection.resolving(agent(stored))
        XCTAssertEqual(resolved.details.llmProviderConfig?.thinkingEnabled, true)
    }

    // MARK: - The editor

    /// A detection refresh alone must not light Save; a real model change must.
    func testADetectionRefreshIsNotAnUnsavedEdit() {
        let profile = agent(ProviderConfig(apiProvider: .ollama, modelName: "llama3.1:8b"))
        let buffer = ProfileEditBuffer(profile: profile)

        var refreshed = profile.details.llmProviderConfig!
        refreshed.cognitiveCapability = .parallelActions
        refreshed.modelDialect = .mistralXML
        buffer.draft.details = profile.details.settingLLMProviderConfig(refreshed)
        XCTAssertFalse(buffer.isDirty, "the picker re-detects on every open — that is not the user's edit")

        refreshed.modelName = "qwen2.5:7b"
        buffer.draft.details = profile.details.settingLLMProviderConfig(refreshed)
        XCTAssertTrue(buffer.isDirty, "picking another model is a real change")

        refreshed.modelName = "llama3.1:8b"
        refreshed.thinkingEnabled.toggle()
        buffer.draft.details = profile.details.settingLLMProviderConfig(refreshed)
        XCTAssertTrue(buffer.isDirty, "a preference is a real change")
    }

    // MARK: - The profile summary

    func testTheSummarySaysWhereTheAnswerComesFrom() {
        XCTAssertTrue(BackendProfileService.toolCallingSummary(for: ProviderConfig(apiProvider: .ollama, modelName: ""))
            .hasPrefix("not yet detected"))
        XCTAssertTrue(BackendProfileService.toolCallingSummary(for: ProviderConfig(apiProvider: .openAI, modelName: "gpt-5"))
            .hasPrefix("native"))

        let model = toolCapable()
        OllamaService.shared.localModels = [model]
        let stale = BackendProfileService.toolCallingSummary(for: ProviderConfig(apiProvider: .ollama, modelName: "llama3.1:8b"))
        XCTAssertTrue(stale.hasPrefix(model.cognitiveCapability.rawValue), stale)
        XCTAssertTrue(stale.contains("still stores"), "a stale stored copy must be called out — got: \(stale)")
    }

    // MARK: - Wiring

    /// ⚠️ The detection is only worth anything if every run path calls it. These are the three
    /// entry points a run's profile passes through; removing the call from any one of them puts
    /// that path back on the stored copy. A source check, because the real providers cannot run
    /// in a unit test.
    func testEveryRunEntryPointResolvesTheLiveCapability() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // Service
            .deletingLastPathComponent()   // Core
            .deletingLastPathComponent()   // DevgenticTests
            .deletingLastPathComponent()   // repo root
        func source(_ path: String) throws -> String {
            guard let text = try? String(contentsOf: root.appendingPathComponent(path), encoding: .utf8) else {
                throw XCTSkip("\(path) not reachable — running outside a checkout")
            }
            return text
        }
        let orchestration = try source("Devgentic/Core/Backends/BackendOrchestrationService.swift")
        XCTAssertTrue(orchestration.contains("BackendRequestConfig(profile: await LiveModelDetection.resolving(requestedConfig.profile))"),
                      "chat, Code, Orb, QuickAccess, ChatOps and the scheduler")
        let agentConnect = try source("Devgentic/Core/Backends/TextGen/AgentConnect.swift")
        XCTAssertEqual(agentConnect.components(separatedBy: "let profile = await LiveModelDetection.resolving(requestedProfile)").count - 1, 2,
                       "streamAgentResponse and streamWorkflowNodeResponse")
        let streamManager = try source("Devgentic/Core/Utils/ActiveStreamManager.swift")
        XCTAssertTrue(streamManager.contains("await LiveModelDetection.resolving(config.profile)"),
                      "the trace config snapshot")
    }
}
