// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
//
//  CodeContextWindowTests.swift
//  DevgenticTests
//
//  Created by Raj Singh.
//

import XCTest
import SwiftData
@testable import devgentic

// MARK: - A. The override reaches the request and every budget

final class ContextOverrideResolutionTests: XCTestCase {

    private func ollama(trained: Int? = 131_072, stored: [String: JSONValue]? = nil, override: Int? = nil) -> ProviderConfig {
        var config = ProviderConfig(apiProvider: .ollama, modelName: "gemma4:latest",
                                    advancedConfiguration: stored, modelMetadata: ModelMetadata(tier: .small, contextWindow: trained))
        config.numCtxOverride = override
        return config
    }

    private func sent(_ config: ProviderConfig) -> Int? {
        OllamaContextWindowPolicy.configuredNumCtx(in: OllamaRequestOptions.resolve(
            stored: config.advancedConfiguration, metadata: config.modelMetadata,
            modelName: config.modelName, flavour: .agent, numCtxOverride: config.numCtxOverride).options)
    }

    /// ⚠️ The defect: the agent preset's 8,192 won.
    func testTheOverrideWinsOverThePreset() {
        XCTAssertEqual(sent(ollama(override: 32_768)), 32_768)
    }

    func testTheOverrideWinsOverStoredAdvancedSettings() {
        XCTAssertEqual(sent(ollama(stored: ["numCtx": .number(4_096), "temperature": .number(0.2)], override: 16_384)), 16_384)
    }

    /// The rest of the stored options survive — only the window is overridden.
    func testTheOverrideKeepsTheOtherOptions() {
        let config = ollama(stored: ["numCtx": .number(4_096), "temperature": .number(0.2)], override: 16_384)
        let options = OllamaRequestOptions.resolve(stored: config.advancedConfiguration, metadata: config.modelMetadata,
                                                   modelName: config.modelName, flavour: .agent, numCtxOverride: 16_384).options
        XCTAssertEqual(options?["temperature"], .number(0.2))
    }

    func testNoOverrideLeavesTheLadderAlone() {
        XCTAssertEqual(sent(ollama(override: nil)), sent(ollama(override: nil)))
        XCTAssertNotEqual(sent(ollama(override: nil)), 32_768, "premise: the preset decides without an override")
    }

    /// The request and the gauge / budgets must read the SAME window — the 2026-09-20 defect.
    func testTheGaugeAndBudgetsSeeTheOverride() {
        XCTAssertEqual(EffectiveContextWindow.resolve(for: ollama(override: 32_768), flavour: .agent), 32_768)
    }

    /// ⚠️ `ProviderConfig` has a HAND-WRITTEN decoder — a field it forgets is saved and then lost.
    func testTheOverrideSurvivesTheProfileBlob() throws {
        let config = ollama(override: 65_536)
        let decoded = try JSONDecoder().decode(ProviderConfig.self, from: JSONEncoder().encode(config))
        XCTAssertEqual(decoded.numCtxOverride, 65_536)
        XCTAssertEqual(decoded, config)
    }
}

// MARK: - A. Code's default and its per-project choice

@MainActor
final class CodeContextSizeTests: XCTestCase {

    private func llm(_ provider: ApiProvider = .ollama, trained: Int?) -> ProviderConfig {
        ProviderConfig(apiProvider: provider, modelName: "m", modelMetadata: ModelMetadata(tier: .small, contextWindow: trained))
    }

    func testTheDefaultIsTheModelsWindowCapped() {
        XCTAssertEqual(CodeSessionManager.contextTokens(.default, for: llm(trained: 131_072)), CodeSessionManager.presetContextCap)
        XCTAssertEqual(CodeSessionManager.contextTokens(.default, for: llm(trained: 8_192)), 8_192, "never above what the model supports")
    }

    func testAChosenSizeWins() {
        var settings = CodeQuickSettings.default
        settings.contextTokens = 65_536
        XCTAssertEqual(CodeSessionManager.contextTokens(settings, for: llm(trained: 131_072)), 65_536)
    }

