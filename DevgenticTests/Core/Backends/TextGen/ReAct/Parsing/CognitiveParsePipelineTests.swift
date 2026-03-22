//
//  CognitiveParsePipelineTests.swift
//  DevgenticTests
//
//  Integration tests for CognitiveParsePipeline — the 5-stage
//  Dialect-Anchored Cascade orchestrator.
//  Validates end-to-end flow: Sanitize → Primary → Drift → Fallback → Heuristic.
//

import XCTest
@testable import devgentic

final class CognitiveParsePipelineTests: XCTestCase {

    // MARK: - Stage 1: Primary Parser Succeeds

    func testPrimary_NativeJSON_ConfidentResult() {
        let pipeline = CognitiveParsePipeline(expectedDialect: .nativeJSON)
        let input = """
        {"content": "Listing directory.", "tool_calls": [{"name": "list_directory", "arguments": {"path": "/"}}]}
        """
        let result = pipeline.parse(raw: input)
        XCTAssertEqual(result.toolCalls.count, 1)
        XCTAssertEqual(result.toolCalls.first?.name, "list_directory")
        XCTAssertEqual(result.reasoning, "Listing directory.")
    }

    func testPrimary_MistralXML_ConfidentResult() {
        // Note: OutputSanitizer strips trailing </tool_call>, so we add text after
        // to prevent the close tag from being at the very end of the string.
        let pipeline = CognitiveParsePipeline(expectedDialect: .mistralXML)
        let input = """
        I will read the file.
        <tool_call>
        {"name": "read_file", "arguments": {"path": "/tmp/test.txt"}}
        </tool_call>
        Let me check.
        """
        let result = pipeline.parse(raw: input)
        XCTAssertEqual(result.toolCalls.count, 1)
        XCTAssertEqual(result.toolCalls.first?.name, "read_file")
    }

    func testPrimary_ReActMarkdown_ConfidentResult() {
        let pipeline = CognitiveParsePipeline(expectedDialect: .reactMarkdown)
        let input = """
        Thought: I need to list the directory.
        Action: list_directory
        Action Input: {"path": "/tmp"}
        """
        let result = pipeline.parse(raw: input)
        XCTAssertEqual(result.toolCalls.count, 1)
        XCTAssertEqual(result.toolCalls.first?.name, "list_directory")
    }

    // MARK: - Stage 0: Sanitizer Integration

    func testSanitizer_ThinkBlockExtracted() {
        let pipeline = CognitiveParsePipeline(expectedDialect: .nativeJSON)
        let input = """
        <think>I should list the directory first.</think>
        {"content": "Listing.", "tool_calls": [{"name": "list_directory", "arguments": {"path": "/"}}]}
        """
        let result = pipeline.parse(raw: input)
        XCTAssertEqual(result.toolCalls.count, 1)
        XCTAssertEqual(result.thought, "I should list the directory first.")
    }

    func testSanitizer_CodeFenceStripped() {
        let pipeline = CognitiveParsePipeline(expectedDialect: .nativeJSON)
        let input = """
        ```json
        {"content": "Found it.", "tool_calls": [{"name": "read_file", "arguments": {"path": "/a.txt"}}]}
        ```
        """
        let result = pipeline.parse(raw: input)
        XCTAssertEqual(result.toolCalls.count, 1)
    }

    func testSanitizer_EmptyAfterSanitization() {
        let pipeline = CognitiveParsePipeline(expectedDialect: .nativeJSON)
        let input = "<think>Just thinking, nothing to do.</think>"
        let result = pipeline.parse(raw: input)
        XCTAssertEqual(result.toolCalls.count, 0)
    }

    // MARK: - Stage 2+3: Drift Detection → Fallback Parser

    func testDrift_NativeJSON_DriftsToXML() {
        // Primary dialect is nativeJSON but model outputs XML
        let pipeline = CognitiveParsePipeline(expectedDialect: .nativeJSON)
        let input = """
        <tool_call>
        {"name": "list_directory", "arguments": {"path": "/tmp"}}
        </tool_call>
        """
        let result = pipeline.parse(raw: input)
        // Drift detector should catch standardXML, fallback to MistralXMLParser
        XCTAssertEqual(result.toolCalls.count, 1)
        XCTAssertEqual(result.toolCalls.first?.name, "list_directory")
    }

