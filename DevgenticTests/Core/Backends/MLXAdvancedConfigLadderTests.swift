// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
//
//  MLXAdvancedConfigLadderTests.swift
//  DevgenticTests
//
//  Created by Raj Singh.
//

import XCTest
@testable import devgentic

final class MLXAdvancedConfigLadderTests: XCTestCase {

    private let tiers: [ModelTier] = [.tiny, .small, .medium, .large, .ultra]
    private let quantizations: [String?] = ["3bit", "4bit", "8bit", nil]

    func testTheAgentLadderNeverPenalisesRepetitionHard() {
        for tier in tiers {
            for quantization in quantizations {
                let config = MLXAdvancedConfig.recommended(
                    for: ModelMetadata(tier: tier, quantization: quantization), profile: .agent)
                XCTAssertLessThanOrEqual(config.repetitionPenalty, 1.1, "\(tier) \(quantization ?? "fp16")")
                XCTAssertGreaterThanOrEqual(config.repetitionPenalty, 1.0, "\(tier) \(quantization ?? "fp16")")
            }
        }
    }

    /// The device run's model: tiny tier, 4-bit.
    func testQwen3BOnAnAgentRunGetsTheLightPenalty() {
        let metadata = ModelMetadata(tier: .tiny, quantization: "4bit")
        XCTAssertEqual(MLXAdvancedConfig.recommended(for: metadata, profile: .agent).repetitionPenalty, 1.05)
    }

    /// Bots keep the strong ladder: they repeat no identifiers, and it is what keeps a tiny Q4 model
    /// out of a prose loop.
    func testTheChatLadderIsUnchanged() {
        let metadata = ModelMetadata(tier: .tiny, quantization: "4bit")
        let chat = MLXAdvancedConfig.recommended(for: metadata, profile: .chat)
        XCTAssertEqual(chat.repetitionPenalty, 1.30)
        XCTAssertEqual(chat.repetitionContextSize, 30)
    }

    /// Code and agent profiles are on the agent ladder; only Bot is on the chat one.
    func testEveryToolRunningProfileTypeIsOnTheAgentLadder() {
        for type in ProfileType.allCases {
            XCTAssertEqual(OllamaConfigDefaultProfile.forProfileType(type), type == .bot ? .chat : .agent, "\(type)")
        }
    }
}
