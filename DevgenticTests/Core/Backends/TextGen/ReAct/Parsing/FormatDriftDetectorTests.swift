// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
//
//  FormatDriftDetectorTests.swift
//  DevgenticTests
//
//  Tests for FormatDriftDetector — Stage 2 of the Dialect-Anchored Cascade.
//  Validates all 10 probe types and dialect exclusion logic.
//

import XCTest
@testable import devgentic

final class FormatDriftDetectorTests: XCTestCase {

    // MARK: - Probe 1: PythonicTag

    func testPythonicTag_Detected() {
        let detector = FormatDriftDetector(excludedDialect: .nativeJSON)
        let input = "<|python_tag|>[{\"name\": \"list_directory\", \"arguments\": {\"path\": \"/\"}}]"
        XCTAssertEqual(detector.detect(in: input), .pythonicTag)
    }

    func testPythonicTag_NotPresent() {
        let detector = FormatDriftDetector(excludedDialect: .nativeJSON)
        let input = "I cannot help with that request."
        XCTAssertNil(detector.detect(in: input))
    }

    // MARK: - Probe 2: DeepXML

    func testDeepXML_Detected() {
        let detector = FormatDriftDetector(excludedDialect: .nativeJSON)
        let input = """
        <function=list_directory>
        <parameter=path>/tmp</parameter>
        </function>
        """
        XCTAssertEqual(detector.detect(in: input), .deepXML)
    }

    func testDeepXML_OnlyFunctionTag_NoMatch() {
        let detector = FormatDriftDetector(excludedDialect: .nativeJSON)
        let input = "<function=list_directory>some text</function>"
        // Missing <parameter= — should not match
        XCTAssertNotEqual(detector.detect(in: input), .deepXML)
    }

    // MARK: - Probe 3: BracketHash

    func testBracketHash_Detected() {
        let detector = FormatDriftDetector(excludedDialect: .nativeJSON)
        let input = "<Functions#list_directory>{\"path\": \"/tmp\"}</Functions>"
        XCTAssertEqual(detector.detect(in: input), .bracketHash)
    }

    // MARK: - Probe 4: YAMLInXML

    func testYAMLInXML_Detected() {
        let detector = FormatDriftDetector(excludedDialect: .nativeJSON)
        let input = """
        <tool_calls>
        - name: list_directory
          arguments:
            path: /tmp
        </tool_calls>
        """
        XCTAssertEqual(detector.detect(in: input), .yamlInXML)
    }

    func testYAMLInXML_XMLWithoutYAML_NoMatch() {
        let detector = FormatDriftDetector(excludedDialect: .nativeJSON)
        let input = """
        <tool_calls>
        [{"name": "list_directory"}]
        </tool_calls>
        """
        // Has <tool_calls> but no YAML pattern — should not match yamlInXML
        XCTAssertNotEqual(detector.detect(in: input), .yamlInXML)
    }

    // MARK: - Probe 5: GenericToolsXML

    func testGenericToolsXML_PluralTag() {
        let detector = FormatDriftDetector(excludedDialect: .nativeJSON)
        let input = """
        <tools>
        {"name": "list_directory", "arguments": {"path": "/"}}
        </tools>
        """
        XCTAssertEqual(detector.detect(in: input), .genericToolsXML)
    }

    func testGenericToolsXML_SingularTag() {
        let detector = FormatDriftDetector(excludedDialect: .nativeJSON)
        let input = """
        <tool>
        {"name": "read_file", "arguments": {"path": "/a.txt"}}
        </tool>
        """
        XCTAssertEqual(detector.detect(in: input), .genericToolsXML)
    }

    // MARK: - Probe 6: StandardXML

    func testStandardXML_DetectedWhenNotMistralDialect() {
        // Primary is nativeJSON, so StandardXML probe should be active
        let detector = FormatDriftDetector(excludedDialect: .nativeJSON)
        let input = """
        <tool_call>
        {"name": "list_directory", "arguments": {"path": "/"}}
        </tool_call>
        """
        XCTAssertEqual(detector.detect(in: input), .standardXML)
    }

    func testStandardXML_ExcludedWhenMistralDialect() {
        // Primary IS mistralXML — StandardXML probe should NOT be added
        let detector = FormatDriftDetector(excludedDialect: .mistralXML)
        let input = """
        <tool_call>
        {"name": "list_directory", "arguments": {"path": "/"}}
        </tool_call>
        """
        // Should NOT detect standardXML since that's the primary dialect
        XCTAssertNotEqual(detector.detect(in: input), .standardXML)
    }

    // MARK: - Probe 7: ReActMarkdown

    func testReActMarkdown_DetectedWhenNotReActDialect() {
        let detector = FormatDriftDetector(excludedDialect: .nativeJSON)
        let input = """
        Thought: I need to list files.
        Action: list_directory
        Action Input: {"path": "/"}
        """
        XCTAssertEqual(detector.detect(in: input), .reactMarkdown)
    }

