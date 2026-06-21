//
//  MistralXMLParserTests.swift
//  DevgenticTests
//
//  Tests for MistralXMLParser — handles <tool_call> XML wrappers
//  and [TOOL_CALLS] array markers used by Mistral/Devstral models.
//

import XCTest
@testable import devgentic

final class MistralXMLParserTests: XCTestCase {

    private let parser = MistralXMLParser()

    // MARK: - Standard <tool_call> XML Format

    func testXML_SingleToolCall() {
        let input = """
        <tool_call>
        {"name": "list_directory", "arguments": {"path": "/tmp"}}
        </tool_call>
        """
        let result = parser.parse(rawResponse: input)
        XCTAssertEqual(result.toolCalls.count, 1)
        XCTAssertEqual(result.toolCalls.first?.name, "list_directory")
        XCTAssertEqual(result.toolCalls.first?.arguments["path"], .string("/tmp"))
    }

    func testXML_MultipleToolCalls() {
        let input = """
        <tool_call>
        {"name": "list_directory", "arguments": {"path": "/tmp"}}
        </tool_call>
        <tool_call>
        {"name": "read_file", "arguments": {"path": "/tmp/a.txt"}}
        </tool_call>
        """
        let result = parser.parse(rawResponse: input)
        XCTAssertEqual(result.toolCalls.count, 2)
        XCTAssertEqual(result.toolCalls[0].name, "list_directory")
        XCTAssertEqual(result.toolCalls[1].name, "read_file")
    }

    func testXML_WithReasoningBefore() {
        let input = """
        I need to check the directory first.
        <tool_call>
        {"name": "list_directory", "arguments": {"path": "/"}}
        </tool_call>
        """
        let result = parser.parse(rawResponse: input)
        XCTAssertEqual(result.toolCalls.count, 1)
        XCTAssertTrue(result.reasoning.contains("check the directory"))
    }

    // MARK: - Hybrid XML Format (content/tool_name/arguments tags)

    func testHybridXML_WithContentAndToolNameTags() {
        let input = """
        <tool_call>
        <content>I will search for files.</content>
        <tool_name>fs_smart_search</tool_name>
        <arguments>{"search_term": "readme"}</arguments>
        </tool_call>
        """
        let result = parser.parse(rawResponse: input)
        XCTAssertEqual(result.toolCalls.count, 1)
        XCTAssertEqual(result.toolCalls.first?.name, "fs_smart_search")
        XCTAssertEqual(result.toolCalls.first?.arguments["search_term"], .string("readme"))
        XCTAssertTrue(result.reasoning.contains("search for files"))
    }

    // MARK: - [TOOL_CALLS] Marker Format

    func testToolCallsMarker_JSONArray() {
        let input = """
        [TOOL_CALLS] [{"name": "list_directory", "arguments": {"path": "/Desktop"}}]
        """
        let result = parser.parse(rawResponse: input)
        XCTAssertEqual(result.toolCalls.count, 1)
        XCTAssertEqual(result.toolCalls.first?.name, "list_directory")
    }

    func testToolCallsMarker_MultipleTools() {
        let input = """
        [TOOL_CALLS] [
            {"name": "list_directory", "arguments": {"path": "/tmp"}},
            {"name": "fs_smart_search", "arguments": {"search_term": "config"}}
        ]
        """
        let result = parser.parse(rawResponse: input)
        XCTAssertEqual(result.toolCalls.count, 2)
    }

    // MARK: - No Tool Markers (Conversational Exit)

    func testNoMarkers_PlainText() {
        let input = "I cannot help with that request. Please try something else."
        let result = parser.parse(rawResponse: input)
        XCTAssertEqual(result.toolCalls.count, 0)
        XCTAssertTrue(result.reasoning.contains("cannot help"))
    }

    // MARK: - Edge Cases

    func testXML_StrayCharactersAfterJSON() {
        let input = """
        <tool_call>
        {"name": "read_file", "arguments": {"path": "/test.txt"}},;
        </tool_call>
        """
        let result = parser.parse(rawResponse: input)
        XCTAssertEqual(result.toolCalls.count, 1)
        XCTAssertEqual(result.toolCalls.first?.name, "read_file")
    }

    func testXML_EmptyArguments() {
        let input = """
        <tool_call>
        {"name": "recall_conversation_history", "arguments": {}}
        </tool_call>
        """
        let result = parser.parse(rawResponse: input)
        XCTAssertEqual(result.toolCalls.count, 1)
        XCTAssertEqual(result.toolCalls.first?.name, "recall_conversation_history")
        XCTAssertTrue(result.toolCalls.first?.arguments.isEmpty ?? false)
    }

    // MARK: - S7: Attribute-Style XML

    func testXML_AttributeStyle_SelfClosing() {
        // Some models emit attributes in the tag instead of JSON body
        let input = """
        <tool_call name="list_directory" path="/tmp" />
        """
        let result = parser.parse(rawResponse: input)
        XCTAssertEqual(result.toolCalls.count, 1)
        XCTAssertEqual(result.toolCalls.first?.name, "list_directory")
        XCTAssertEqual(result.toolCalls.first?.arguments["path"], .string("/tmp"))
    }

    // MARK: - S10: Multiple [TOOL_CALLS] Markers

    func testToolCallsMarker_MultipleMarkers() {
        let input = """
        [TOOL_CALLS] [{"name": "list_directory", "arguments": {"path": "/tmp"}}]
        [TOOL_CALLS] [{"name": "read_file", "arguments": {"path": "/a.txt"}}]
        """
        let result = parser.parse(rawResponse: input)
        XCTAssertEqual(result.toolCalls.count, 2)
        XCTAssertEqual(result.toolCalls[0].name, "list_directory")
        XCTAssertEqual(result.toolCalls[1].name, "read_file")
    }

    // MARK: - S9: CDATA-Wrapped JSON

    func testXML_CDATAWrappedJSON() {
        let input = """
        <tool_call>
        <![CDATA[{"name": "list_directory", "arguments": {"path": "/tmp"}}]]>
        </tool_call>
        """
        let result = parser.parse(rawResponse: input)
        XCTAssertEqual(result.toolCalls.count, 1)
        XCTAssertEqual(result.toolCalls.first?.name, "list_directory")
        XCTAssertEqual(result.toolCalls.first?.arguments["path"], .string("/tmp"))
    }

    // MARK: - #15: ReasoningQualityFilter (G7) on the with-tools path

    func testWithToolCall_StubReasoning_IsFiltered() {
        // A small/Q4 model that narrates "Calling <tool>" before its tool call must NOT leak
        // that stub into working memory — the with-tools reasoning is filtered (#15 / G7).
        let input = """
        Calling search_web
        <tool_call>
        {"name": "search_web", "arguments": {"query": "swift"}}
        </tool_call>
        """
        let result = parser.parse(rawResponse: input)
        XCTAssertEqual(result.toolCalls.count, 1)
        XCTAssertEqual(result.toolCalls.first?.name, "search_web")
        XCTAssertEqual(result.reasoning, "", "Stub narration must be filtered out of with-tools reasoning")
    }

    func testTermination_StubShapedText_IsPreserved() {
        // The no-tools path's text IS the final answer — it must never be filtered, even when
        // it happens to look stub-shaped (#15: only the with-tools reasoning is filtered).
        let input = "Using it."
        let result = parser.parse(rawResponse: input)
        XCTAssertEqual(result.toolCalls.count, 0)
        XCTAssertEqual(result.reasoning, "Using it.", "A short final answer must be preserved, not blanked")
    }
}
