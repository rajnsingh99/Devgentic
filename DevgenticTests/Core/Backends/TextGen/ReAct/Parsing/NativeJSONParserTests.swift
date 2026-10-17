// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
//
//  NativeJSONParserTests.swift
//  DevgenticTests
//
//  Tests for NativeJSONParser — the fast-path parser for models
//  that emit well-formed OpenAI-compatible JSON tool call arrays.
//

import XCTest
@testable import devgentic

final class NativeJSONParserTests: XCTestCase {

    private let parser = NativeJSONParser()

    // MARK: - Fast Path (Direct Decode)

    func testFastPath_SingleToolCall() {
        let input = """
        {"content": "Listing directory.", "tool_calls": [{"name": "list_directory", "arguments": {"path": "/"}}]}
        """
        let result = parser.parse(rawResponse: input)
        XCTAssertEqual(result.toolCalls.count, 1)
        XCTAssertEqual(result.toolCalls.first?.name, "list_directory")
        XCTAssertEqual(result.reasoning, "Listing directory.")
    }

    func testFastPath_MultipleToolCalls() {
        let input = """
        {
          "content": "Running parallel actions.",
          "tool_calls": [
            {"name": "list_directory", "arguments": {"path": "/tmp"}},
            {"name": "read_file", "arguments": {"path": "/tmp/test.txt"}},
            {"name": "read_file_metadata", "arguments": {"path": "/tmp"}}
          ]
        }
        """
        let result = parser.parse(rawResponse: input)
        XCTAssertEqual(result.toolCalls.count, 3)
        XCTAssertEqual(result.toolCalls[0].name, "list_directory")
        XCTAssertEqual(result.toolCalls[1].name, "read_file")
        XCTAssertEqual(result.toolCalls[2].name, "read_file_metadata")
    }

    func testFastPath_EmptyToolCallsArray() {
        let input = """
        {"content": "I cannot help with that.", "tool_calls": []}
        """
        let result = parser.parse(rawResponse: input)
        XCTAssertEqual(result.toolCalls.count, 0)
        XCTAssertEqual(result.reasoning, "I cannot help with that.")
    }

    func testFastPath_ComplexArguments() {
        let input = """
        {
          "content": "Creating file.",
          "tool_calls": [{
            "name": "create_or_update_file",
            "arguments": {
              "path": "/tmp/test.txt",
              "content": "Hello World",
              "overwrite": true,
              "mode": null
            }
          }]
        }
        """
        let result = parser.parse(rawResponse: input)
        XCTAssertEqual(result.toolCalls.count, 1)
        XCTAssertEqual(result.toolCalls.first?.arguments["overwrite"], .bool(true))
        XCTAssertEqual(result.toolCalls.first?.arguments["mode"], .null)
    }

    // MARK: - Markdown Fence Handling

    func testMarkdownFence_JsonWrapped() {
        let input = """
        ```json
        {"content": "Listing.", "tool_calls": [{"name": "list_directory", "arguments": {"path": "/"}}]}
        ```
        """
        let result = parser.parse(rawResponse: input)
        XCTAssertEqual(result.toolCalls.count, 1)
    }

    // MARK: - Fallback to HeuristicCognitiveParser

    // MARK: - Recovery is the PIPELINE's job, not this parser's
    //
    // ⚠️ These two tests asserted `parser.parse(...)` recovered tool calls by delegating to
    // `HeuristicCognitiveParser` internally. That delegation was deliberately removed — this
    // file's header states why: doing it inside the parser bypasses the pipeline's
    // `parseOutcome` tracking, so a rescued call was indistinguishable from a clean fast-path
    // hit and nothing downstream knew recovery had happened. The tests were never re-pointed,
    // so they asserted removed behaviour and had been failing against committed code.
    //
    // Re-pointed at the real contract rather than deleted: the recovery they cared about is
    // genuine and still required, it simply belongs one layer up. Each now asserts BOTH halves —
    // the parser yields, and the pipeline recovers — so neither the yield nor the rescue can
    // regress unnoticed.

    func testMalformedJSON_ParserYields_PipelineRecovers() {
        // Missing comma between the two objects — the strict fast path cannot decode it.
        let input = """
        {
          "content": "Searching.",
          "tool_calls": [
            {"name": "list_directory", "arguments": {"path": "/tmp"}}
            {"name": "read_file", "arguments": {"path": "/a.txt"}}
          ]
        }
        """

        let parserResult = parser.parse(rawResponse: input)
        XCTAssertTrue(parserResult.toolCalls.isEmpty,
                      "the parser must yield rather than rescue — rescuing here loses parseOutcome")
        XCTAssertFalse(parserResult.reasoning.isEmpty,
                       "yielding must not discard the text (see ConversationalExitContractTests)")

        let recovered = CognitiveParsePipeline(expectedDialect: .nativeJSON, registeredTools: [])
            .parse(raw: input)
        XCTAssertGreaterThanOrEqual(recovered.toolCalls.count, 1,
                                    "the pipeline's heuristic stage must recover at least one tool")
    }

    func testLegacySingleFormat_ParserYields_PipelineRecovers() {
        // `tool_name` at the top level — not `NativeArraySchema`, so the fast path misses.
        let input = """
        {"content": "Executing.", "tool_name": "list_directory", "arguments": {"path": "/"}}
        """

        let parserResult = parser.parse(rawResponse: input)
        XCTAssertTrue(parserResult.toolCalls.isEmpty, "the parser must yield, not rescue")

        let recovered = CognitiveParsePipeline(expectedDialect: .nativeJSON, registeredTools: [])
            .parse(raw: input)
        XCTAssertEqual(recovered.toolCalls.count, 1)
        XCTAssertEqual(recovered.toolCalls.first?.name, "list_directory")
    }
}
