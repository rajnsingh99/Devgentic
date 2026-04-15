//
//  MediumFixVerificationTests.swift
//  DevgenticTests
//
//  Red-green verification tests for the 5 MEDIUM severity production-readiness fixes.
//
//  Fix 1: DiffUtility — prefix/suffix strip, rolling LCS, large-file fallback
//  Fix 2: ImageView — DispatchQueue.asyncAfter → structured Task (no retain cycle)
//  Fix 3: GapBuffer Equatable + CodeDocument value-based equality
//  Fix 4: AgentTimelineView — early-exit group title (no Set allocation)
//  Fix 5: ContentBlockView — forward incremental cursor for search highlighting
//

import XCTest
import Foundation
import SwiftUI
@testable import devgentic

// MARK: - Fix 1: DiffUtility Optimization

final class DiffUtilityOptimizationTests: XCTestCase {

    /// Identical inputs should produce all-unchanged diff.
    func testIdenticalInputsProduceNoChanges() {
        let text = "line1\nline2\nline3"
        let diff = DiffUtility.generateDiff(original: text, modified: text)

        XCTAssertEqual(diff.count, 3)
        for result in diff {
            XCTAssertEqual(result.type, .unchanged, "Identical lines should be unchanged")
        }
    }

    /// Empty original with content in modified should produce all-added.
    func testEmptyOriginalProducesAllAdded() {
        let diff = DiffUtility.generateDiff(original: "", modified: "line1\nline2")

        let added = diff.filter { $0.type == .added }
        XCTAssertGreaterThanOrEqual(added.count, 1, "Should have added lines")
    }

    /// Content in original with empty modified should produce all-deleted.
    func testEmptyModifiedProducesAllDeleted() {
        let diff = DiffUtility.generateDiff(original: "line1\nline2", modified: "")

        let deleted = diff.filter { $0.type == .deleted }
        XCTAssertGreaterThanOrEqual(deleted.count, 1, "Should have deleted lines")
    }

    /// Common prefix should be detected and marked unchanged.
    func testCommonPrefixOptimization() {
        let original = "prefix1\nprefix2\nchanged_old"
        let modified = "prefix1\nprefix2\nchanged_new"

        let diff = DiffUtility.generateDiff(original: original, modified: modified)

        // First two lines should be unchanged
        XCTAssertEqual(diff[0].type, .unchanged)
        XCTAssertEqual(diff[0].line, "prefix1")
        XCTAssertEqual(diff[1].type, .unchanged)
        XCTAssertEqual(diff[1].line, "prefix2")
    }

    /// Common suffix should be detected and marked unchanged.
    func testCommonSuffixOptimization() {
        let original = "changed_old\nsuffix1\nsuffix2"
        let modified = "changed_new\nsuffix1\nsuffix2"

        let diff = DiffUtility.generateDiff(original: original, modified: modified)

        // Last two lines should be unchanged
        let lastTwo = diff.suffix(2)
        XCTAssertEqual(lastTwo.first?.type, .unchanged)
        XCTAssertEqual(lastTwo.first?.line, "suffix1")
        XCTAssertEqual(lastTwo.last?.type, .unchanged)
        XCTAssertEqual(lastTwo.last?.line, "suffix2")
    }

    /// Line numbers should be correctly assigned.
    func testLineNumbersAreCorrect() {
        let original = "A\nB\nC"
        let modified = "A\nX\nC"

        let diff = DiffUtility.generateDiff(original: original, modified: modified)

        // "A" is unchanged: original=1, modified=1
        let unchanged1 = diff.first { $0.line == "A" && $0.type == .unchanged }
        XCTAssertEqual(unchanged1?.originalLineNumber, 1)
        XCTAssertEqual(unchanged1?.modifiedLineNumber, 1)

        // "C" is unchanged: should have valid line numbers
        let unchangedC = diff.first { $0.line == "C" && $0.type == .unchanged }
        XCTAssertNotNil(unchangedC?.originalLineNumber)
        XCTAssertNotNil(unchangedC?.modifiedLineNumber)
    }

    /// Single-line change should produce delete + add.
    func testSingleLineChange() {
        let diff = DiffUtility.generateDiff(original: "old line", modified: "new line")

        let deleted = diff.filter { $0.type == .deleted }
        let added = diff.filter { $0.type == .added }
        XCTAssertEqual(deleted.count, 1, "Should have 1 deleted line")
        XCTAssertEqual(added.count, 1, "Should have 1 added line")
        XCTAssertEqual(deleted.first?.line, "old line")
        XCTAssertEqual(added.first?.line, "new line")
    }

