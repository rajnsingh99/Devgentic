// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2026 Raj Singh
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
            {"name": "fs_read_metadata", "arguments": {"path": "/tmp"}}
          ]
        }
        """
        let result = parser.parse(rawResponse: input)
        XCTAssertEqual(result.toolCalls.count, 3)
        XCTAssertEqual(result.toolCalls[0].name, "list_directory")
        XCTAssertEqual(result.toolCalls[1].name, "read_file")
        XCTAssertEqual(result.toolCalls[2].name, "fs_read_metadata")
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

    func testFallback_MalformedJSON_DelegatesToHeuristic() {
        // Missing comma — fast-path fails, should delegate to heuristic parser
        let input = """
        {
          "content": "Searching.",
          "tool_calls": [
            {"name": "list_directory", "arguments": {"path": "/tmp"}}
            {"name": "read_file", "arguments": {"path": "/a.txt"}}
          ]
        }
        """
        let result = parser.parse(rawResponse: input)
        // Heuristic should recover at least some tool calls
        XCTAssertGreaterThanOrEqual(result.toolCalls.count, 1, "Heuristic fallback should recover at least 1 tool")
    }

    func testFallback_LegacySingleFormat() {
        // Not NativeArraySchema — should fall through to heuristic
        let input = """
        {"content": "Executing.", "tool_name": "list_directory", "arguments": {"path": "/"}}
        """
        let result = parser.parse(rawResponse: input)
        XCTAssertEqual(result.toolCalls.count, 1)
        XCTAssertEqual(result.toolCalls.first?.name, "list_directory")
    }
}
