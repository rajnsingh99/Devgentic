// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
//
//  PerformanceOptimizationTests.swift
//  DevgenticTests
//
//  Created by Raj Singh.
//

import XCTest
import SwiftUI
@testable import devgentic

// MARK: - P14: Timeline Grouping Tests

final class TimelineGroupingTests: XCTestCase {

    // MARK: - Correctness

    func testEmptyEventsProducesNoNodes() {
        let nodes = AgentTimelineView.buildGroupedNodes(from: [], isStreaming: false)
        XCTAssertTrue(nodes.isEmpty)
    }

    func testSingleThoughtProducesOneNode() {
        let events: [TimelineEvent] = [
            .thought(id: UUID(), text: "Thinking about the problem...")
        ]
        // When not streaming, a trailing thought gets deduplicated
        let nodesStreaming = AgentTimelineView.buildGroupedNodes(from: events, isStreaming: true)
        XCTAssertEqual(nodesStreaming.count, 1)
        if case .thought(_, let text) = nodesStreaming[0] {
            XCTAssertEqual(text, "Thinking about the problem...")
        } else {
            XCTFail("Expected thought node")
        }
    }

    /// ⚠️ UPDATED 2026-09-12 (tc-11). This used to pass NO `finalContentText` and still assert the
    /// thought was dropped — pass 1 ran unconditionally. It is now gated on there actually being
    /// an answer below to duplicate, which is the premise the pass's own comment states, so the
    /// test supplies one. Its twin below covers the case that used to lose the narrative.
    func testTrailingThoughtDeduplicatedWhenNotStreaming() {
        let events: [TimelineEvent] = [
            .toolExecution(ToolExecutionData(id: UUID(), name: "read_file", params: "{}", output: "content", isSuccess: true, isExecuting: false)),
            .thought(id: UUID(), text: "Final summary")
        ]
        let nodes = AgentTimelineView.buildGroupedNodes(
            from: events, isStreaming: false, finalContentText: "Here is the answer."
        )
        // The trailing thought should be removed, leaving the lone tool as a plain
        // `.action` row (a collapsible `.actionGroup` requires 2+ tools by design).
        XCTAssertEqual(nodes.count, 1)
        if case .action(let event) = nodes[0] {
            if case .toolExecution(let data) = event {
                XCTAssertEqual(data.name, "read_file")
            } else {
                XCTFail("Expected the surviving node to be the tool execution")
            }
        } else {
            XCTFail("Expected a single .action node (single tools don't form groups)")
        }
    }

    /// ⚠️ THE tc-11 REGRESSION GUARD. With no answer below, the trailing narrative is the ONLY
    /// record of what the agent did — a cancelled or skipped run renders exactly this shape.
    /// Mutation that must kill this: drop `hasFinalAnswerBelow` from pass 1's condition.
    func testTrailingThoughtSurvivesWhenThereIsNoFinalAnswerBelow() {
        let events: [TimelineEvent] = [
            .toolExecution(ToolExecutionData(id: UUID(), name: "read_file", params: "{}", output: "content", isSuccess: true, isExecuting: false)),
            .thought(id: UUID(), text: "Checking the config before giving up")
        ]
        let nodes = AgentTimelineView.buildGroupedNodes(from: events, isStreaming: false)
        XCTAssertEqual(nodes.count, 2,
                       "nothing duplicates the thought, so deleting it destroys the only 'why' the user has")
    }

    /// A synthetic stopped-run placeholder is not an answer either — it is the marker for a run
    /// that produced nothing, which is precisely when the narrative matters most.
    func testTrailingThoughtSurvivesWhenTheAnswerIsOnlyAStoppedPlaceholder() {
        let events: [TimelineEvent] = [
            .toolExecution(ToolExecutionData(id: UUID(), name: "read_file", params: "{}", output: "content", isSuccess: true, isExecuting: false)),
            .thought(id: UUID(), text: "Checking the config before giving up")
        ]
        let nodes = AgentTimelineView.buildGroupedNodes(
            from: events, isStreaming: false,
            finalContentText: ChatMessage.stoppedRunPlaceholder
        )
        XCTAssertEqual(nodes.count, 2)
    }

    func testTrailingThoughtKeptWhenStreaming() {
        let events: [TimelineEvent] = [
            .toolExecution(ToolExecutionData(id: UUID(), name: "read_file", params: "{}", output: "content", isSuccess: true, isExecuting: false)),
            .thought(id: UUID(), text: "Still thinking...")
        ]
        let nodes = AgentTimelineView.buildGroupedNodes(from: events, isStreaming: true)
        XCTAssertEqual(nodes.count, 2)
    }