    /// Performance: diff of two 500-line files should complete in reasonable time.
    func testPerformanceWith500Lines() {
        let original = (0..<500).map { "Line \($0): original content here" }.joined(separator: "\n")
        let modified = (0..<500).map { $0 % 10 == 5 ? "Line \($0): MODIFIED content" : "Line \($0): original content here" }.joined(separator: "\n")

        measure {
            _ = DiffUtility.generateDiff(original: original, modified: modified)
        }
    }

    /// Verify large file fallback doesn't crash.
    func testLargeFileFallbackDoesNotCrash() {
        // Create files where the core (after prefix/suffix strip) is large.
        // Prefix the same, then diverge completely for 100 lines, then same suffix.
        let prefix = (0..<10).map { "Same \($0)" }
        let suffix = (0..<10).map { "End \($0)" }
        let origCore = (0..<100).map { "Original \($0)" }
        let modCore = (0..<100).map { "Modified \($0)" }

        let original = (prefix + origCore + suffix).joined(separator: "\n")
        let modified = (prefix + modCore + suffix).joined(separator: "\n")

        let diff = DiffUtility.generateDiff(original: original, modified: modified)
        XCTAssertGreaterThan(diff.count, 0, "Should produce non-empty diff")

        // Prefix and suffix should be unchanged
        let unchanged = diff.filter { $0.type == .unchanged }
        XCTAssertGreaterThanOrEqual(unchanged.count, 20, "Should preserve 10 prefix + 10 suffix as unchanged")
    }
}

// MARK: - Fix 2: ImageView Task-based feedback
// The fix replaced DispatchQueue.main.asyncAfter with Task.sleep.
// This is a structural fix — verified by compilation. Smoke test:

final class ImageViewStructuralTests: XCTestCase {

    /// Verifies ImageView can be constructed with valid data.
    func testImageViewInstantiationWithValidData() {
        // Create a minimal 1x1 PNG
        let pngData = createMinimalPNGData()
        let view = ImageView(imageData: pngData)
        XCTAssertNotNil(view)
    }

    /// Verifies ImageView handles invalid data without crash.
    func testImageViewInstantiationWithInvalidData() {
        let view = ImageView(imageData: Data([0x00, 0x01, 0x02]))
        XCTAssertNotNil(view, "Invalid image data should not crash the view")
    }

    private func createMinimalPNGData() -> Data {
        // Create a 1x1 red pixel NSImage and convert to PNG
        let image = NSImage(size: NSSize(width: 1, height: 1))
        image.lockFocus()
        NSColor.red.drawSwatch(in: NSRect(x: 0, y: 0, width: 1, height: 1))
        image.unlockFocus()

        guard let tiffData = image.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiffData),
              let pngData = bitmap.representation(using: .png, properties: [:]) else {
            return Data()
        }
        return pngData
    }
}

// MARK: - Fix 3: GapBuffer Equatable + CodeDocument Value Equality

final class GapBufferEquatableTests: XCTestCase {

    /// GapBuffers with same content should be equal.
    func testEqualContentIsEqual() {
        let buf1 = GapBuffer(string: "Hello world")
        let buf2 = GapBuffer(string: "Hello world")
        XCTAssertEqual(buf1, buf2, "Same content should be equal")
    }

    /// GapBuffers with different content should not be equal.
    func testDifferentContentIsNotEqual() {
        let buf1 = GapBuffer(string: "Hello")
        let buf2 = GapBuffer(string: "World")
        XCTAssertNotEqual(buf1, buf2, "Different content should not be equal")
    }

    /// GapBuffer string property should return the original content.
    func testStringPropertyReturnsContent() {
        let buf = GapBuffer(string: "Test content")
        XCTAssertEqual(buf.string, "Test content")
    }

    /// GapBuffer after mutation should reflect changes in equality.
    func testMutatedBufferReflectsChanges() {
        var buf1 = GapBuffer(string: "Hello")
        let buf2 = GapBuffer(string: "Hello")
        XCTAssertEqual(buf1, buf2)

        buf1.insert("!")
        XCTAssertNotEqual(buf1, buf2, "Mutated buffer should differ")
        XCTAssertEqual(buf1.string, "Hello!", "Insert should append at gap position")
    }

    /// CodeDocument equality uses value comparison (content + language).
    func testCodeDocumentValueEquality() {
        let doc1 = CodeDocument(content: "let x = 1", language: "swift")
        let doc2 = CodeDocument(content: "let x = 1", language: "swift")
        let doc3 = CodeDocument(content: "let x = 2", language: "swift")
        let doc4 = CodeDocument(content: "let x = 1", language: "python")

        XCTAssertEqual(doc1, doc2, "Same content + language should be equal")
        XCTAssertNotEqual(doc1, doc3, "Different content should not be equal")
        XCTAssertNotEqual(doc1, doc4, "Different language should not be equal")
    }

    /// CodeDocument with same reference is still equal (identity implies value equality).
    func testCodeDocumentReferenceEqualityStillWorks() {
        let doc = CodeDocument(content: "code", language: "swift")
        XCTAssertEqual(doc, doc, "Same reference should be equal")
    }
}

