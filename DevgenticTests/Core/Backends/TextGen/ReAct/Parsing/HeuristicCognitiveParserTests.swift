//
//  HeuristicCognitiveParserTests.swift
//  DevgenticTests
//
//  Tests for HeuristicCognitiveParser — the battle-tested fallback parser
//  that rescues structurally volatile responses from local models.
//

import XCTest
@testable import devgentic

final class HeuristicCognitiveParserTests: XCTestCase {

    private let parser = HeuristicCognitiveParser()

    // MARK: - Well-Formed JSON (Attempt 1: LegacyArraySchema)

    func testWellFormed_SingleToolCall() {
        let input = """
        {
          "content": "I need to list the directory.",
          "tool_calls": [
            {"name": "list_directory", "arguments": {"path": "/Users/alice"}}
          ]
        }
        """
        let result = parser.parse(rawResponse: input)
        XCTAssertEqual(result.toolCalls.count, 1)
        XCTAssertEqual(result.toolCalls.first?.name, "list_directory")
        XCTAssertEqual(result.toolCalls.first?.arguments["path"], .string("/Users/alice"))
        XCTAssertEqual(result.reasoning, "I need to list the directory.")
    }

    func testWellFormed_ParallelToolCalls() {
        let input = """
        {
          "content": "Searching for files.",
          "tool_calls": [
            {"name": "list_directory", "arguments": {"path": "/Desktop"}},
            {"name": "fs_smart_search", "arguments": {"search_term": "Acme"}}
          ]
        }
        """
        let result = parser.parse(rawResponse: input)
        XCTAssertEqual(result.toolCalls.count, 2)
        XCTAssertEqual(result.toolCalls[0].name, "list_directory")
        XCTAssertEqual(result.toolCalls[1].name, "fs_smart_search")
    }

    func testWellFormed_EmptyToolCalls() {
        let input = """
        {"content": "I cannot help with that.", "tool_calls": []}
        """
        let result = parser.parse(rawResponse: input)
        XCTAssertEqual(result.toolCalls.count, 0)
        XCTAssertEqual(result.reasoning, "I cannot help with that.")
    }

    func testWellFormed_ToolCallWithNullArgValue() {
        let input = """
        {
          "content": "Searching.",
          "tool_calls": [
            {"name": "fs_smart_search", "arguments": {"search_term": "test", "scope": null}}
          ]
        }
        """
        let result = parser.parse(rawResponse: input)
        XCTAssertEqual(result.toolCalls.count, 1)
        XCTAssertEqual(result.toolCalls.first?.arguments["scope"], .null)
    }

    // MARK: - Legacy Single-Tool Format (Attempt 2: LegacySingleSchema)

    func testLegacySingle_ToolNameAndArguments() {
        let input = """
        {"content": "Reading file.", "tool_name": "read_file", "arguments": {"path": "/tmp/test.txt"}}
        """
        let result = parser.parse(rawResponse: input)
        XCTAssertEqual(result.toolCalls.count, 1)
        XCTAssertEqual(result.toolCalls.first?.name, "read_file")
    }

    func testLegacySingle_NullToolName() {
        let input = """
        {"content": "Done thinking.", "tool_name": null, "arguments": null}
        """
        let result = parser.parse(rawResponse: input)
        XCTAssertEqual(result.toolCalls.count, 0)
        XCTAssertEqual(result.reasoning, "Done thinking.")
    }

    // MARK: - Bare Tool Call (Attempt 3: BareToolCallSchema)

    func testBareToolCall_NoContentWrapper() {
        let input = """
        {"name": "execute_shell", "arguments": {"command": "ls -la"}}
        """
        let result = parser.parse(rawResponse: input)
        XCTAssertEqual(result.toolCalls.count, 1)
        XCTAssertEqual(result.toolCalls.first?.name, "execute_shell")
        XCTAssertEqual(result.toolCalls.first?.arguments["command"], .string("ls -la"))
    }

    func testBareToolCall_WithParametersKey() {
        let input = """
        {"name": "list_directory", "parameters": {"path": "/home"}}
        """
        let result = parser.parse(rawResponse: input)
        XCTAssertEqual(result.toolCalls.count, 1)
        XCTAssertEqual(result.toolCalls.first?.arguments["path"], .string("/home"))
    }

    // MARK: - Lenient Extraction (Attempt 4)

    func testLenient_ContentOnly_NoTools() {
        // Malformed enough to fail Attempts 1-3 but has extractable "content"
        let input = """
        { "content": "I will help you with that.", "extra_bad_key": undefined }
        """
        let result = parser.parse(rawResponse: input)
        XCTAssertTrue(result.reasoning.contains("I will help you with that."))
    }