    func testConsecutiveToolsGroupedTogether() {
        let events: [TimelineEvent] = [
            .toolExecution(ToolExecutionData(id: UUID(), name: "read_file", params: "{}", output: "a", isSuccess: true, isExecuting: false)),
            .toolExecution(ToolExecutionData(id: UUID(), name: "write_file", params: "{}", output: "b", isSuccess: true, isExecuting: false)),
            .toolExecution(ToolExecutionData(id: UUID(), name: "execute_shell", params: "{}", output: "c", isSuccess: true, isExecuting: false))
        ]
        let nodes = AgentTimelineView.buildGroupedNodes(from: events, isStreaming: true)
        XCTAssertEqual(nodes.count, 1)
        if case .actionGroup(let actions) = nodes[0] {
            XCTAssertEqual(actions.count, 3)
        } else {
            XCTFail("Expected single action group with 3 tools")
        }
    }

    func testThoughtBreaksActionGroup() {
        let events: [TimelineEvent] = [
            .toolExecution(ToolExecutionData(id: UUID(), name: "read_file", params: "{}", output: "a", isSuccess: true, isExecuting: false)),
            .thought(id: UUID(), text: "Let me analyze..."),
            .toolExecution(ToolExecutionData(id: UUID(), name: "write_file", params: "{}", output: "b", isSuccess: true, isExecuting: false))
        ]
        let nodes = AgentTimelineView.buildGroupedNodes(from: events, isStreaming: true)
        XCTAssertEqual(nodes.count, 3) // group(1 tool) + thought + group(1 tool)
    }

    func testMilestoneBreaksActionGroup() {
        let events: [TimelineEvent] = [
            .toolExecution(ToolExecutionData(id: UUID(), name: "read_file", params: "{}", output: "a", isSuccess: true, isExecuting: false)),
            .capabilityMilestone(id: UUID(), kind: .planGenerated, detail: "Generated plan"),
            .toolExecution(ToolExecutionData(id: UUID(), name: "write_file", params: "{}", output: "b", isSuccess: true, isExecuting: false))
        ]
        let nodes = AgentTimelineView.buildGroupedNodes(from: events, isStreaming: true)
        XCTAssertEqual(nodes.count, 3) // group(1) + milestone + group(1)
    }

    func testMixedMediaAndToolsGroupTogether() {
        let events: [TimelineEvent] = [
            .toolExecution(ToolExecutionData(id: UUID(), name: "generate_image", params: "{}", output: nil, isSuccess: true, isExecuting: false)),
            .mediaGeneration(id: UUID(), toolName: "flux", artifact: nil, isComplete: true)
        ]
        let nodes = AgentTimelineView.buildGroupedNodes(from: events, isStreaming: true)
        XCTAssertEqual(nodes.count, 1)
        if case .actionGroup(let actions) = nodes[0] {
            XCTAssertEqual(actions.count, 2)
        } else {
            XCTFail("Expected single action group with tool + media")
        }
    }

    // MARK: - Performance

    func testGroupingPerformanceWith500Events() {
        // Build a realistic large event list: alternating thoughts and tool groups
        var events: [TimelineEvent] = []
        for i in 0..<500 {
            if i % 5 == 0 {
                events.append(.thought(id: UUID(), text: "Step \(i): analyzing..."))
            } else {
                events.append(.toolExecution(ToolExecutionData(
                    id: UUID(), name: "tool_\(i % 10)", params: "{\"arg\": \"\(i)\"}",
                    output: String(repeating: "x", count: 200), isSuccess: true, isExecuting: false
                )))
            }
        }

        measure {
            for _ in 0..<100 {
                let _ = AgentTimelineView.buildGroupedNodes(from: events, isStreaming: true)
            }
        }
        // 100 iterations of 500 events = 50,000 grouping operations per measure block.
        // Should complete well under 1 second.
    }
}

// MARK: - P15: Search Highlighting Tests

final class SearchHighlightingTests: XCTestCase {

    // MARK: - Correctness

    func testEmptyQueryReturnsUnmodifiedText() {
        let result = AgentBubbleContentView.highlightText("Hello world", query: "")
        XCTAssertEqual(String(result.characters), "Hello world")
    }

    func testNoMatchReturnsUnmodifiedText() {
        let result = AgentBubbleContentView.highlightText("Hello world", query: "xyz")
        XCTAssertEqual(String(result.characters), "Hello world")
        // Verify no background color was set
        for run in result.runs {
            XCTAssertNil(run.backgroundColor)
        }
    }

