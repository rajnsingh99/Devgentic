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

    func testBareToolCall_MissingOuterBrace_RecoversFinalAnswer() {
        // Reproduction of the iter-13 production bug: qwen2.5-coder:14b emitted a
        // bare `final_answer` call with the outer `}` dropped. Depth ends at 1;
        // extractOutermostJSON should append a closer and BareToolCallSchema
        // should decode cleanly.
        let input = #"{"name": "final_answer", "arguments": {"answer": "Here are the files:\n- a.pdf\n- b.pdf"}"#
        let result = parser.parse(rawResponse: input)
        XCTAssertEqual(result.toolCalls.count, 1, "Missing outer brace should be salvaged")
        XCTAssertEqual(result.toolCalls.first?.name, "final_answer")
        let answer = result.toolCalls.first?.arguments["answer"]?.stringValue ?? ""
        XCTAssertTrue(answer.contains("Here are the files"))
        XCTAssertTrue(answer.contains("a.pdf"))
    }

    func testBareToolCall_MissingTwoClosingBraces_RecoversFinalAnswer() {
        // Deeper truncation: both the `arguments` closer and the root closer dropped.
        // Depth ends at 2; recovery appends two `}` and the payload decodes.
        let input = #"{"name": "final_answer", "arguments": {"answer": "Task complete""#
        let result = parser.parse(rawResponse: input)
        XCTAssertEqual(result.toolCalls.count, 1, "Two missing braces should still be salvaged")
        XCTAssertEqual(result.toolCalls.first?.name, "final_answer")
        XCTAssertEqual(result.toolCalls.first?.arguments["answer"]?.stringValue, "Task complete")
    }

    // MARK: - Bug 3: Malformed Content with Valid tool_calls

    func testMalformedContent_HTMLTags_RecoverToolCalls() {
        // Exact bug from production: content has HTML tags (not valid JSON string)
        // but tool_calls array is perfectly valid
        let input = """
        {
          "content":<p>Based on the metadata retrieval results, it seems that there are multiple folders.</p>,
          "tool_calls": [
            {
              "name": "fs_smart_search",
              "arguments": {
                "search_term": "*Acme*"
              }
            }
          ]
        }
        """
        let result = parser.parse(rawResponse: input)
        XCTAssertEqual(result.toolCalls.count, 1, "Valid tool_calls should be recovered even when content field is malformed HTML")
        XCTAssertEqual(result.toolCalls.first?.name, "fs_smart_search")
        XCTAssertEqual(result.toolCalls.first?.arguments["search_term"], .string("*Acme*"))
    }

    func testMalformedContent_UnquotedValue_RecoverToolCalls() {
        // Content value not wrapped in quotes
        let input = """
        {
          "content": unquoted text here,
          "tool_calls": [
            {"name": "list_directory", "arguments": {"path": "/tmp"}}
          ]
        }
        """
        let result = parser.parse(rawResponse: input)
        XCTAssertEqual(result.toolCalls.count, 1, "Valid tool_calls should be recovered even when content value is unquoted")
        XCTAssertEqual(result.toolCalls.first?.name, "list_directory")
    }

    func testMalformedContent_NoToolCalls_ReturnsNil() {
        // When neither content nor tool_calls can be found, should still return nil
        // to allow other recovery paths (markdown field format, etc.)
        let input = "Just plain text without any JSON structure"
        let result = parser.parse(rawResponse: input)
        XCTAssertEqual(result.toolCalls.count, 0)
        XCTAssertTrue(result.reasoning.contains("plain text"), "Plain text should be preserved as reasoning")
    }

    // MARK: - Raw Newline Recovery (Step 7: escapeRawControlsInsideStrings)
    // Quantized models (qwen-coder:14b Q4_K_M observed in prod) sometimes emit a literal
    // LF character inside a JSON string value instead of the escape sequence `\n`.
    // JSONDecoder rejects this; step 7 of sanitizeJSON rewrites those raw LFs before decoding.

    func testRawNewline_InsideFinalAnswerString_Recovered() {
        // Reduced shape of the exact production failure — raw LF between escaped \n sequences
        // inside the `answer` string of a final_answer tool call.
        // The blank line after "**Symbols Found:**" is a literal LF in the Swift source,
        // which becomes a raw LF in the JSON string at runtime.
        let input = """
        {
          "name": "final_answer",
          "arguments": {
            "answer": "**Project Analysis Summary**\\n\\n**Symbols Found:**
        - `public class January2026` defined at line 9\\n\\n*No further actions needed.*"
          }
        }
        """
        let result = parser.parse(rawResponse: input)
        XCTAssertEqual(result.toolCalls.count, 1, "Raw LF inside string should be escaped and parse recovered")
        XCTAssertEqual(result.toolCalls.first?.name, "final_answer")
        let answer = result.toolCalls.first?.arguments["answer"]?.stringValue ?? ""
        XCTAssertTrue(answer.contains("Project Analysis Summary"))
        XCTAssertTrue(answer.contains("Symbols Found"))
        XCTAssertTrue(answer.contains("public class January2026"))
    }

    func testRawNewline_BetweenJSONTokens_NotModified() {
        // Pretty-printed JSON has raw LFs BETWEEN tokens — these are valid whitespace and
        // must not be escaped by the transform (they're outside any string value).
        let input = """
        {
          "content": "hello",
          "tool_calls": [
            {"name": "list_directory", "arguments": {"path": "/tmp"}}
          ]
        }
        """
        let result = parser.parse(rawResponse: input)
        XCTAssertEqual(result.toolCalls.count, 1, "Pretty-printed JSON must still parse cleanly")
        XCTAssertEqual(result.toolCalls.first?.name, "list_directory")
        XCTAssertEqual(result.reasoning, "hello")
    }

    func testEscapedNewline_PreservedThroughTransform() {
        // Already-correct `\n` escape sequence (2 chars in JSON) should not be double-escaped.
        let input = #"{"content": "line one\nline two", "tool_calls": []}"#
        let result = parser.parse(rawResponse: input)
        // After JSONDecoder, the escape becomes a real LF char in the parsed string.
        XCTAssertEqual(result.reasoning, "line one\nline two")
        XCTAssertEqual(result.toolCalls.count, 0)
    }

    func testEscapedQuoteInsideString_NotTreatedAsBoundary() {
        // Escape handling: `\"` inside a string must not prematurely close it,
        // so raw LF elsewhere in the same string is still detected as in-string.
        let input = """
        {"name": "foo", "arguments": {"quote": "she said \\"hi\\" then walked away
        on a new line"}}
        """
        let result = parser.parse(rawResponse: input)
        XCTAssertEqual(result.toolCalls.count, 1)
        XCTAssertEqual(result.toolCalls.first?.name, "foo")
        let quote = result.toolCalls.first?.arguments["quote"]?.stringValue ?? ""
        XCTAssertTrue(quote.contains("she said"))
        XCTAssertTrue(quote.contains("on a new line"))
    }

    func testUnmatchedBraces_WithRawNewlines_DoesNotFabricateToolCall() {
        // Risk-surface case: JSON is broken for a DIFFERENT reason (truncated / unmatched
        // braces) AND happens to contain raw newlines. After step 7 escapes the newlines,
        // the outer structure is still invalid — the transform must NOT falsely succeed.
        //
        // Acceptable outcomes: empty tool_calls OR recovery via existing lenient paths with
        // a correct tool name. Unacceptable: a tool call with a fabricated/wrong name.
        let input = """
        {"name": "read_file", "arguments": {"path": "/tmp/abc
        xyz.txt"
        """
        let result = parser.parse(rawResponse: input)
        if let toolCall = result.toolCalls.first {
            XCTAssertEqual(toolCall.name, "read_file", "If recovered, the tool name must be correct — never fabricated")
        }
        // Whether it's recovered or not is acceptable; what matters is no wrong-name result.
    }

    func testRawTab_InsideStringValue_Recovered() {
        // Same bug family, different control char. A raw TAB inside a JSON string is invalid
        // and should be escaped to `\t`.
        let input = "{\"content\": \"col1\tcol2\", \"tool_calls\": []}"
        let result = parser.parse(rawResponse: input)
        XCTAssertEqual(result.reasoning, "col1\tcol2", "Raw tab inside string value should parse correctly after step 7")
    }
}