    func testOnlyOllamaIsOverridden() {
        XCTAssertNil(CodeSessionManager.contextTokens(.default, for: llm(.anthropic, trained: 200_000)))
        XCTAssertNil(CodeSessionManager.contextTokens(.default, for: llm(.mlx, trained: 131_072)))
    }

    /// Unknown window → leave Ollama's own ladder in charge rather than guess.
    func testAnUnknownWindowIsNotGuessed() {
        XCTAssertNil(CodeSessionManager.contextTokens(.default, for: ProviderConfig(apiProvider: .ollama, modelName: "no-such-model-xyz")))
    }

    /// `apply` is what every send and every project load goes through.
    func testApplyPutsTheWindowOnTheRun() {
        var config = AgentConfig(llmConfig: llm(trained: 131_072), tools: CodeToolPreset.defaultTools, historyStrategy: .pointer)
        CodeSessionManager.apply(.default, to: &config)
        XCTAssertEqual(config.llmConfig.numCtxOverride, CodeSessionManager.presetContextCap)
        XCTAssertEqual(EffectiveContextWindow.resolve(for: config.llmConfig, flavour: .agent), CodeSessionManager.presetContextCap)
    }
}

// MARK: - B. The fixed-cost warning

final class FixedCostWarningTests: XCTestCase {

    private func usage(toolChars: Int, knowledgeChars: Int = 0, window: Int) -> ContextWindowUsage {
        ContextWindowUsage(usedTokens: 0, windowTokens: window, trainedTokens: nil, modelName: "m", provider: .ollama,
                           profileID: nil, lastTurn: nil, windowIsFallback: false, usesRetrieval: false,
                           turnSpansMultipleCalls: true,
                           breakdown: ContextOccupancy(toolChars: toolChars, knowledgeChars: knowledgeChars))
    }

    /// The device case: 14K chars of tools + 2K instructions + 362 of project knowledge in an 8K window.
    func testTheDeviceCaseWarns() {
        let u = usage(toolChars: 14_044, knowledgeChars: 362, window: 8_192)
        XCTAssertTrue(u.fixedCostIsHigh)
        XCTAssertEqual(u.fixedTokens, ContextOccupancy.tokens(14_044 + PromptFitCheck.layerOverheadChars + 362))
    }

    /// The same prompt in the Code default window is fine.
    func testTheSamePromptIn32KDoesNotWarn() {
        XCTAssertFalse(usage(toolChars: 14_044, knowledgeChars: 362, window: 32_768).fixedCostIsHigh)
    }

    func testNoBreakdownNoWarning() {
        let u = ContextWindowUsage(usedTokens: 0, windowTokens: 8_192, trainedTokens: nil, modelName: "m", provider: .ollama,
                                   profileID: nil, lastTurn: nil, windowIsFallback: false, usesRetrieval: false,
                                   turnSpansMultipleCalls: false)
        XCTAssertFalse(u.fixedCostIsHigh)
    }
}

// MARK: - B. A step the provider had to cut

@MainActor
final class ProviderOverflowTests: XCTestCase {

    /// ⚠️ From the device log: step 5 reached 8,051 of 8,192 (Ollama cuts to fit and reports the
    /// cut size, just under the window). Steps 2–3 at 5.6–5.8K were fine despite the app's
    /// pessimistic estimate saying "over budget".
    func testTheDeviceStepsAreClassifiedCorrectly() {
        XCTAssertTrue(ContextCutLog.isOverflow(promptTokens: 8_051, windowTokens: 8_192))
        XCTAssertFalse(ContextCutLog.isOverflow(promptTokens: 5_814, windowTokens: 8_192))
        XCTAssertFalse(ContextCutLog.isOverflow(promptTokens: 5_000, windowTokens: 0), "unknown window must not report")
    }

