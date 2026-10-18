// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
//
//  ConversationalExitContractTests.swift
//  DevgenticTests
//
//  Created by Raj Singh.
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