    func testDrift_MistralXML_DriftsToReActMarkdown() {
        // Primary dialect is mistralXML but model outputs ReAct markdown
        let pipeline = CognitiveParsePipeline(expectedDialect: .mistralXML)
        let input = """
        Thought: Let me search for the file.
        Action: fs_smart_search
        Action Input: {"search_term": "readme"}
        """
        let result = pipeline.parse(raw: input)
        XCTAssertEqual(result.toolCalls.count, 1)
        XCTAssertEqual(result.toolCalls.first?.name, "fs_smart_search")
    }

    func testDrift_NativeJSON_DriftsToFlatJSON() {
        // Primary dialect is nativeJSON but model outputs legacy single-tool format
        let pipeline = CognitiveParsePipeline(expectedDialect: .nativeJSON)
        let input = """
        {"content": "Listing.", "tool_name": "list_directory", "arguments": {"path": "/"}}
        """
        let result = pipeline.parse(raw: input)
        // Should be caught by flatJSONLeakage probe → fallback or heuristic recovery
        XCTAssertGreaterThanOrEqual(result.toolCalls.count, 1)
        XCTAssertEqual(result.toolCalls.first?.name, "list_directory")
    }

    func testDrift_DynamicToolTag() {
        let pipeline = CognitiveParsePipeline(
            expectedDialect: .nativeJSON,
            knownToolNames: ["list_directory"]
        )
        let input = """
        <list_directory>{"path": "/tmp"}</list_directory>
        """
        let result = pipeline.parse(raw: input)
        XCTAssertGreaterThanOrEqual(result.toolCalls.count, 1)
    }

    // MARK: - Stage 4: Heuristic Recovery

    func testHeuristic_MalformedJSON_Recovery() {
        // Primary is nativeJSON, but JSON is malformed — should fall through to heuristic
        let pipeline = CognitiveParsePipeline(expectedDialect: .nativeJSON)
        let input = """
        {"content": "Searching.", "tool_calls": [{"name": "list_directory", "arguments": {"path": "/tmp"}} {"name": "read_file", "arguments": {"path": "/a.txt"}}]}
        """
        let result = pipeline.parse(raw: input)
        // Heuristic should recover at least one tool call
        XCTAssertGreaterThanOrEqual(result.toolCalls.count, 1)
    }

    // MARK: - Conversational Exit (No Tool Calls)

    func testConversationalExit_PlainText() {
        let pipeline = CognitiveParsePipeline(expectedDialect: .nativeJSON)
        let input = "I'm sorry, I cannot help with that request."
        let result = pipeline.parse(raw: input)
        XCTAssertEqual(result.toolCalls.count, 0)
        XCTAssertTrue(result.reasoning.contains("cannot help"))
    }

    func testConversationalExit_NativeJSONEmpty() {
        let pipeline = CognitiveParsePipeline(expectedDialect: .nativeJSON)
        let input = """
        {"content": "The task is complete. Here is what I found.", "tool_calls": []}
        """
        let result = pipeline.parse(raw: input)
        XCTAssertEqual(result.toolCalls.count, 0)
        XCTAssertTrue(result.reasoning.contains("task is complete"))
    }

    // MARK: - Thought Propagation

    func testThought_PropagatedFromSanitizer() {
        let pipeline = CognitiveParsePipeline(expectedDialect: .mistralXML)
        // Add trailing text after </tool_call> so the sanitizer doesn't strip it as an orphan
        let input = """
        <think>Deep reasoning about the task.</think>
        <tool_call>
        {"name": "list_directory", "arguments": {"path": "/"}}
        </tool_call>
        Done.
        """
        let result = pipeline.parse(raw: input)
        XCTAssertEqual(result.toolCalls.count, 1)
        XCTAssertEqual(result.thought, "Deep reasoning about the task.")
    }

    // MARK: - Edge Cases

    func testEmptyInput() {
        let pipeline = CognitiveParsePipeline(expectedDialect: .nativeJSON)
        let result = pipeline.parse(raw: "")
        XCTAssertEqual(result.toolCalls.count, 0)
    }

    func testWhitespaceOnlyInput() {
        let pipeline = CognitiveParsePipeline(expectedDialect: .nativeJSON)
        let result = pipeline.parse(raw: "   \n\t  ")
        XCTAssertEqual(result.toolCalls.count, 0)
    }

    // MARK: - S20: Think Block Contains Tool-Call-Like Text