    /// The executor's decision: real counts only, and the step is carried through.
    func testOnlyARealCountReportsAnOverflow() {
        let real = TokenUsage(inputTokens: 8_051, outputTokens: 10, isEstimated: false)
        XCTAssertEqual(ContextCutLog.overflow(in: real, step: 5, windowTokens: 8_192)?.step, 5)
        let estimated = TokenUsage(inputTokens: 8_051, outputTokens: 10, isEstimated: true)
        XCTAssertNil(ContextCutLog.overflow(in: estimated, step: 5, windowTokens: 8_192), "an estimate is not the provider cutting")
        XCTAssertNil(ContextCutLog.overflow(in: TokenUsage(inputTokens: 5_814, outputTokens: 10, isEstimated: false), step: 3, windowTokens: 8_192))
    }

    func testAnOverflowAloneShowsInTheGauge() {
        let log = ContextCutLog()
        let conversation = UUID()
        log.recordOverflow(.init(step: 5, promptTokens: 8_051, windowTokens: 8_192), conversationID: conversation, traceID: "t")
        XCTAssertEqual(log.lastTurn(for: conversation)?.overflow?.step, 5)
    }

    /// The FIRST step that overflowed is the one that explains the turn.
    func testTheFirstOverflowIsKept() {
        let log = ContextCutLog()
        let conversation = UUID()
        log.recordOverflow(.init(step: 5, promptTokens: 8_051, windowTokens: 8_192), conversationID: conversation, traceID: "t")
        log.recordOverflow(.init(step: 6, promptTokens: 8_100, windowTokens: 8_192), conversationID: conversation, traceID: "t")
        XCTAssertEqual(log.lastTurn(for: conversation)?.overflow?.step, 5)
    }
}

// MARK: - Wiring

final class CodeContextWiringTests: XCTestCase {

    private func source(_ relative: String) throws -> String {
        var root = URL(fileURLWithPath: #filePath)
        for _ in 0..<4 { root = root.deletingLastPathComponent() }
        let url = root.appendingPathComponent(relative)
        try XCTSkipUnless(FileManager.default.fileExists(atPath: url.path), "running outside a checkout")
        return try String(contentsOf: url, encoding: .utf8)
            .components(separatedBy: "\n")
            .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
            .joined(separator: "\n")
    }

    func testTheRequestFactoryPassesTheOverride() throws {
        let code = try source("Devgentic/Core/Backends/TextGen/AgentConnect.swift")
        XCTAssertTrue(code.contains("numCtxOverride: llmConfig.numCtxOverride"), "the request ignores Code's context size")
        XCTAssertEqual(code.components(separatedBy: "contextWindowTokens: contextWindow").count - 1, 2,
                       "a run no longer knows its window, so overflow cannot be detected")
    }

    func testCodeAppliesItsContextSize() throws {
        let code = try source("Devgentic/Interfaces/Code/CodeSessionManager.swift")
        XCTAssertTrue(code.contains("agentConfig.llmConfig.numCtxOverride = contextTokens(settings, for: agentConfig.llmConfig)"))
        XCTAssertTrue(code.contains("agentConfig.llmConfig.numCtxOverride = Self.contextTokens(quickSettings, for: agentConfig.llmConfig)"),
                      "a newly picked model keeps the previous model's window until the next send")
    }

    func testTheGaugeShowsTheWarningAndTheOverflow() throws {
        let code = try source("Devgentic/Interfaces/Shared/ChatInput/ContextWindowGauge.swift")
        XCTAssertTrue(code.contains("if usage.fixedCostIsHigh, let fixed = usage.fixedTokens { fixedCostRow(fixed) }"))
        XCTAssertTrue(code.contains("if let overflow = record.overflow { overflowRow(overflow) }"))
    }

    func testRaiseContextOpensCodeQuickSettings() throws {
        let code = try source("Devgentic/Interfaces/Shared/ChatInput/ChatInputAreaView.swift")
        XCTAssertTrue(code.contains("? { codeSessionManager.showQuickSettings = true }"))
        let toolbar = try source("Devgentic/Interfaces/Shared/ChatInput/InputToolbarView.swift")
        XCTAssertTrue(toolbar.contains("codeSessionManager.showQuickSettings"), "the popover no longer follows the shared flag")
    }
}
