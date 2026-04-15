//
//  OutputSanitizerTests.swift
//  DevgenticTests
//
//  Tests for OutputSanitizer — Stage 0 of the Dialect-Anchored Cascade.
//  Strips think blocks, BOM artifacts, code fences, and orphan tags.
//

import XCTest
@testable import devgentic

final class OutputSanitizerTests: XCTestCase {

    // MARK: - Think Block Extraction

    func testThinkBlock_SingleBlock() {
        let input = """
        <think>I need to reason about this carefully.</think>
        {"content": "Here is my answer.", "tool_calls": []}
        """
        let result = OutputSanitizer.sanitize(input)
        XCTAssertFalse(result.cleaned.contains("<think>"))
        XCTAssertFalse(result.cleaned.contains("</think>"))
        XCTAssertTrue(result.cleaned.contains("tool_calls"))
        XCTAssertEqual(result.thought, "I need to reason about this carefully.")
    }

    func testThinkBlock_MultipleBlocks() {
        let input = """
        <think>First thought.</think>
        Some content here.
        <think>Second thought.</think>
        More content.
        """
        let result = OutputSanitizer.sanitize(input)
        XCTAssertFalse(result.cleaned.contains("<think>"))
        XCTAssertNotNil(result.thought)
        XCTAssertTrue(result.thought!.contains("First thought."))
        XCTAssertTrue(result.thought!.contains("Second thought."))
        XCTAssertTrue(result.cleaned.contains("Some content here."))
        XCTAssertTrue(result.cleaned.contains("More content."))
    }

    func testThinkBlock_CaseInsensitive() {
        let input = """
        <THINK>Deep reasoning here.</THINK>
        {"content": "Result.", "tool_calls": []}
        """
        let result = OutputSanitizer.sanitize(input)
        XCTAssertFalse(result.cleaned.contains("THINK"))
        XCTAssertEqual(result.thought, "Deep reasoning here.")
    }

    func testThinkBlock_NoThinkTags() {
        let input = """
        {"content": "Plain response.", "tool_calls": []}
        """
        let result = OutputSanitizer.sanitize(input)
        XCTAssertNil(result.thought)
        XCTAssertTrue(result.cleaned.contains("Plain response."))
    }

    // MARK: - BOM / Leading Artifacts

    func testBOM_StripsLeadingBOM() {
        let bom = "\u{FEFF}"
        let input = bom + "{\"content\": \"test\", \"tool_calls\": []}"
        let result = OutputSanitizer.sanitize(input)
        XCTAssertTrue(result.cleaned.hasPrefix("{"))
    }

    func testLeadingArtifacts_NonASCII() {
        // Simulate non-printable leading chars
        let artifact = String(UnicodeScalar(0x00)!)
        let input = artifact + "{\"content\": \"test\"}"
        let result = OutputSanitizer.sanitize(input)
        XCTAssertTrue(result.cleaned.hasPrefix("{"))
    }

    // MARK: - Code Fence Stripping

    func testCodeFence_JsonBlock() {
        let input = """
        ```json
        {"content": "Listed.", "tool_calls": [{"name": "list_directory", "arguments": {"path": "/"}}]}
        ```
        """
        let result = OutputSanitizer.sanitize(input)
        XCTAssertFalse(result.cleaned.contains("```"))
        XCTAssertTrue(result.cleaned.contains("list_directory"))
    }

    func testCodeFence_XmlBlock() {
        let input = """
        ```xml
        <tool_call>
        {"name": "read_file", "arguments": {"path": "/test.txt"}}
        </tool_call>
        ```
        """
        let result = OutputSanitizer.sanitize(input)
        XCTAssertFalse(result.cleaned.contains("```"))
        XCTAssertTrue(result.cleaned.contains("<tool_call>"))
    }

    func testCodeFence_BareBackticks() {
        let input = """
        ```
        {"name": "list_directory", "arguments": {"path": "/"}}
        ```
        """
        let result = OutputSanitizer.sanitize(input)
        XCTAssertFalse(result.cleaned.contains("```"))
    }

