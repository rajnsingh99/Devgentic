// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
//
//  PointerPromiseGatingTests.swift
//  DevgenticTests
//
//  Created by Raj Singh.
//

import XCTest
@testable import devgentic

final class PointerPromiseGatingTests: XCTestCase {

    private static let marker = "get_conversation_history("
    private let conversationID = UUID()

    /// Enough turns that hybrid has older ones to render as pointers (it inlines the last 3).
    private func history(turns: Int = 6) -> [ChatMessage] {
        var messages: [ChatMessage] = []
        for index in 0..<turns {
            let base = Date().addingTimeInterval(Double(index) * 2)
            messages.append(ChatMessage(id: UUID(), conversationId: conversationID,
                                        timestamp: base, sender: .user,
                                        content: .plainText("question \(index)")))
            messages.append(ChatMessage(id: UUID(), conversationId: conversationID,
                                        timestamp: base.addingTimeInterval(1), sender: .agent,
                                        content: .plainText("answer \(index)")))
        }
        return messages
    }

    private func nativeText(_ strategy: HistoryStrategy, toolsAvailable: Bool) -> String {
        NativeHistoryConverter.build(
            strategy: strategy, from: history(), charBudget: 50_000,
            includeImages: false, toolsAvailable: toolsAvailable
        ).map(\.text).joined(separator: "\n")
    }

    private func episodicText(_ strategy: HistoryStrategy, toolsAvailable: Bool) -> String {
        EpisodicHistoryFormatter.build(
            strategy: strategy, from: history(), toolsAvailable: toolsAvailable
        )
    }

    // MARK: - The invariant: the two emitters agree

    func testBothEmittersMakeTheSamePromise() {
        // ⚠️ THE REGRESSION GUARD, stated as the invariant rather than as "the converter has a
        // parameter". Whatever the strategy and whatever the profile, a prompt must not contain
        // one renderer's retrieval instruction alongside the other's refusal of it.
        for strategy in HistoryStrategy.allCases {
            for toolsAvailable in [true, false] {
                let native = nativeText(strategy, toolsAvailable: toolsAvailable).contains(Self.marker)
                let episodic = episodicText(strategy, toolsAvailable: toolsAvailable).contains(Self.marker)

                XCTAssertEqual(
                    native, episodic,
                    "\(strategy) / toolsAvailable=\(toolsAvailable): the native turns \(native ? "DO" : "do NOT") "
                    + "promise a get_conversation_history call while the episodic XML \(episodic ? "DOES" : "does NOT"). "
                    + "Both reach the model in the same request, so the prompt contradicts itself."
                )
            }
        }
    }

    // MARK: - The gate actually gates

    func testAToollessProfileIsNeverToldToCallTheTool() {
        for strategy in HistoryStrategy.allCases {
            XCTAssertFalse(
                nativeText(strategy, toolsAvailable: false).contains(Self.marker),
                "\(strategy) tells a profile with no tools to call get_conversation_history."
            )
        }
    }

    func testAToolRunningProfileStillGetsItsPointers() {
        // The other direction, and the one that would break the feature rather than a promise:
        // gating everything would silently turn pointer history into an unexpandable skeleton,
        // and `AgentConnect` would then stop injecting the tool because the marker is what it
        // probes for.
        for strategy in [HistoryStrategy.pointer, .hybrid] {
            XCTAssertTrue(
                nativeText(strategy, toolsAvailable: true).contains(Self.marker),
                "\(strategy) must still emit pointers for a profile that has the tool — the marker "
                + "is what AgentConnect keys on to inject it."
            )
        }
    }

    func testTheWithheldWordingMatchesTheOtherEmitter() {
        // Both renderers should read identically in a prompt; a second phrasing is a second thing
        // to grep for, and the pair being greppable together is what makes the next divergence
        // visible.
        let withheld = "Summary only — full detail is not retrievable this turn."
        XCTAssertTrue(nativeText(.pointer, toolsAvailable: false).contains(withheld))
        XCTAssertTrue(episodicText(.pointer, toolsAvailable: false).contains(withheld))
    }

    // MARK: - Non-pointer strategies are untouched

    func testStrategiesWithoutPointersNeverCarryTheMarker() {
        // These render prose, not skeletons, so the flag must change nothing about them. If one
        // started emitting the marker, `AgentConnect` would inject a tool no outcome references.
        for strategy in [HistoryStrategy.recentHistory, .fullHistory] {
            for toolsAvailable in [true, false] {
                XCTAssertFalse(nativeText(strategy, toolsAvailable: toolsAvailable).contains(Self.marker),
                               "\(strategy) emitted a pointer marker")
            }
        }
    }

    // MARK: - What AgentConnect actually probes

    func testTheInjectionProbeAgreesWithWhatWasEmitted() {
        // `AgentConnect` decides whether to inject `get_conversation_history` by scanning the
        // NATIVE turns when they exist — not the episodic XML that carries the contract. That is
        // only sound while the two agree, which is what the first test pins. This states the
        // consequence directly: on a tool-less profile the probe must come back false, so the
        // tool is not injected for a run whose history refuses to reference it.
        for strategy in HistoryStrategy.allCases {
            let turns = NativeHistoryConverter.build(
                strategy: strategy, from: history(), charBudget: 50_000,
                includeImages: false, toolsAvailable: false
            )
            XCTAssertFalse(
                turns.contains { $0.text.contains(Self.marker) },
                "\(strategy): the probe would inject get_conversation_history for a profile that "
                + "was rendered as having no tools."
            )
        }
    }
}
