// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
//
//  ReActMarkdownParserTests.swift
//  DevgenticTests
//
//  Tests for ReActMarkdownParser — handles the classic
//  Thought / Action / Action Input format used by Llama and similar models.
//

import XCTest
@testable import devgentic

final class ReActMarkdownParserTests: XCTestCase {

    private let parser = ReActMarkdownParser()

    // MARK: - Standard Format

    func testStandard_ThoughtActionInput() {
        let input = """
        Thought: I need to list the directory contents.
        Action: list_directory
        Action Input: {"path": "/tmp"}
        """
        let result = parser.parse(rawResponse: input)
        XCTAssertEqual(result.toolCalls.count, 1)
        XCTAssertEqual(result.toolCalls.first?.name, "list_directory")
        XCTAssertEqual(result.toolCalls.first?.arguments["path"], .string("/tmp"))
        XCTAssertTrue(result.reasoning.contains("list the directory"))
    }

    func testStandard_ComplexArguments() {
        let input = """
        Thought: I will create a new file with some content.
        Action: create_or_update_file
        Action Input: {"path": "/tmp/test.txt", "content": "Hello World", "overwrite": true}
        """
        let result = parser.parse(rawResponse: input)
        XCTAssertEqual(result.toolCalls.count, 1)
        XCTAssertEqual(result.toolCalls.first?.name, "create_or_update_file")
        XCTAssertEqual(result.toolCalls.first?.arguments["content"], .string("Hello World"))
        XCTAssertEqual(result.toolCalls.first?.arguments["overwrite"], .bool(true))
    }

    func testStandard_EmptyArguments() {
        let input = """
        Thought: I need to recall context.
        Action: recall_conversation_history
        Action Input: {}
        """
        let result = parser.parse(rawResponse: input)
        XCTAssertEqual(result.toolCalls.count, 1)
        XCTAssertEqual(result.toolCalls.first?.name, "recall_conversation_history")
        XCTAssertTrue(result.toolCalls.first?.arguments.isEmpty ?? false)
    }

    // MARK: - Reasoning Keyword Variants

    func testReasoningKeyword_InsteadOfThought() {
        let input = """
        Reasoning: Let me search for the file first.
        Action: fs_smart_search
        Action Input: {"search_term": "config"}
        """
        let result = parser.parse(rawResponse: input)
        XCTAssertEqual(result.toolCalls.count, 1)
        XCTAssertEqual(result.toolCalls.first?.name, "fs_smart_search")
        XCTAssertTrue(result.reasoning.contains("search for the file"))
    }

    // MARK: - Termination Signals

    func testTermination_ActionNone() {
        let input = """
        Thought: The task is complete.
        Action: None
        """
        let result = parser.parse(rawResponse: input)
        XCTAssertEqual(result.toolCalls.count, 0)
        XCTAssertTrue(result.reasoning.contains("task is complete"))
    }

    func testTermination_ActionFinish() {
        let input = """
        Thought: I have finished the task.
        Action: finish
        """
        let result = parser.parse(rawResponse: input)
        XCTAssertEqual(result.toolCalls.count, 0)
    }

    func testTermination_ActionDone() {
        let input = """
        Thought: All done.
        Action: done
        """
        let result = parser.parse(rawResponse: input)
        XCTAssertEqual(result.toolCalls.count, 0)
    }

    func testTermination_NoActionField() {
        let input = """
        Thought: I cannot help with that request. Let me explain what I found.
        """
        let result = parser.parse(rawResponse: input)
        XCTAssertEqual(result.toolCalls.count, 0)
        XCTAssertTrue(result.reasoning.contains("cannot help"))
    }

    func testTermination_FinalAnswer() {
        let input = """
        Thought: I know the answer now.
        Final Answer: The capital of France is Paris.
        """
        let result = parser.parse(rawResponse: input)
        XCTAssertEqual(result.toolCalls.count, 0)
        XCTAssertTrue(result.reasoning.contains("capital of France"))
    }

    // MARK: - Missing Action Input

    func testMissingActionInput_ReturnsEmptyArgs() {
        let input = """
        Thought: Let me check.
        Action: list_directory
        """
        let result = parser.parse(rawResponse: input)
        // No Action Input → should still parse the action but with empty arguments
        XCTAssertEqual(result.toolCalls.count, 1)
        XCTAssertEqual(result.toolCalls.first?.name, "list_directory")
        XCTAssertTrue(result.toolCalls.first?.arguments.isEmpty ?? false)
    }

    // MARK: - Markdown Fence in Action Input