    func testSingleMatchHighlighted() {
        let result = AgentBubbleContentView.highlightText("Hello world", query: "world")
        XCTAssertEqual(String(result.characters), "Hello world")
        // The "world" portion should have a background color
        var foundHighlight = false
        for run in result.runs {
            if run.backgroundColor != nil {
                foundHighlight = true
                let text = String(result[run.range].characters)
                XCTAssertEqual(text, "world")
            }
        }
        XCTAssertTrue(foundHighlight, "Expected 'world' to be highlighted")
    }

    func testMultipleMatchesHighlighted() {
        let result = AgentBubbleContentView.highlightText("the cat and the dog", query: "the")
        var highlightCount = 0
        for run in result.runs {
            if run.backgroundColor != nil {
                highlightCount += 1
                let text = String(result[run.range].characters)
                XCTAssertEqual(text, "the")
            }
        }
        XCTAssertEqual(highlightCount, 2, "Expected 2 highlights for 'the'")
    }

    func testCaseInsensitiveMatch() {
        let result = AgentBubbleContentView.highlightText("Hello HELLO hello", query: "hello")
        var highlightCount = 0
        for run in result.runs {
            if run.backgroundColor != nil { highlightCount += 1 }
        }
        XCTAssertEqual(highlightCount, 3, "Expected 3 case-insensitive highlights")
    }

    func testActiveMatchGetsDifferentColor() {
        let result = AgentBubbleContentView.highlightText("aaa bbb aaa", query: "aaa", activeMatchIndex: 1)
        var colors: [Color?] = []
        for run in result.runs {
            if run.backgroundColor != nil {
                colors.append(run.backgroundColor)
            }
        }
        XCTAssertEqual(colors.count, 2, "Expected 2 highlights")
        // The two highlights should have different colors (active vs inactive)
        XCTAssertNotEqual(colors[0], colors[1], "Active match should have a different color")
    }

    func testAdjacentMatchesDoNotCrash() {
        // Searching "aa" in "aaaa" should find 2 non-overlapping matches at [0..2] and [2..4].
        // They may merge into a single AttributedString run since they're adjacent with same style.
        // The key test: it doesn't crash and the entire string is highlighted.
        let result = AgentBubbleContentView.highlightText("aaaa", query: "aa")
        // Every character should be highlighted (no unhighlighted runs)
        let unhighlightedCount = result.runs.filter { $0.backgroundColor == nil }.count
        XCTAssertEqual(unhighlightedCount, 0, "All characters should be highlighted")
    }

    func testUnicodeTextHighlighting() {
        let result = AgentBubbleContentView.highlightText("Hello 🌍 world 🌍 end", query: "🌍")
        var highlightCount = 0
        for run in result.runs {
            if run.backgroundColor != nil {
                highlightCount += 1
                let text = String(result[run.range].characters)
                XCTAssertEqual(text, "🌍")
            }
        }
        XCTAssertEqual(highlightCount, 2, "Expected 2 emoji highlights")
    }

    func testEntireStringIsMatch() {
        let result = AgentBubbleContentView.highlightText("test", query: "test")
        var foundHighlight = false
        for run in result.runs {
            if run.backgroundColor != nil {
                foundHighlight = true
                XCTAssertEqual(String(result[run.range].characters), "test")
            }
        }
        XCTAssertTrue(foundHighlight)
    }

    // MARK: - Performance

    func testHighlightPerformanceOnLargeText() {
        // 50KB of text with a common word appearing every ~500 chars (~100 matches)
        let paragraph = "This is a test paragraph with some content that includes various words. "
        let largeText = String(repeating: paragraph, count: 700) // ~50KB
        let query = "test"

        measure {
            for _ in 0..<10 {
                let _ = AgentBubbleContentView.highlightText(largeText, query: query)
            }
        }
        // 10 iterations of 50KB text with ~700 matches per measure block.
        // The optimized O(n) algorithm should handle this well under 1 second.
    }

    func testHighlightPerformanceWithManyMatches() {
        // Worst case: single-character query on repetitive text (~50K matches)
        let largeText = String(repeating: "ab", count: 25_000) // 50K chars, 25K matches for "a"
        let query = "a"

        measure {
            let _ = AgentBubbleContentView.highlightText(largeText, query: query)
        }
        // Single iteration with 25K matches. Tests the highlighting loop efficiency.
    }
}
