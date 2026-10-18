// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
//
//  PlanGeneratorStrategyTests.swift
//  DevgenticTests
//
//  Created by Raj Singh.
//

import XCTest
@testable import devgentic

final class PlanGeneratorStrategyTests: XCTestCase {

    private let strategy = PlanGeneratorStrategy()
    private let sampleTools: Set<String> = ["file_search", "read_file", "run_command", "write_file", "web_search"]

    // MARK: - Clean Numbered List

    func testParse_CleanNumberedList_CorrectCount() {
        let input = """
        1. Search for log files
        2. Read the error entries
        3. Summarize findings
        """

        let result = strategy.parsePlan(from: input, availableToolNames: sampleTools)

        XCTAssertEqual(result.count, 3)
        XCTAssertEqual(result[0].id, "step_1")
        XCTAssertEqual(result[0].description, "Search for log files")
        XCTAssertEqual(result[1].id, "step_2")
        XCTAssertEqual(result[1].description, "Read the error entries")
        XCTAssertEqual(result[2].id, "step_3")
        XCTAssertEqual(result[2].description, "Summarize findings")
    }

    // MARK: - Tool Brackets Extraction

    func testParse_WithToolBrackets_ExtractsValidTools() {
        let input = """
        1. Search for log files [file_search]
        2. Read the error entries [read_file, run_command]
        3. Write summary report [write_file]
        """

        let result = strategy.parsePlan(from: input, availableToolNames: sampleTools)

        XCTAssertEqual(result.count, 3)
        XCTAssertEqual(result[0].toolHints, ["file_search"])
        XCTAssertEqual(result[1].toolHints, ["read_file", "run_command"])
        XCTAssertEqual(result[2].toolHints, ["write_file"])
    }

    func testParse_ToolBrackets_DescriptionStripped() {
        let input = "1. Find all config files [file_search]"

        let result = strategy.parsePlan(from: input, availableToolNames: sampleTools)

        XCTAssertEqual(result[0].description, "Find all config files")
    }

    // MARK: - Preamble and Trailing Text

    func testParse_WithPreamble_IgnoresNonNumberedLines() {
        let input = """
        Here is my plan for completing this task:

        1. Search for the files
        2. Read their contents

        Let me know if you need changes!
        """

        let result = strategy.parsePlan(from: input, availableToolNames: sampleTools)

        XCTAssertEqual(result.count, 2)
        XCTAssertEqual(result[0].description, "Search for the files")
        XCTAssertEqual(result[1].description, "Read their contents")
    }

    // MARK: - Alternative Numbering Formats

    func testParse_ParenthesisNumbering_Parses() {
        let input = """
        1) Find the log files
        2) Read the entries
        """

        let result = strategy.parsePlan(from: input, availableToolNames: sampleTools)

        XCTAssertEqual(result.count, 2)
        XCTAssertEqual(result[0].description, "Find the log files")
    }

    func testParse_ColonNumbering_Parses() {
        let input = """
        1: Find the log files
        2: Read the entries
        """

        let result = strategy.parsePlan(from: input, availableToolNames: sampleTools)

        XCTAssertEqual(result.count, 2)
    }

    func testParse_DashNumbering_Parses() {
        let input = """
        1- Find the log files
        2- Read the entries
        """

        let result = strategy.parsePlan(from: input, availableToolNames: sampleTools)

        XCTAssertEqual(result.count, 2)
    }

    func testParse_StepPrefix_Parses() {
        let input = """
        Step 1. Find the log files
        Step 2. Read the entries
        Step 3. Summarize
        """

        let result = strategy.parsePlan(from: input, availableToolNames: sampleTools)

        XCTAssertEqual(result.count, 3)
        XCTAssertEqual(result[0].description, "Find the log files")
    }

    // MARK: - Missing Brackets (Graceful Degradation)

    func testParse_NoBrackets_ToolHintsNil() {
        let input = """
        1. Search for files
        2. Read the files
        """

        let result = strategy.parsePlan(from: input, availableToolNames: sampleTools)

        XCTAssertEqual(result.count, 2)
        XCTAssertNil(result[0].toolHints)
        XCTAssertNil(result[1].toolHints)
    }

    // MARK: - Hallucinated Tool Validation

    func testParse_HallucinatedTools_Discarded() {
        let input = "1. Do something [file_search, fake_tool, imaginary_helper]"

        let result = strategy.parsePlan(from: input, availableToolNames: sampleTools)

        XCTAssertEqual(result.count, 1)
        XCTAssertEqual(result[0].toolHints, ["file_search"], "Only valid tools should survive validation")
    }

    func testParse_AllToolsInvalid_HintsNil() {
        let input = "1. Do something [fake_tool, another_fake]"

        let result = strategy.parsePlan(from: input, availableToolNames: sampleTools)

        XCTAssertEqual(result.count, 1)
        XCTAssertNil(result[0].toolHints, "When all hints are invalid, toolHints should be nil")
    }

    func testParse_MixedValidAndInvalid_OnlyValidRetained() {
        let input = """
        1. Search files [file_search, nonexistent_tool]
        2. Process results [fake, run_command, also_fake]
        """

        let result = strategy.parsePlan(from: input, availableToolNames: sampleTools)

        XCTAssertEqual(result[0].toolHints, ["file_search"])
        XCTAssertEqual(result[1].toolHints, ["run_command"])
    }

    // MARK: - Empty / Garbage Response