    func testCodeFence_NoFences() {
        let input = "{\"content\": \"test\", \"tool_calls\": []}"
        let result = OutputSanitizer.sanitize(input)
        XCTAssertEqual(result.cleaned, input)
    }

    // MARK: - Orphan Tag Stripping

    func testOrphanTag_TrailingToolCall() {
        let input = """
        {"name": "list_directory", "arguments": {"path": "/"}}
        </tool_call>
        """
        let result = OutputSanitizer.sanitize(input)
        XCTAssertFalse(result.cleaned.contains("</tool_call>"))
        XCTAssertTrue(result.cleaned.contains("list_directory"))
    }

    func testOrphanTag_TrailingS() {
        let input = """
        {"content": "Done.", "tool_calls": []}
        </s>
        """
        let result = OutputSanitizer.sanitize(input)
        XCTAssertFalse(result.cleaned.contains("</s>"))
    }

    func testOrphanTag_TrailingTools() {
        let input = """
        {"name": "read_file", "arguments": {"path": "/a.txt"}}
        </tools>
        """
        let result = OutputSanitizer.sanitize(input)
        XCTAssertFalse(result.cleaned.contains("</tools>"))
    }

    func testOrphanTag_MatchedPairPreserved() {
        let input = """
        <tool_call>
        {"name": "read_file", "arguments": {"path": "/a.txt"}}
        </tool_call>
        """
        let result = OutputSanitizer.sanitize(input)
        // Matched pair — the close tag should survive since it's not truly orphaned
        // (the sanitizer only strips trailing orphans, the open tag keeps it matched)
        XCTAssertTrue(result.cleaned.contains("<tool_call>"))
    }

    // MARK: - S14: Special Token Markers

    func testSpecialToken_EotId() {
        let input = """
        {"content": "Listed.", "tool_calls": [{"name": "list_directory", "arguments": {"path": "/"}}]}<|eot_id|>
        """
        let result = OutputSanitizer.sanitize(input)
        XCTAssertFalse(result.cleaned.contains("<|eot_id|>"))
        XCTAssertTrue(result.cleaned.contains("list_directory"))
    }

    func testSpecialToken_EndOfText() {
        let input = """
        {"content": "Done.", "tool_calls": []}<|end_of_text|>
        """
        let result = OutputSanitizer.sanitize(input)
        XCTAssertFalse(result.cleaned.contains("<|end_of_text|>"))
    }

    func testSpecialToken_ImEnd() {
        let input = """
        {"content": "Result.", "tool_calls": [{"name": "read_file", "arguments": {"path": "/a.txt"}}]}<|im_end|>
        """
        let result = OutputSanitizer.sanitize(input)
        XCTAssertFalse(result.cleaned.contains("<|im_end|>"))
        XCTAssertTrue(result.cleaned.contains("read_file"))
    }

    // MARK: - S16: <output> Wrapper Tag

    func testOutputWrapper_Stripped() {
        let input = """
        <output>
        {"content": "Listed.", "tool_calls": [{"name": "list_directory", "arguments": {"path": "/"}}]}
        </output>
        """
        let result = OutputSanitizer.sanitize(input)
        XCTAssertFalse(result.cleaned.contains("<output>"))
        XCTAssertFalse(result.cleaned.contains("</output>"))
        XCTAssertTrue(result.cleaned.contains("list_directory"))
    }

    func testResponseWrapper_Stripped() {
        let input = """
        <response>
        {"content": "Done.", "tool_calls": []}
        </response>
        """
        let result = OutputSanitizer.sanitize(input)
        XCTAssertFalse(result.cleaned.contains("<response>"))
        XCTAssertFalse(result.cleaned.contains("</response>"))
    }

    // MARK: - Combined Artifacts

