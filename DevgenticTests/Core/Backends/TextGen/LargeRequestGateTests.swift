// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
//
//  LargeRequestGateTests.swift
//  DevgenticTests
//
//  The large-cloud-request confirmation: when it asks, how often, and for which endpoints.
//

import XCTest
@testable import devgentic

final class LargeRequestGateTests: XCTestCase {

    private let threshold = LargeRequestGate.thresholdChars

    func testThresholdIsFiftyThousandTokensOnTheGaugeBasis() {
        XCTAssertEqual(LargeRequestGate.thresholdTokens, 50_000)
        XCTAssertEqual(threshold, Int(50_000 * PromptFitCheck.charsPerToken))
        XCTAssertEqual(LargeRequestGate.estimatedTokens(chars: threshold), 50_000)
    }

    func testAsksOnlyAtOrAboveTheThreshold() {
        XCTAssertFalse(LargeRequestGate.needsConfirmation(payloadChars: threshold - 1, thresholdChars: threshold, approvedThroughChars: 0))
        XCTAssertTrue(LargeRequestGate.needsConfirmation(payloadChars: threshold, thresholdChars: threshold, approvedThroughChars: 0))
    }

    func testZeroThresholdDisablesTheGate() {
        XCTAssertFalse(LargeRequestGate.needsConfirmation(payloadChars: 10_000_000, thresholdChars: 0, approvedThroughChars: 0))
    }

    /// After an approval the next ask waits for another threshold's worth of growth — a run that
    /// stays over the line must not re-prompt on every tool call.
    func testAfterApprovalAsksAgainOnlyAfterAnotherThresholdOfGrowth() {
        let approved = threshold + 30_000
        XCTAssertFalse(LargeRequestGate.needsConfirmation(payloadChars: approved + 1_000, thresholdChars: threshold, approvedThroughChars: approved))
        XCTAssertFalse(LargeRequestGate.needsConfirmation(payloadChars: approved + threshold - 1, thresholdChars: threshold, approvedThroughChars: approved))
        XCTAssertTrue(LargeRequestGate.needsConfirmation(payloadChars: approved + threshold, thresholdChars: threshold, approvedThroughChars: approved))
    }

    func testOnlyRemoteEndpointsAreGated() {
        for provider in [ApiProvider.openRouter, .openAI, .anthropic, .google] {
            XCTAssertEqual(LargeRequestGate.confirmChars(provider: provider, baseURL: nil), threshold, "\(provider)")
        }
        XCTAssertEqual(LargeRequestGate.confirmChars(provider: .ollama, baseURL: nil), 0)
        XCTAssertEqual(LargeRequestGate.confirmChars(provider: .mlx, baseURL: nil), 0)
    }

    /// `ProviderClass` files every OpenAI-compatible profile as cloud; one on this machine is not.
    func testLocalOpenAICompatibleServersAreNotGated() {
        XCTAssertEqual(LargeRequestGate.confirmChars(provider: .openAICompatible, baseURL: "http://localhost:1234/v1"), 0)
        XCTAssertEqual(LargeRequestGate.confirmChars(provider: .openAICompatible, baseURL: "http://127.0.0.1:8000/v1"), 0)
        XCTAssertEqual(LargeRequestGate.confirmChars(provider: .openAICompatible, baseURL: "https://api.groq.com/openai/v1"), threshold)
    }

    func testBannerStatesTheSizeAndTheConsequences() {
        let text = LargeRequestGate.bannerText(payloadChars: 225_870, modelName: "a/b:free")
        XCTAssertTrue(text.contains("75,290"), text)
        XCTAssertTrue(text.contains("a/b:free"), text)
        XCTAssertTrue(text.contains("nothing is sent"), text)
    }
}