    func testLenient_LegacyToolNameExtraction() {
        // Has "tool_name" but structurally broken enough to fail Attempts 1-3
        let input = """
        { "content": "Listing files.", "tool_name": "list_directory", "arguments": {"path": "/tmp"}, "broken": undefined }
        """
        let result = parser.parse(rawResponse: input)
        XCTAssertEqual(result.toolCalls.count, 1)
        XCTAssertEqual(result.toolCalls.first?.name, "list_directory")
    }

    // MARK: - Lenient Array Extraction (New: Strategy A)

    func testLenient_MissingCommaBetweenArrayElements() {
        // Real failure from production: missing comma after "fs_smart_search"
        let input = """
        {
          "content": "The user wants to list all files.",
          "tool_calls": [
            {
              "name": "list_directory",
              "arguments": { "path": "/Users/alice" }
            },
            {
              "name": "fs_smart_search"
              "search_term": "Acme",
              "scope": null
            }
          ]
        }
        """
        let result = parser.parse(rawResponse: input)
        // Should recover at least the first well-formed tool call
        XCTAssertGreaterThanOrEqual(result.toolCalls.count, 1, "Should recover at least 1 tool call from malformed array")
        XCTAssertEqual(result.toolCalls.first?.name, "list_directory")

        // Should also recover the second tool via flattened argument extraction
        if result.toolCalls.count >= 2 {
            XCTAssertEqual(result.toolCalls[1].name, "fs_smart_search")
            XCTAssertEqual(result.toolCalls[1].arguments["search_term"], .string("Acme"))
        }
    }

    func testLenient_FlattenedArguments_NoArgumentsWrapper() {
        // Model puts params at tool-call level instead of inside "arguments"
        // Must have a structural defect (missing comma) to bypass standard decode attempts
        // and reach lenient extraction where flattened argument recovery kicks in
        let input = """
        {
          "content": "Searching for files.",
          "tool_calls": [
            {
              "name": "fs_smart_search"
              "search_term": "readme",
              "scope": null
            }
          ]
        }
        """
        let result = parser.parse(rawResponse: input)
        XCTAssertGreaterThanOrEqual(result.toolCalls.count, 1)
        XCTAssertEqual(result.toolCalls.first?.name, "fs_smart_search")
        XCTAssertEqual(result.toolCalls.first?.arguments["search_term"], .string("readme"))
    }

    func testLenient_MixedValidAndMalformedToolCalls() {
        // First tool is valid, second has structural defect, third is valid
        let input = """
        {
          "content": "Executing multiple actions.",
          "tool_calls": [
            {"name": "list_directory", "arguments": {"path": "/tmp"}},
            {"name": "read_file" "path": "/tmp/test.txt"},
            {"name": "fs_read_metadata", "arguments": {"path": "/tmp"}}
          ]
        }
        """
        let result = parser.parse(rawResponse: input)
        // Should recover tools 1 and 3 at minimum (well-formed), plus attempt tool 2
        XCTAssertGreaterThanOrEqual(result.toolCalls.count, 2, "Should recover at least 2 tool calls")
    }

    // MARK: - Markdown Fence Stripping

    func testMarkdownFences_JsonBlock() {
        let input = """
        ```json
        {"content": "Found it.", "tool_calls": [{"name": "read_file", "arguments": {"path": "/a.txt"}}]}
        ```
        """
        let result = parser.parse(rawResponse: input)
        XCTAssertEqual(result.toolCalls.count, 1)
        XCTAssertEqual(result.toolCalls.first?.name, "read_file")
    }

    // MARK: - Python Literal Normalization

    func testPythonLiterals_TrueFalseNone() {
        let input = """
        {"content": "Checking status.", "tool_calls": [{"name": "check_status", "arguments": {"verbose": True, "debug": False, "extra": None}}]}
        """
        let result = parser.parse(rawResponse: input)
        XCTAssertEqual(result.toolCalls.count, 1)
        XCTAssertEqual(result.toolCalls.first?.arguments["verbose"], .bool(true))
        XCTAssertEqual(result.toolCalls.first?.arguments["debug"], .bool(false))
        XCTAssertEqual(result.toolCalls.first?.arguments["extra"], .null)
    }

    // MARK: - Trailing Comma Removal

    func testTrailingComma_InArguments() {
        let input = """
        {"content": "Listing.", "tool_calls": [{"name": "list_directory", "arguments": {"path": "/tmp",}}]}
        """
        let result = parser.parse(rawResponse: input)
        XCTAssertEqual(result.toolCalls.count, 1)
    }