    func testCombined_ThinkAndCodeFence() {
        let input = """
        <think>Let me reason about the tool call.</think>
        ```json
        {"content": "Listing.", "tool_calls": [{"name": "list_directory", "arguments": {"path": "/"}}]}
        ```
        """
        let result = OutputSanitizer.sanitize(input)
        XCTAssertFalse(result.cleaned.contains("<think>"))
        XCTAssertFalse(result.cleaned.contains("```"))
        XCTAssertTrue(result.cleaned.contains("list_directory"))
        XCTAssertEqual(result.thought, "Let me reason about the tool call.")
    }

    // MARK: - Edge Cases

    func testEmptyString() {
        let result = OutputSanitizer.sanitize("")
        XCTAssertTrue(result.cleaned.isEmpty)
        XCTAssertNil(result.thought)
    }

    func testWhitespaceOnly() {
        let result = OutputSanitizer.sanitize("   \n\t  ")
        XCTAssertTrue(result.cleaned.isEmpty)
    }

    func testCleanInput_Unchanged() {
        let input = "{\"content\": \"Hello.\", \"tool_calls\": [{\"name\": \"list_directory\", \"arguments\": {\"path\": \"/\"}}]}"
        let result = OutputSanitizer.sanitize(input)
        XCTAssertEqual(result.cleaned, input)
        XCTAssertNil(result.thought)
    }

    // MARK: - Duplicate Block Deduplication (G2)

    func testDuplicateBlock_TwoIdenticalJSONObjects() {
        let block = """
        {"content": {"thought": "No tools.", "tool_calls": []}}
        """
        let input = block + "\n" + block
        let result = OutputSanitizer.sanitize(input)
        // Should contain only one block
        let braceCount = result.cleaned.filter { $0 == "{" }.count
        // One top-level + one nested "content" object = 2 open braces for single block
        XCTAssertEqual(braceCount, 2, "Should keep only the first JSON block")
    }

    func testDuplicateBlock_SingleBlock_Unchanged() {
        let input = """
        {"content": "Hello.", "tool_calls": []}
        """
        let result = OutputSanitizer.sanitize(input)
        XCTAssertTrue(result.cleaned.contains("Hello."))
    }

    func testDuplicateBlock_NonJSON_Unchanged() {
        let input = "Action: list_directory\nAction Input: {\"path\": \"/\"}"
        let result = OutputSanitizer.sanitize(input)
        XCTAssertTrue(result.cleaned.contains("Action:"))
    }

    // MARK: - Scoped Think-Block Strip (G3)

    func testStripThinkBlocksAndTokens_RemovesThinkTags() {
        let input = "<think>Internal reasoning here.</think>\nThe answer is 42."
        let result = OutputSanitizer.stripThinkBlocksAndTokens(input)
        XCTAssertFalse(result.contains("<think>"))
        XCTAssertFalse(result.contains("Internal reasoning"))
        XCTAssertEqual(result, "The answer is 42.")
    }

    func testStripThinkBlocksAndTokens_RemovesSpecialTokens() {
        let input = "The answer is 42.<|eot_id|>"
        let result = OutputSanitizer.stripThinkBlocksAndTokens(input)
        XCTAssertEqual(result, "The answer is 42.")
    }

    func testStripThinkBlocksAndTokens_PreservesCodeFences() {
        let input = """
        Here's the code:

        ```swift
        let files = try FileManager.default.contentsOfDirectory(atPath: path)
        ```
        """
        let result = OutputSanitizer.stripThinkBlocksAndTokens(input)
        XCTAssertTrue(result.contains("```swift"), "Code fences should NOT be stripped by scoped sanitizer")
        XCTAssertTrue(result.contains("```"), "Closing code fence should be preserved")
    }

    func testStripThinkBlocksAndTokens_PreservesMarkdown() {
        let input = """
        <think>Some internal reasoning.</think>
        Here's an example:

        ```python
        print("hello world")
        ```

        That's all!
        """
        let result = OutputSanitizer.stripThinkBlocksAndTokens(input)
        XCTAssertFalse(result.contains("<think>"))
        XCTAssertTrue(result.contains("```python"), "Python code fence should be preserved")
        XCTAssertTrue(result.contains("print(\"hello world\")"))
        XCTAssertTrue(result.contains("That's all!"))
    }

