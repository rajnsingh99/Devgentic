// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
//
//  PromptPrefixStabilityTests.swift
//  devgenticTests
//
//  On the legacy path the whole message array is rebuilt every iteration. A KV cache (MLX's, or
//  Ollama's own) can only skip re-reading the part of the prompt that is byte-identical to the
//  previous iteration's. The system message is ~2k tokens and the chat template renders the ~3.5k
//  token tool block AFTER it, so one changed byte in it costs a full re-read of both. On the
//  2026-10-06 device run that was 7-11s per iteration on Qwen2.5-3B.
//
//  These pin the invariant, not where any particular layer lives: what changes during a run must
//  not change the system message, and must still reach the model.
//

import XCTest
@testable import devgentic

final class PromptPrefixStabilityTests: XCTestCase {

    private func context(
        iteration: Int,
        scratchpad: String = "",
        clarification: ClarificationContext? = nil,
        negativeConstraints: Set<String> = [],
        hallucinatedTools: Set<String> = []
    ) -> SemanticContext {
        SemanticContext(
            instructions: "You are a coding assistant.",
            environmentFacts: EnvironmentFacts(
                osVersion: "macOS 26",
                shellType: "Zsh",
                userName: "tester",
                homeDirectory: "/Users/tester",
                currentDate: "06/10/2026, 14:35",
                workspaceRoot: "/Users/tester/project"
            ),
            longTermMemory: StaticGroundingMemory(ragContext: ""),
            recentHistory: "<episodic_memory>earlier turn</episodic_memory>",
            nativeHistoryTurns: nil,
            originalQuery: "Which file defines clamp?",
            currentIteration: iteration,
            compiledScratchpad: scratchpad,
            latestClarification: clarification,
            negativeConstraints: negativeConstraints,
            hallucinatedTools: hallucinatedTools,
            availableTools: [],
            userProfile: nil,
            skillManifests: nil,
            promptLayerConfig: .agent,
            workflowContext: nil
        )
    }

    private func system(_ messages: [[String: String]]) -> String {
        messages.first { $0["role"] == "system" }?["content"] ?? ""
    }

    private func user(_ messages: [[String: String]]) -> String {
        messages.filter { $0["role"] == "user" }.compactMap { $0["content"] }.joined(separator: "\n")
    }

    /// A struggling run: by iteration 5 it has a scratchpad, failed paths, a hallucinated tool and a
    /// clarification. None of that may move the system message, under either wrapping.
    func testTheLegacySystemMessageIsByteIdenticalAcrossARun() {
        for wrapping in [PromptWrapping.xml, .markdown] {
            let first = PromptBuilder.buildStandardMessages(context: context(iteration: 1), wrapping: wrapping)
            let later = PromptBuilder.buildStandardMessages(
                context: context(
                    iteration: 5,
                    scratchpad: "read_file a.py -> 4 lines",
                    clarification: ClarificationContext(query: "Which clamp?", response: "the one in src"),
                    negativeConstraints: ["code_search_files with '*.py' failed"],
                    hallucinatedTools: ["open_file"]
                ),
                wrapping: wrapping
            )
            XCTAssertEqual(system(first), system(later),
                           "\(wrapping.logLabel): a fact learned mid-run changed the system message, so the "
                           + "whole tool block after it is re-read on the next iteration")

            let tail = user(later)
            for fact in ["the one in src", "code_search_files with '*.py' failed", "open_file"] {
                XCTAssertTrue(tail.contains(fact), "\(wrapping.logLabel): '\(fact)' no longer reaches the model")
            }
        }
    }

    /// The failed paths are a Set. Two Sets with the same members can iterate in different orders,
    /// so rendering them unsorted could change the bytes with no change in the facts.
    func testTheSameFailedPathsRenderTheSameBytes() {
        let names = (1...12).map { "path \($0) failed" }
        let forward = Set(names)
        var backward = Set<String>(minimumCapacity: 64)
        names.reversed().forEach { backward.insert($0) }

        let a = PromptBuilder.buildStandardMessages(context: context(iteration: 3, negativeConstraints: forward, hallucinatedTools: forward))
        let b = PromptBuilder.buildStandardMessages(context: context(iteration: 3, negativeConstraints: backward, hallucinatedTools: backward))
        XCTAssertEqual(user(a), user(b))
    }

    /// The native path sends real turns and never rebuilds the system message per iteration, so it
    /// keeps these layers where they were. Pinned so the move stays confined to the legacy path.
    func testTheNativePathKeepsTheLayersInTheSystemMessage() {
        let messages = PromptBuilder.buildStandardMessages(
            context: context(
                iteration: 2,
                clarification: ClarificationContext(query: "Which clamp?", response: "the one in src"),
                negativeConstraints: ["a failed path"],
                hallucinatedTools: ["open_file"]
            ),
            includeWorkingMemory: false
        )
        for fact in ["the one in src", "a failed path", "open_file"] {
            XCTAssertTrue(system(messages).contains(fact), "native path lost '\(fact)' from its system message")
        }
    }

    /// The run's date is captured once. Rebuilt per iteration, a minute ticking over changed the
    /// environment layer mid-run (T4 spanned 14:35-14:37). The executor cannot be driven across a
    /// real minute in a test, so this guards the call site the way `OpenAIPanelGatingSourceTests`
    /// does: the per-iteration context must read the run's captured date, never a fresh `Date()`.
    func testTheExecutorReadsTheRunsDateNotTheClock() throws {
        let source = try String(
            contentsOf: URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent()   // Generation
                .deletingLastPathComponent()   // ReAct
                .deletingLastPathComponent()   // TextGen
                .deletingLastPathComponent()   // Backends
                .deletingLastPathComponent()   // Core
                .deletingLastPathComponent()   // devgenticTests
                .deletingLastPathComponent()   // repo root
                .appendingPathComponent("Devgentic/Core/Backends/TextGen/ReAct/ReActAgentExecutor.swift"),
            encoding: .utf8)
        XCTAssertFalse(source.contains("currentDate: Date()"),
                       "the iteration context reads the clock again, so the date changes mid-run")
        XCTAssertFalse(source.contains("EnvironmentFacts.clock().time"),
                       "the iteration context reads the clock again, so the time changes mid-run")
        XCTAssertTrue(source.contains("currentDate: runClock.date"))
        XCTAssertTrue(source.contains("currentTime: runClock.time"))
    }
}
