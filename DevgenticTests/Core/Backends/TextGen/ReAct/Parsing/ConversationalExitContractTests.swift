// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
//
//  ConversationalExitContractTests.swift
//  DevgenticTests
//
//  ONE contract, asserted across the whole parser matrix: a parser that finds no tool call must
//  hand back the model's TEXT.
//
//  ⚠️ WHY THIS FILE EXISTS. `NativeJSONParser` returned `reasoning: ""` on a fast-path miss — the
//  only one of fourteen parsers that did; every sibling returns
//  `rawResponse.trimmingCharacters(in: .whitespacesAndNewlines)` under a "Treating as
//  conversational exit" log. The damage was not confined to parsing: plain prose reaches
//  `classifyConfidence`, which correctly finds no tool signals and returns `.confident`, and
//  `resolveAndFinalize` then emits `.genuineCompletion` carrying that empty string. So on the
//  `.nativeJSON` prompted path (Ollama content-fallback, MLX JSON mode) a model that answered in
//  prose — a refusal, a clarifying question, a direct answer — produced an EMPTY final answer.
//
//  ⚠️ It survived because the tests that covered the path asserted the VERDICT and not the TEXT.
//  `testParseOutcome_PlainTextExit_GenuineCompletion` even stated the contract in its comment
//  ("Stage 1 returns text as reasoning") and checked only `toolCalls.count` and `parseOutcome`.
//  A per-parser test would have had the same blind spot for any parser nobody thought to add, so
//  the contract is asserted here across the matrix instead of one parser at a time.
//

import XCTest
@testable import devgentic

final class ConversationalExitContractTests: XCTestCase {

    /// Prose a model might genuinely end a turn with. Contains no marker of any dialect, so every
    /// parser in the matrix must treat it as a conversational exit.
    private let prose = "I'm sorry, I cannot help with that request."

    /// Every dialect reachable as a Stage-1 primary. Driven from `allCases` rather than a hand
    /// list, so a new dialect is covered the day it is added.
    func testEveryDialectPrimaryParserPreservesProseOnAConversationalExit() {
        for dialect in ModelDialect.allCases {
            let parser = ParserFactory.createParser(for: dialect)
            let step = parser.parse(rawResponse: prose)

            XCTAssertTrue(step.toolCalls.isEmpty,
                          "\(dialect.rawValue) extracted a tool call from plain prose: \(step.toolCalls)")
            XCTAssertTrue(
                step.reasoning.contains("cannot help"),
                "\(dialect.rawValue)'s parser DISCARDED the model's answer on a no-match. Every "
                + "parser must return the text — a conversational exit that carries no text "
                + "reaches the user as an empty reply. Got reasoning: \(step.reasoning.debugDescription)"
            )
        }
    }

    /// The same contract through the whole pipeline, which is where the consequence actually lands:
    /// the step the executor seats as `finalAgentThought`.
    func testEveryDialectPipelinePreservesProseOnAConversationalExit() {
        for dialect in ModelDialect.allCases {
            let pipeline = CognitiveParsePipeline(expectedDialect: dialect, registeredTools: [])
            let result = pipeline.parse(raw: prose)

            XCTAssertTrue(
                result.reasoning.contains("cannot help"),
                "\(dialect.rawValue): the pipeline returned a completion with no text. Got: "
                + result.reasoning.debugDescription
            )
        }
    }

    /// ⚠️ The specific regression, named, so a future reader meets the case rather than the rule.
    /// This is the exact input `CognitiveParsePipelineTests.testConversationalExit_PlainText` fed,
    /// and it returned `""` for as long as the defect was live.
    func testNativeJSONFastPathMissReturnsTheTextNotAnEmptyString() {
        let step = NativeJSONParser().parse(rawResponse: prose)

        XCTAssertEqual(step.reasoning, prose)
        XCTAssertTrue(step.toolCalls.isEmpty)
    }

    /// The fast path must still filter narration stubs out of `content` — the fix preserves text on
    /// the MISS path and must not turn the parser into a pass-through on the HIT path.
    func testFastPathStillFiltersContentAndExtractsCalls() {
        let step = NativeJSONParser().parse(
            rawResponse: #"{"content": "Listing directory.", "tool_calls": [{"name": "ls", "arguments": {}}]}"#
        )

        XCTAssertEqual(step.toolCalls.count, 1)
        XCTAssertEqual(step.reasoning, "Listing directory.")
    }

    /// ⚠️ A `.genuineCompletion` with empty reasoning is the shape the defect produced, and it is
    /// indistinguishable from "the model said nothing" at every layer above the parser. Nothing
    /// downstream can recover the text once it is dropped here, which is why the assertion belongs
    /// on the outcome and the text TOGETHER.
    func testAGenuineCompletionNeverCarriesEmptyText() {
        for dialect in ModelDialect.allCases {
            let result = CognitiveParsePipeline(expectedDialect: dialect, registeredTools: [])
                .parse(raw: prose)

            if result.parseOutcome == .genuineCompletion {
                XCTAssertFalse(
                    result.reasoning.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                    "\(dialect.rawValue) reported a completed turn with no answer in it"
                )
            }
        }
    }
}