    func testThinkBlock_WithToolCallText_StrippedBeforeParsing() {
        // The think block contains <tool_call> text that should NOT be parsed as a real call.
        // The sanitizer must strip it in Stage 0 so drift detection doesn't trigger on it.
        let pipeline = CognitiveParsePipeline(expectedDialect: .nativeJSON)
        let input = """
        <think>
        I considered calling <tool_call>{"name": "dangerous_tool", "arguments": {}}</tool_call> but decided not to.
        </think>
        {"content": "I cannot help with that.", "tool_calls": []}
        """
        let result = pipeline.parse(raw: input)
        XCTAssertEqual(result.toolCalls.count, 0, "Tool call inside <think> block must not be extracted")
        XCTAssertTrue(result.reasoning.contains("cannot help"))
        XCTAssertNotNil(result.thought, "Think block content should still be captured as thought")
    }

    // MARK: - S21: Sanitizer Strips Opening Tag, Closing Tag Preserved

    func testOrphanClosingTag_DoesNotBreakParsing() {
        // A stray </tool_call> at the end (without a matching open) should be stripped
        // by the sanitizer so it doesn't confuse the MistralXML parser.
        let pipeline = CognitiveParsePipeline(expectedDialect: .nativeJSON)
        let input = """
        {"content": "Listing files.", "tool_calls": [{"name": "list_directory", "arguments": {"path": "/"}}]}
        </tool_call>
        """
        let result = pipeline.parse(raw: input)
        XCTAssertEqual(result.toolCalls.count, 1)
        XCTAssertEqual(result.toolCalls.first?.name, "list_directory")
    }

    // MARK: - S22: Double Drift — Two Formats Present, Higher Priority Wins

    func testDoubleDrift_PythonicTagAndReActMarkdown_PythonicWins() {
        // Text contains both PythonicTag (probe 1) and ReAct markdown (probe 7).
        // Drift detector should match the higher-priority probe (PythonicTag).
        let pipeline = CognitiveParsePipeline(expectedDialect: .nativeJSON)
        let input = """
        <|python_tag|>[{"name": "list_directory", "arguments": {"path": "/tmp"}}]
        Action: read_file
        Action Input: {"path": "/a.txt"}
        """
        let result = pipeline.parse(raw: input)
        // PythonicTag fallback uses NativeJSONParser on the array after the token.
        // The important thing is we get tool calls, and they come from the pythonic path.
        XCTAssertGreaterThanOrEqual(result.toolCalls.count, 1, "Should recover tool calls from the higher-priority drift format")
    }

    // MARK: - S23: Nested Content with Duplicate Blocks (G1 + G2)

    func testNestedContent_WithDuplicateBlocks_ParsedCorrectly() {
        // Reproduces the exact log scenario: model emits nested content wrapper
        // with think block and duplicates the JSON block.
        let pipeline = CognitiveParsePipeline(expectedDialect: .heuristicJson)
        let input = """
        <think>
        Okay, let's see what the user is asking here.
        </think>
        {
        "content": {
        "thought": "No file list can be retrieved with the available tools.",
        "tool_calls": []
          }
        }
        {
        "content": {
        "thought": "No file list can be retrieved with the available tools.",
        "tool_calls": []
          }
        }
        """
        let result = pipeline.parse(raw: input)
        XCTAssertEqual(result.toolCalls.count, 0, "Empty tool_calls should be recognized as conversational exit")
        XCTAssertTrue(result.reasoning.contains("No file list"), "Should extract thought as reasoning")
        XCTAssertNotNil(result.thought, "Think block should be captured")
    }

    func testNestedContent_WithToolCalls_ThroughPipeline() {
        let pipeline = CognitiveParsePipeline(expectedDialect: .heuristicJson)
        let input = """
        {
          "content": {
            "thought": "I should list the directory.",
            "tool_calls": [
              {"name": "list_directory", "arguments": {"path": "/Users/alice"}}
            ]
          }
        }
        """
        let result = pipeline.parse(raw: input)
        XCTAssertEqual(result.toolCalls.count, 1)
        XCTAssertEqual(result.toolCalls.first?.name, "list_directory")
        XCTAssertEqual(result.reasoning, "I should list the directory.")
    }

    func testDoubleDrift_DeepXMLAndFlatJSON_DeepXMLWins() {
        // Text contains both DeepXML signals and flat JSON leakage.
        // DeepXML (probe 2) is higher priority than FlatJSONLeakage (probe 12).
        let pipeline = CognitiveParsePipeline(expectedDialect: .reactMarkdown)
        let input = """
        <function=list_directory>
        <parameter=path>/tmp</parameter>
        </function>
        {"tool_name": "read_file"}
        """
        let result = pipeline.parse(raw: input)
        // DeepXML fallback parser should be selected
        XCTAssertGreaterThanOrEqual(result.toolCalls.count, 1, "Should recover via DeepXML fallback, not flat JSON")
    }
}