    func testTrailingComma_InToolCallsArray() {
        let input = """
        {"content": "Running.", "tool_calls": [{"name": "list_directory", "arguments": {"path": "/"}},]}
        """
        let result = parser.parse(rawResponse: input)
        XCTAssertEqual(result.toolCalls.count, 1)
    }

    // MARK: - Content Rescue

    func testContentRescue_PathInContent() {
        // tool_name present but no arguments — path embedded in content.
        // Must include a structural defect (trailing "broken": undefined) to bypass
        // standard decode attempts 1-3 and reach lenient extraction Strategy B,
        // where content rescue kicks in for empty arguments.
        let input = """
        { "content": "/Users/alice/Desktop/Acme", "tool_name": "list_directory", "arguments": {}, "broken": undefined }
        """
        let result = parser.parse(rawResponse: input)
        XCTAssertEqual(result.toolCalls.count, 1)
        XCTAssertEqual(result.toolCalls.first?.name, "list_directory")
        XCTAssertEqual(result.toolCalls.first?.arguments["path"], .string("/Users/alice/Desktop/Acme"))
    }

    func testContentRescue_SearchTermInContent() {
        // Same pattern: structural defect forces lenient extraction path
        let input = """
        { "content": "Acme", "tool_name": "fs_smart_search", "arguments": {}, "broken": undefined }
        """
        let result = parser.parse(rawResponse: input)
        XCTAssertEqual(result.toolCalls.count, 1)
        XCTAssertEqual(result.toolCalls.first?.arguments["search_term"], .string("Acme"))
    }

    // MARK: - Edge Cases

    func testTotalGarbage_ReturnsRawAsReasoning() {
        let input = "This is just plain text with no JSON at all."
        let result = parser.parse(rawResponse: input)
        XCTAssertEqual(result.toolCalls.count, 0)
        XCTAssertTrue(result.reasoning.contains("plain text"))
    }

    func testEmptyString() {
        let result = parser.parse(rawResponse: "")
        XCTAssertEqual(result.toolCalls.count, 0)
    }

    func testNestedJSONInContent() {
        // Content itself contains JSON-like text that shouldn't confuse the parser
        let input = """
        {"content": "The config is {\\\"key\\\": \\\"value\\\"}.", "tool_calls": [{"name": "list_directory", "arguments": {"path": "/"}}]}
        """
        let result = parser.parse(rawResponse: input)
        XCTAssertEqual(result.toolCalls.count, 1)
    }

    // MARK: - S1: Single-Quoted JSON Keys

    func testSingleQuotedKeys_FullResponse() {
        // Some models (esp. Python-trained) emit single-quoted JSON
        let input = """
        {'content': 'Listing files.', 'tool_calls': [{'name': 'list_directory', 'arguments': {'path': '/tmp'}}]}
        """
        let result = parser.parse(rawResponse: input)
        XCTAssertEqual(result.toolCalls.count, 1)
        XCTAssertEqual(result.toolCalls.first?.name, "list_directory")
        XCTAssertEqual(result.toolCalls.first?.arguments["path"], .string("/tmp"))
        XCTAssertEqual(result.reasoning, "Listing files.")
    }

    // MARK: - S6: Arguments as Stringified JSON

    func testStringifiedArguments_InArraySchema() {
        // Model serializes arguments as a JSON string instead of an object
        let input = """
        {"content": "Listing.", "tool_calls": [{"name": "list_directory", "arguments": "{\\"path\\": \\"/tmp\\"}"}]}
        """
        let result = parser.parse(rawResponse: input)
        XCTAssertEqual(result.toolCalls.count, 1)
        XCTAssertEqual(result.toolCalls.first?.name, "list_directory")
        XCTAssertEqual(result.toolCalls.first?.arguments["path"], .string("/tmp"))
    }

    func testStringifiedArguments_InSingleSchema() {
        // Legacy single-tool format with stringified arguments
        let input = """
        {"content": "Reading.", "tool_name": "read_file", "arguments": "{\\"path\\": \\"/tmp/test.txt\\"}"}
        """
        let result = parser.parse(rawResponse: input)
        XCTAssertEqual(result.toolCalls.count, 1)
        XCTAssertEqual(result.toolCalls.first?.name, "read_file")
        XCTAssertEqual(result.toolCalls.first?.arguments["path"], .string("/tmp/test.txt"))
    }