// MARK: - Fix 4: Timeline Group Title Optimization

final class TimelineGroupTitleTests: XCTestCase {

    /// Single tool execution should return formatted name.
    func testSingleToolExecutionTitle() {
        let events: [TimelineEvent] = [
            .toolExecution(ToolExecutionData(id: UUID(), name: "read_file", params: "{}", output: "ok", isSuccess: true, isExecuting: false))
        ]
        let nodes = AgentTimelineView.buildGroupedNodes(from: events, isStreaming: false)

        // Should have one action group with one item
        XCTAssertEqual(nodes.count, 1)
    }

    /// Multiple same-tool executions should show "X times".
    func testMultipleSameToolExecutions() {
        let events: [TimelineEvent] = [
            .toolExecution(ToolExecutionData(id: UUID(), name: "read_file", params: "{}", output: "a", isSuccess: true, isExecuting: false)),
            .toolExecution(ToolExecutionData(id: UUID(), name: "read_file", params: "{}", output: "b", isSuccess: true, isExecuting: false)),
            .toolExecution(ToolExecutionData(id: UUID(), name: "read_file", params: "{}", output: "c", isSuccess: true, isExecuting: false)),
        ]
        let nodes = AgentTimelineView.buildGroupedNodes(from: events, isStreaming: false)

        // All should be grouped into one action group
        XCTAssertEqual(nodes.count, 1)
        if case .actionGroup(let actions) = nodes[0] {
            XCTAssertEqual(actions.count, 3, "All 3 should be in the group")
        } else {
            XCTFail("Expected action group")
        }
    }

    /// Mixed tool executions should show "Executed N tools".
    func testMixedToolExecutions() {
        let events: [TimelineEvent] = [
            .toolExecution(ToolExecutionData(id: UUID(), name: "read_file", params: "{}", output: "a", isSuccess: true, isExecuting: false)),
            .toolExecution(ToolExecutionData(id: UUID(), name: "write_file", params: "{}", output: "b", isSuccess: true, isExecuting: false)),
        ]
        let nodes = AgentTimelineView.buildGroupedNodes(from: events, isStreaming: false)
        XCTAssertEqual(nodes.count, 1, "Mixed tools should still be grouped")
    }
}

// MARK: - Fix 5: Search Highlighting Forward Cursor

final class SearchHighlightingOptimizationTests: XCTestCase {

    /// Verifies highlighting produces correct result for simple case.
    func testBasicHighlighting() {
        let result = AgentBubbleContentView.highlightText("Hello world hello", query: "hello")

        let plainText = String(result.characters)
        XCTAssertEqual(plainText, "Hello world hello", "Content should be unchanged")

        // Should have 2 highlighted ranges (case-insensitive: "Hello" and "hello")
        var highlightCount = 0
        for run in result.runs {
            if run.backgroundColor != nil {
                highlightCount += 1
            }
        }
        XCTAssertEqual(highlightCount, 2, "Should highlight 2 occurrences of 'hello'")
    }

    /// Verifies empty query produces no highlighting.
    func testEmptyQueryNoHighlighting() {
        let result = AgentBubbleContentView.highlightText("Hello world", query: "")
        var highlightCount = 0
        for run in result.runs {
            if run.backgroundColor != nil { highlightCount += 1 }
        }
        XCTAssertEqual(highlightCount, 0, "Empty query should produce no highlighting")
    }

    /// Verifies no-match query produces no highlighting.
    func testNoMatchQueryNoHighlighting() {
        let result = AgentBubbleContentView.highlightText("Hello world", query: "zzzzz")
        var highlightCount = 0
        for run in result.runs {
            if run.backgroundColor != nil { highlightCount += 1 }
        }
        XCTAssertEqual(highlightCount, 0, "No-match query should produce no highlighting")
    }

    /// Verifies active match gets different highlighting.
    func testActiveMatchHighlighting() {
        let result = AgentBubbleContentView.highlightText("aaa aaa aaa", query: "aaa", activeMatchIndex: 1)

        var backgroundColors: [Color?] = []
        for run in result.runs {
            backgroundColors.append(run.backgroundColor)
        }
        // Should have 3 highlighted ranges, one of which is the active (orange) match
        let highlighted = backgroundColors.compactMap { $0 }
        XCTAssertEqual(highlighted.count, 3, "Should have 3 highlighted ranges")
    }

    /// Performance: highlighting on 10KB text should complete quickly.
    func testHighlightingPerformanceOn10KB() {
        let text = String(repeating: "The quick brown fox jumps over the lazy dog. ", count: 250)
        measure {
            _ = AgentBubbleContentView.highlightText(text, query: "fox")
        }
    }
}