    // MARK: - sanitizeForUI: Prompt Scaffold Tag Stripping

    func testSanitizeForUI_EpisodicMemoryTag_Stripped() {
        let input = "<episodic_memory> contains the recent calculation of '2 + 2' which is equal to 4.</working_memory>"
        let result = OutputSanitizer.sanitizeForUI(input)
        XCTAssertFalse(result.contains("<episodic_memory>"), "Episodic memory tag should be stripped")
        XCTAssertFalse(result.contains("</working_memory>"), "Working memory closing tag should be stripped")
        XCTAssertTrue(result.contains("calculation of '2 + 2'"), "Content between tags should be preserved")
    }

    func testSanitizeForUI_WorkingMemoryBlock_Stripped() {
        let input = """
        <working_memory>
        Step 1: read_file succeeded with content "Hello"
        </working_memory>
        I will now proceed to answer.
        """
        let result = OutputSanitizer.sanitizeForUI(input)
        XCTAssertFalse(result.contains("<working_memory>"))
        XCTAssertFalse(result.contains("</working_memory>"))
        XCTAssertTrue(result.contains("I will now proceed to answer"))
    }

    func testSanitizeForUI_NegativeConstraintsTag_Stripped() {
        let input = "<negative_constraints>\nFAILED PATHS:\n- delete_file denied\n</negative_constraints>"
        let result = OutputSanitizer.sanitizeForUI(input)
        XCTAssertFalse(result.contains("<negative_constraints>"))
        XCTAssertFalse(result.contains("</negative_constraints>"))
    }

    func testSanitizeForUI_FullEpisodicBlock_Stripped() {
        let input = """
        <episodic_memory>
          <recent>
            <turn status="completed" goal="list files" recency="1 turn ago">
              <action tool="list_directory" status="success">
                <params path="/Users/alice/Desktop"/>
              </action>
            </turn>
          </recent>
        </episodic_memory>
        Now I need to read the file.
        """
        let result = OutputSanitizer.sanitizeForUI(input)
        XCTAssertFalse(result.contains("<episodic_memory>"))
        XCTAssertFalse(result.contains("<recent>"))
        XCTAssertFalse(result.contains("<turn"))
        XCTAssertFalse(result.contains("<action"))
        XCTAssertFalse(result.contains("<params"))
        XCTAssertTrue(result.contains("Now I need to read the file"))
    }

    func testSanitizeForUI_PlainText_Unchanged() {
        let input = "I will search for files on the Desktop using fs_smart_search."
        let result = OutputSanitizer.sanitizeForUI(input)
        XCTAssertEqual(result, input, "Plain text without scaffold tags should pass through unchanged")
    }

    func testSanitizeForUI_EmptyString_ReturnsEmpty() {
        XCTAssertEqual(OutputSanitizer.sanitizeForUI(""), "")
    }

    func testSanitizeForUI_SpecialTokensAlsoStripped() {
        let input = "<|im_start|>assistant\nI will help you.<|im_end|>"
        let result = OutputSanitizer.sanitizeForUI(input)
        XCTAssertFalse(result.contains("<|im_start|>"))
        XCTAssertFalse(result.contains("<|im_end|>"))
        XCTAssertTrue(result.contains("I will help you"))
    }

    func testSanitizeForUI_CollapsesMultipleBlankLines() {
        let input = "Line 1\n\n\n\n\nLine 2"
        let result = OutputSanitizer.sanitizeForUI(input)
        XCTAssertFalse(result.contains("\n\n\n"), "Triple+ newlines should be collapsed")
        XCTAssertTrue(result.contains("Line 1"))
        XCTAssertTrue(result.contains("Line 2"))
    }
}