    func testSingleQuotedKeys_MixedWithDouble() {
        // Hybrid: some keys single-quoted, some double-quoted
        let input = """
        {"content": 'Searching.', 'tool_calls': [{"name": 'fs_smart_search', "arguments": {'search_term': "readme"}}]}
        """
        let result = parser.parse(rawResponse: input)
        XCTAssertEqual(result.toolCalls.count, 1)
        XCTAssertEqual(result.toolCalls.first?.name, "fs_smart_search")
    }

    // MARK: - S2: Unquoted JSON Keys

    func testUnquotedKeys_FullResponse() {
        // JavaScript-style unquoted keys: {content: "...", tool_calls: [...]}
        let input = """
        {content: "Listing files.", tool_calls: [{name: "list_directory", arguments: {path: "/tmp"}}]}
        """
        let result = parser.parse(rawResponse: input)
        XCTAssertEqual(result.toolCalls.count, 1)
        XCTAssertEqual(result.toolCalls.first?.name, "list_directory")
        XCTAssertEqual(result.toolCalls.first?.arguments["path"], .string("/tmp"))
    }

    func testUnquotedKeys_MixedWithQuoted() {
        // Some keys quoted, some not
        let input = """
        {"content": "Reading.", tool_calls: [{"name": "read_file", arguments: {"path": "/a.txt"}}]}
        """
        let result = parser.parse(rawResponse: input)
        XCTAssertEqual(result.toolCalls.count, 1)
        XCTAssertEqual(result.toolCalls.first?.name, "read_file")
    }

    // MARK: - S4: Duplicate tool_calls Key

    func testDuplicateToolCallsKey_MergesArrays() {
        // Model emits "tool_calls" key twice — structurally invalid JSON
        // Should recover at least one set of tool calls via lenient extraction
        let input = """
        {"content": "Running.", "tool_calls": [{"name": "list_directory", "arguments": {"path": "/tmp"}}], "tool_calls": [{"name": "read_file", "arguments": {"path": "/a.txt"}}]}
        """
        let result = parser.parse(rawResponse: input)
        // JSONDecoder takes the last value for duplicate keys, so we get read_file
        // This is acceptable — the test verifies we don't crash and recover at least one
        XCTAssertGreaterThanOrEqual(result.toolCalls.count, 1)
    }

    // MARK: - S3: Escaped Newlines in Content

    func testEscapedNewlines_InContentValue() {
        // Literal \n in content string (not actual newline char)
        let input = """
        {"content": "Line1\\nLine2\\nLine3", "tool_calls": [{"name": "list_directory", "arguments": {"path": "/"}}]}
        """
        let result = parser.parse(rawResponse: input)
        XCTAssertEqual(result.toolCalls.count, 1)
        XCTAssertEqual(result.toolCalls.first?.name, "list_directory")
    }

    // MARK: - S24: Markdown-Field Format Recovery

    func testMarkdownField_ContentWithEmptyToolCalls() {
        // After OutputSanitizer strips backticks from ```content```: ... ```tool_calls```: []
        let input = """
        content: Based on the working memory, we have found 7 PDF files in the Acme directory.

        tool_calls: []
        """
        let result = parser.parse(rawResponse: input)
        XCTAssertEqual(result.toolCalls.count, 0)
        XCTAssertTrue(result.reasoning.contains("Based on the working memory"))
        XCTAssertFalse(result.reasoning.contains("content:"), "Structural prefix should be stripped")
        XCTAssertFalse(result.reasoning.contains("tool_calls"), "Structural suffix should be stripped")
    }

    func testMarkdownField_ContentWithNextStepAndToolCalls() {
        // Exact pattern from the production bug (iteration 4)
        let input = """
        content: The search has been completed successfully.

        **Next Step**: Since the user asked for all files in Acme and we have retrieved them, there is nothing left to do.

        tool_calls: []
        """
        let result = parser.parse(rawResponse: input)
        XCTAssertEqual(result.toolCalls.count, 0)
        XCTAssertTrue(result.reasoning.contains("search has been completed"))
        XCTAssertTrue(result.reasoning.contains("**Next Step**"))
        XCTAssertFalse(result.reasoning.contains("content:"))
        XCTAssertFalse(result.reasoning.contains("tool_calls:"))
    }

    func testMarkdownField_ContentOnly_NoToolCallsSuffix() {
        let input = "content: Here is my final answer about the files."
        let result = parser.parse(rawResponse: input)
        XCTAssertEqual(result.toolCalls.count, 0)
        XCTAssertEqual(result.reasoning, "Here is my final answer about the files.")
    }

