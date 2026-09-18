// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
//
//  CodeProfileFitHintTests.swift
//  DevgenticTests
//
//  C7 (composer audit, 2026-07-18): the pre-send context-overflow hint covered only
//  `.bot`/`.agent`, so Code mode — where large file attachments are MOST common — got no
//  warning at all and only discovered the overflow at send time.
//
//  Fixing it meant reading the model config through `resolvedLLMConfig` (which knows
//  `.code`) instead of `primaryLLMConfig` (which returns nil for it). `primaryLLMConfig`
//  was deliberately NOT widened: it also backs `supportsVisionInput` and the orchestration
//  path, so broadening it would have silently changed Code-mode vision behaviour as a side
//  effect of adding a hint. These tests pin both halves of that decision.
//

import XCTest
@testable import devgentic

final class CodeProfileFitHintTests: XCTestCase {

    private func codeProfile(model: String = "qwen-coder") -> BackendProfileModel {
        BackendProfileSnapshot(
            displayName: "Code",
            details: .code(AgentConfig(
                llmConfig: ProviderConfig(apiProvider: .ollama, modelName: model),
                tools: []
            ))
        )
    }

    func testCodeProfileReportsCodeType() {
        XCTAssertEqual(codeProfile().profileType, .code)
    }

    /// The accessor the fit hint now uses — it must see Code's real model config,
    /// otherwise the estimate is computed against nothing.
    func testResolvedLLMConfigSeesCodeProfile() {
        let resolved = codeProfile().resolvedLLMConfig
        XCTAssertNotNil(resolved, "A Code profile carries a real model config")
        XCTAssertEqual(resolved?.modelName, "qwen-coder")
    }

    /// Pins the deliberate boundary: `primaryLLMConfig` stays bot/agent-only. If someone
    /// "simplifies" the hint back onto it, Code silently loses the warning again; if they
    /// widen THIS instead, `supportsVisionInput` changes for Code as a side effect.
    func testPrimaryLLMConfigStillExcludesCodeOnPurpose() {
        XCTAssertNil(
            codeProfile().primaryLLMConfig,
            "primaryLLMConfig must stay bot/agent-only — it also backs supportsVisionInput"
        )
    }

    /// Sanity: the two accessors agree for the profile types that were always supported,
    /// so the switch didn't change behaviour for bot/agent.
    func testBotProfileAgreesAcrossBothAccessors() {
        let bot = BackendProfileSnapshot(
            displayName: "Bot",
            details: .bot(BotConfig(llmConfig: ProviderConfig(apiProvider: .ollama, modelName: "llama")))
        )
        XCTAssertEqual(bot.primaryLLMConfig?.modelName, "llama")
        XCTAssertEqual(bot.resolvedLLMConfig?.modelName, "llama")
    }
}