    func testReActMarkdown_ExcludedWhenReActDialect() {
        let detector = FormatDriftDetector(excludedDialect: .reactMarkdown)
        let input = """
        Thought: I need to list files.
        Action: list_directory
        Action Input: {"path": "/"}
        """
        XCTAssertNotEqual(detector.detect(in: input), .reactMarkdown)
    }

    // MARK: - Probe 8: DynamicToolTag

    func testDynamicToolTag_KnownToolName() {
        let detector = FormatDriftDetector(
            excludedDialect: .nativeJSON,
            knownToolNames: ["list_directory", "read_file"]
        )
        let input = """
        <list_directory>{"path": "/tmp"}</list_directory>
        """
        XCTAssertEqual(detector.detect(in: input), .dynamicToolTag)
    }

    func testDynamicToolTag_StructuralMatch_UnknownTool() {
        let detector = FormatDriftDetector(excludedDialect: .nativeJSON)
        let input = """
        <search_files>{"query": "readme"}</search_files>
        """
        XCTAssertEqual(detector.detect(in: input), .dynamicToolTag)
    }

    // MARK: - Probe 9: ArrayInversion

    func testArrayInversion_Detected() {
        let detector = FormatDriftDetector(excludedDialect: .mistralXML)
        let input = """
        [{"name": "list_directory", "arguments": {"path": "/"}}]
        """
        XCTAssertEqual(detector.detect(in: input), .arrayInversion)
    }

    func testArrayInversion_NotArray_NoMatch() {
        let detector = FormatDriftDetector(excludedDialect: .mistralXML)
        let input = "{\"name\": \"list_directory\"}"
        XCTAssertNotEqual(detector.detect(in: input), .arrayInversion)
    }

    // MARK: - Probe 10: FlatJSONLeakage

    func testFlatJSONLeakage_ToolName() {
        let detector = FormatDriftDetector(excludedDialect: .reactMarkdown)
        let input = "{\"content\": \"Searching.\", \"tool_name\": \"list_directory\", \"arguments\": {\"path\": \"/\"}}"
        XCTAssertEqual(detector.detect(in: input), .flatJSONLeakage)
    }

    func testFlatJSONLeakage_ToolCalls() {
        let detector = FormatDriftDetector(excludedDialect: .reactMarkdown)
        let input = "{\"content\": \"Listing.\", \"tool_calls\": [{\"name\": \"list_directory\"}]}"
        XCTAssertEqual(detector.detect(in: input), .flatJSONLeakage)
    }

    // MARK: - No Drift

    func testNoDrift_PlainText() {
        let detector = FormatDriftDetector(excludedDialect: .nativeJSON)
        let input = "I cannot help with that request. Please try something else."
        XCTAssertNil(detector.detect(in: input))
    }

    func testNoDrift_EmptyString() {
        let detector = FormatDriftDetector(excludedDialect: .nativeJSON)
        XCTAssertNil(detector.detect(in: ""))
    }

    // MARK: - containsAnySignal

    func testContainsAnySignal_True() {
        let detector = FormatDriftDetector(excludedDialect: .nativeJSON)
        let input = """
        <tool_call>
        {"name": "list_directory", "arguments": {"path": "/"}}
        </tool_call>
        """
        XCTAssertTrue(detector.containsAnySignal(in: input))
    }

    func testContainsAnySignal_False() {
        let detector = FormatDriftDetector(excludedDialect: .nativeJSON)
        XCTAssertFalse(detector.containsAnySignal(in: "Just plain text."))
    }

    // MARK: - S18: FunctionCall Tag

    func testFunctionCallTag_Detected() {
        let detector = FormatDriftDetector(excludedDialect: .nativeJSON)
        let input = """
        <functioncall>{"name": "list_directory", "arguments": {"path": "/"}}</functioncall>
        """
        XCTAssertEqual(detector.detect(in: input), .functionCallTag)
    }

    // MARK: - S19: Gorilla Format

    func testGorillaFormat_Detected() {
        let detector = FormatDriftDetector(excludedDialect: .nativeJSON)
        let input = """
        <<function>>list_directory(path="/tmp")
        """
        XCTAssertEqual(detector.detect(in: input), .gorillaFunction)
    }

    // MARK: - Probe Priority (Most Specific Wins)

    func testProbePriority_PythonicTagBeatsReActMarkdown() {
        // Text contains both pythonic tag and ReAct markers
        let detector = FormatDriftDetector(excludedDialect: .nativeJSON)
        let input = """
        <|python_tag|>
        Action: list_directory
        Action Input: {"path": "/"}
        """
        // PythonicTag is higher priority (probe 1) than ReActMarkdown (probe 7)
        XCTAssertEqual(detector.detect(in: input), .pythonicTag)
    }
}