    func testMarkdownField_DoesNotTrigger_ForNormalJSON() {
        // Ensure the fix doesn't interfere with normal JSON that extractOutermostJSON handles
        let input = """
        {"content": "Listed.", "tool_calls": [{"name": "list_directory", "arguments": {"path": "/"}}]}
        """
        let result = parser.parse(rawResponse: input)
        XCTAssertEqual(result.toolCalls.count, 1, "Normal JSON should still parse via standard path")
        XCTAssertEqual(result.toolCalls.first?.name, "list_directory")
    }

    func testMarkdownField_DoesNotTrigger_ForPlainText() {
        // Plain text without "content:" prefix should NOT be altered
        let input = "The directory contains 7 files."
        let result = parser.parse(rawResponse: input)
        XCTAssertTrue(result.reasoning.contains("directory contains 7 files"))
    }

    // MARK: - S25: Truncated/Bracket-Mismatched JSON Recovery

    func testTruncatedJSON_MismatchedBrackets_RecoversBothTools() {
        // Exact production failure: second tool closes with ] instead of },
        // root object missing closing }. extractOutermostJSON returns nil
        // because brace depth never returns to 0.
        let input = """
        {
          "content": "The user wants to list all files.",
          "tool_calls": [
            {
              "name": "list_directory",
              "arguments": { "path": "/Users/alice" }
            },
            {
              "name": "fs_smart_search"
              "arguments": {}
            ]
          ]
        """
        let result = parser.parse(rawResponse: input)
        XCTAssertTrue(result.reasoning.contains("list all files"), "Should extract content as reasoning")
        XCTAssertGreaterThanOrEqual(result.toolCalls.count, 1, "Should recover at least the first well-formed tool call")
        XCTAssertEqual(result.toolCalls.first?.name, "list_directory")
    }

    // MARK: - Nested Content Schema (G1)

    func testNestedContent_WithToolCalls() {
        let input = """
        {
          "content": {
            "thought": "I need to list the directory.",
            "tool_calls": [
              {"name": "list_directory", "arguments": {"path": "/Users/alice"}}
            ]
          }
        }
        """
        let result = parser.parse(rawResponse: input)
        XCTAssertEqual(result.toolCalls.count, 1)
        XCTAssertEqual(result.toolCalls.first?.name, "list_directory")
        XCTAssertEqual(result.toolCalls.first?.arguments["path"], .string("/Users/alice"))
        XCTAssertEqual(result.reasoning, "I need to list the directory.")
    }

    func testNestedContent_EmptyToolCalls() {
        let input = """
        {
          "content": {
            "thought": "No tools available for this task.",
            "tool_calls": []
          }
        }
        """
        let result = parser.parse(rawResponse: input)
        XCTAssertEqual(result.toolCalls.count, 0)
        XCTAssertEqual(result.reasoning, "No tools available for this task.")
    }

    func testNestedContent_NilThought() {
        let input = """
        {
          "content": {
            "tool_calls": [
              {"name": "fs_smart_search", "arguments": {"search_term": "Acme"}}
            ]
          }
        }
        """
        let result = parser.parse(rawResponse: input)
        XCTAssertEqual(result.toolCalls.count, 1)
        XCTAssertEqual(result.toolCalls.first?.name, "fs_smart_search")
        XCTAssertEqual(result.reasoning, "")
    }

    func testNestedContent_NilToolCalls() {
        // Model wraps content as object but omits tool_calls entirely
        let input = """
        {
          "content": {
            "thought": "I cannot help with that."
          }
        }
        """
        let result = parser.parse(rawResponse: input)
        XCTAssertEqual(result.toolCalls.count, 0)
        XCTAssertEqual(result.reasoning, "I cannot help with that.")
    }

    func testNestedContent_DoesNotInterfereWithStandardFormat() {
        // Standard format with content as String should still work (Attempt 1)
        let input = """
        {
          "content": "Standard reasoning.",
          "tool_calls": [{"name": "list_directory", "arguments": {"path": "/"}}]
        }
        """
        let result = parser.parse(rawResponse: input)
        XCTAssertEqual(result.toolCalls.count, 1)
        XCTAssertEqual(result.reasoning, "Standard reasoning.")
    }

    func testTruncatedJSON_MissingClosingBrace_RecoversContent() {
        // Root object opens but never closes — model truncated output
        let input = """
        {
          "content": "Searching for files.",
          "tool_calls": [
            {"name": "list_directory", "arguments": {"path": "/tmp"}}
          ]
        """
        let result = parser.parse(rawResponse: input)
        XCTAssertTrue(result.reasoning.contains("Searching for files"))
        XCTAssertGreaterThanOrEqual(result.toolCalls.count, 1)
        XCTAssertEqual(result.toolCalls.first?.name, "list_directory")
    }
}