    func testMarkdownFence_InActionInput() {
        let input = """
        Thought: Creating a file.
        Action: create_or_update_file
        Action Input: ```json
        {"path": "/tmp/hello.txt", "content": "hi"}
        ```
        """
        let result = parser.parse(rawResponse: input)
        XCTAssertEqual(result.toolCalls.count, 1)
        XCTAssertEqual(result.toolCalls.first?.arguments["path"], .string("/tmp/hello.txt"))
    }

    // MARK: - Trailing Text After Action Input

    func testTrailingText_AfterActionInput() {
        let input = """
        Thought: Let me list the files.
        Action: list_directory
        Action Input: {"path": "/home"}
        This should complete the task.
        """
        let result = parser.parse(rawResponse: input)
        XCTAssertEqual(result.toolCalls.count, 1)
        XCTAssertEqual(result.toolCalls.first?.arguments["path"], .string("/home"))
    }

    // MARK: - S12: Observation Boundary

    func testObservation_StopsActionInput() {
        // Action Input should stop at "Observation:" to avoid contamination
        let input = """
        Thought: Let me check.
        Action: list_directory
        Action Input: {"path": "/tmp"}
        Observation: file1.txt, file2.txt
        """
        let result = parser.parse(rawResponse: input)
        XCTAssertEqual(result.toolCalls.count, 1)
        XCTAssertEqual(result.toolCalls.first?.arguments["path"], .string("/tmp"))
        // Observation text should NOT leak into arguments
    }

    // MARK: - S13: Backtick-Wrapped Tool Name

    func testBacktickWrapped_ToolName() {
        let input = """
        Thought: I need to list the directory.
        Action: `list_directory`
        Action Input: {"path": "/tmp"}
        """
        let result = parser.parse(rawResponse: input)
        XCTAssertEqual(result.toolCalls.count, 1)
        XCTAssertEqual(result.toolCalls.first?.name, "list_directory")
        XCTAssertEqual(result.toolCalls.first?.arguments["path"], .string("/tmp"))
    }

    func testQuoteWrapped_ToolName() {
        let input = """
        Thought: Reading a file.
        Action: "read_file"
        Action Input: {"path": "/a.txt"}
        """
        let result = parser.parse(rawResponse: input)
        XCTAssertEqual(result.toolCalls.count, 1)
        XCTAssertEqual(result.toolCalls.first?.name, "read_file")
    }

    // MARK: - Edge Cases

    func testPlainText_NoReActFormat() {
        let input = "Here is what I found in the directory listing."
        let result = parser.parse(rawResponse: input)
        XCTAssertEqual(result.toolCalls.count, 0)
        XCTAssertTrue(result.reasoning.contains("directory listing"))
    }

    func testEmptyString() {
        let result = parser.parse(rawResponse: "")
        XCTAssertEqual(result.toolCalls.count, 0)
    }

    func testCaseInsensitive_ActionKeywords() {
        let input = """
        thought: checking the directory.
        action: list_directory
        action input: {"path": "/"}
        """
        let result = parser.parse(rawResponse: input)
        XCTAssertEqual(result.toolCalls.count, 1)
        XCTAssertEqual(result.toolCalls.first?.name, "list_directory")
    }

    // MARK: - #15: ReasoningQualityFilter (G7) on the with-tools path

    func testWithToolCall_StubThought_IsFiltered() {
        // A stub Thought ("Calling <tool>") emitted alongside a tool call must be filtered so it
        // doesn't pollute the working-memory scratchpad (#15 / G7).
        let input = """
        Thought: Calling list_directory
        Action: list_directory
        Action Input: {"path": "/tmp"}
        """
        let result = parser.parse(rawResponse: input)
        XCTAssertEqual(result.toolCalls.count, 1)
        XCTAssertEqual(result.toolCalls.first?.name, "list_directory")
        XCTAssertEqual(result.reasoning, "", "Stub thought must be filtered out of with-tools reasoning")
    }

    func testTermination_StubShapedAnswer_IsPreserved() {
        // The termination text IS the final answer — never filtered, even if it looks stub-shaped.
        let input = """
        Thought: Using it.
        Action: None
        """
        let result = parser.parse(rawResponse: input)
        XCTAssertEqual(result.toolCalls.count, 0)
        XCTAssertEqual(result.reasoning, "Using it.", "A short final answer must be preserved")
    }

    func testWithToolCall_RealReasoningStartingLikeStub_IsPreserved() {
        // The filter is anchored + length-gated: a real sentence that merely STARTS like a stub
        // must pass through untouched (guards against over-filtering).
        let input = """
        Thought: Calling the search API will let me verify the exact version before editing.
        Action: search_web
        Action Input: {"query": "version"}
        """
        let result = parser.parse(rawResponse: input)
        XCTAssertEqual(result.toolCalls.count, 1)
        XCTAssertTrue(result.reasoning.contains("verify the exact version"),
                      "Real reasoning that starts like a stub must be preserved")
    }
}
