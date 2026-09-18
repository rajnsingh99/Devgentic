// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
//
//  EditMatcherTests.swift
//  DevgenticTests
//
//  TDD: Tier 1c — EditCodeTool Occurrence Counting + Whitespace Fallback
//

import XCTest
@testable import devgentic

final class EditMatcherTests: XCTestCase {

    // MARK: - Exact Match (Single Occurrence)

    func testApplyEdit_ExactMatch_SingleOccurrence_Applied() {
        let content = "func hello() {\n    print(\"hello\")\n}"
        let result = EditMatcher.applyEdit(content: content, oldString: "print(\"hello\")", newString: "print(\"world\")")

        if case .applied(let newContent) = result {
            XCTAssertTrue(newContent.contains("print(\"world\")"))
            XCTAssertFalse(newContent.contains("print(\"hello\")"))
        } else {
            XCTFail("Expected .applied, got \(result)")
        }
    }

    // MARK: - Multiple Occurrences (Ambiguous)

    func testApplyEdit_MultipleOccurrences_ReturnsAmbiguous() {
        let content = "let x = 1\nlet x = 1\nlet y = 2"
        let result = EditMatcher.applyEdit(content: content, oldString: "let x = 1", newString: "let x = 99")

        if case .ambiguous(let count) = result {
            XCTAssertEqual(count, 2)
        } else {
            XCTFail("Expected .ambiguous(2), got \(result)")
        }
    }

    // MARK: - Not Found

    func testApplyEdit_NotFound_ExactMismatch() {
        let content = "func hello() {}"
        let result = EditMatcher.applyEdit(content: content, oldString: "func goodbye() {}", newString: "func farewell() {}")

        XCTAssertEqual(result, .notFound)
    }

    // MARK: - Whitespace-Normalized Fallback

    func testApplyEdit_WhitespaceFallback_LeadingSpaces() {
        let content = "    func hello() {\n        print(\"hi\")\n    }"
        // old_string without leading whitespace should match the line with leading whitespace
        let result = EditMatcher.applyEdit(content: content, oldString: "func hello() {", newString: "func greet() {")

        if case .applied(let newContent) = result {
            XCTAssertTrue(newContent.contains("func greet() {"))
        } else {
            XCTFail("Expected .applied via whitespace fallback, got \(result)")
        }
    }

    func testApplyEdit_WhitespaceFallback_TrailingSpaces() {
        let content = "let x = 1   \nlet y = 2"
        let result = EditMatcher.applyEdit(content: content, oldString: "let x = 1", newString: "let x = 99")

        if case .applied(let newContent) = result {
            XCTAssertTrue(newContent.contains("let x = 99"))
        } else {
            XCTFail("Expected .applied via whitespace fallback, got \(result)")
        }
    }

    // MARK: - Empty New String (Deletion)

    func testApplyEdit_EmptyNewString_DeletesOldString() {
        let content = "line1\nline2\nline3"
        let result = EditMatcher.applyEdit(content: content, oldString: "line2", newString: "")

        if case .applied(let newContent) = result {
            XCTAssertEqual(newContent, "line1\n\nline3")
        } else {
            XCTFail("Expected .applied, got \(result)")
        }
    }

    // MARK: - Multi-Line Old String

    func testApplyEdit_MultiLineExact_Applied() {
        let content = "func a() {\n    print(\"a\")\n}\n\nfunc b() {\n    print(\"b\")\n}"
        let oldBlock = "func a() {\n    print(\"a\")\n}"
        let newBlock = "func a() {\n    print(\"updated\")\n}"
        let result = EditMatcher.applyEdit(content: content, oldString: oldBlock, newString: newBlock)

        if case .applied(let newContent) = result {
            XCTAssertTrue(newContent.contains("print(\"updated\")"))
            XCTAssertTrue(newContent.contains("print(\"b\")"), "Other function should be unchanged")
        } else {
            XCTFail("Expected .applied, got \(result)")
        }
    }

    // MARK: - Whitespace Fallback Limitation (Multi-Line)

    func testApplyEdit_MultiLineWhitespaceMismatch_NotFound() {
        // Whitespace fallback only works for single lines — multi-line blocks with different
        // whitespace should return .notFound (this is a known limitation, not a bug)
        let content = "    func hello() {\n        print(\"hi\")\n    }"
        let oldBlock = "func hello() {\n    print(\"hi\")\n}"
        let result = EditMatcher.applyEdit(content: content, oldString: oldBlock, newString: "replaced")

        // Multi-line block with different indentation won't match either exact or single-line fallback
        XCTAssertEqual(result, .notFound)
    }
}