    func testParse_EmptyResponse_FallbackToSingleTask() {
        let result = strategy.parsePlan(from: "", availableToolNames: sampleTools)

        XCTAssertEqual(result.count, 1)
        XCTAssertEqual(result[0].id, "step_1")
        XCTAssertEqual(result[0].description, "Complete the user's request directly")
    }

    func testParse_GarbageResponse_FallbackToSingleTask() {
        let input = "I'm not sure what you want me to do. Can you please clarify?"

        let result = strategy.parsePlan(from: input, availableToolNames: sampleTools)

        XCTAssertEqual(result.count, 1)
        XCTAssertEqual(result[0].description, "Complete the user's request directly")
    }

    func testParse_Fallback_UsesProvidedDescription() {
        // generatePlan passes the ORIGINAL QUERY here — a placeholder description
        // became the subtask's ENTIRE task (observed live: gemma4 asked "Please
        // provide a request so I can assist you.").
        let result = strategy.parsePlan(
            from: "",
            availableToolNames: sampleTools,
            fallbackDescription: "Create devgentic_test in /tmp with two files"
        )

        XCTAssertEqual(result.count, 1)
        XCTAssertEqual(result[0].description, "Create devgentic_test in /tmp with two files")
    }

    func testParse_ToolOnlySteps_KeepBracketContentAsDescription() {
        // Observed live (gemma4): every step was bracket-only → all descriptions
        // emptied after the strip → the whole multi-step plan collapsed to the
        // single-task fallback. The bracket content must survive as the description.
        let input = """
        1. [file_search]
        2. [run_command]
        """

        let result = strategy.parsePlan(from: input, availableToolNames: sampleTools)

        XCTAssertEqual(result.count, 2, "Tool-only steps must not vanish")
        XCTAssertEqual(result[0].description, "file_search")
        XCTAssertEqual(result[0].toolHints, ["file_search"])
        XCTAssertEqual(result[1].description, "run_command")
        XCTAssertEqual(result[1].toolHints, ["run_command"])
    }

    // MARK: - OutputSanitizer Integration

    func testParse_MarkdownFenced_StillParses() {
        let input = """
        ```
        1. Search for config files [file_search]
        2. Read the config [read_file]
        ```
        """

        let result = strategy.parsePlan(from: input, availableToolNames: sampleTools)

        XCTAssertEqual(result.count, 2)
        XCTAssertEqual(result[0].toolHints, ["file_search"])
    }

    func testParse_ThinkBlockWrapped_StillParses() {
        let input = """
        <think>
        Let me think about how to decompose this task...
        I should break it into 2 steps.
        </think>
        1. Find the relevant files [file_search]
        2. Read and analyze them [read_file]
        """

        let result = strategy.parsePlan(from: input, availableToolNames: sampleTools)

        XCTAssertEqual(result.count, 2)
        XCTAssertEqual(result[0].description, "Find the relevant files")
    }

    // MARK: - Extra Whitespace / Indentation

    func testParse_ExtraWhitespace_ParsesCleanly() {
        let input = """
           1.   Search for the log files
          2.  Read their contents
        """

        let result = strategy.parsePlan(from: input, availableToolNames: sampleTools)

        XCTAssertEqual(result.count, 2)
        XCTAssertEqual(result[0].description, "Search for the log files")
        XCTAssertEqual(result[1].description, "Read their contents")
    }

    // MARK: - Single Step

    func testParse_SingleStep_ReturnsSingleSubTask() {
        let input = "1. Just do the thing"

        let result = strategy.parsePlan(from: input, availableToolNames: sampleTools)

        XCTAssertEqual(result.count, 1)
        XCTAssertEqual(result[0].description, "Just do the thing")
    }

    // MARK: - Mixed Numbering Styles

    func testParse_MixedNumberingStyles_AllParse() {
        let input = """
        1. First step
        2) Second step
        3: Third step
        """

        let result = strategy.parsePlan(from: input, availableToolNames: sampleTools)

        XCTAssertEqual(result.count, 3)
        XCTAssertEqual(result[0].description, "First step")
        XCTAssertEqual(result[1].description, "Second step")
        XCTAssertEqual(result[2].description, "Third step")
    }

    // MARK: - Default State Verification

    func testParse_AllSubTasks_HaveCorrectDefaults() {
        let input = """
        1. First task
        2. Second task
        """

        let result = strategy.parsePlan(from: input, availableToolNames: sampleTools)

        for task in result {
            XCTAssertEqual(task.status, .pending)
            XCTAssertNil(task.result)
            XCTAssertNil(task.dependsOn)
        }
    }

    // MARK: - Empty Available Tools (no validation)

    func testParse_EmptyToolRegistry_BracketsStillParsedButAllDiscarded() {
        let input = "1. Do the thing [file_search, run_command]"

        let result = strategy.parsePlan(from: input, availableToolNames: [])

        XCTAssertEqual(result.count, 1)
        XCTAssertEqual(result[0].description, "Do the thing")
        XCTAssertNil(result[0].toolHints, "With empty registry, all tool hints should be discarded")
    }

    // MARK: - Case Insensitive Tool Validation

    func testParse_CaseInsensitiveToolMatch_Validates() {
        let input = "1. Search files [File_Search, READ_FILE]"

        let result = strategy.parsePlan(from: input, availableToolNames: sampleTools)

        XCTAssertEqual(result.count, 1)
        // Tools should be preserved with original casing from LLM output
        XCTAssertEqual(result[0].toolHints?.count, 2)
    }
}
