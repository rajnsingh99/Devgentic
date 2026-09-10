// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2026 Raj Singh
//
//  BalancedJSONScannerTests.swift
//  DevgenticTests
//
//  Tests for the shared balanced-block scanner (#15 sub-issue 5), with emphasis on the
//  string/escape edge cases that the old hand-rolled scanners got wrong.
//

import XCTest
@testable import devgentic

final class BalancedJSONScannerTests: XCTestCase {

    private func object(_ s: String) -> String? {
        BalancedJSONScanner.firstObject(in: s).map(String.init)
    }
    private func array(_ s: String) -> String? {
        BalancedJSONScanner.firstArray(in: s).map(String.init)
    }

    // MARK: - Objects

    func testSimpleObject() {
        XCTAssertEqual(object(#"{"a":1}"#), #"{"a":1}"#)
    }

    func testNestedObject() {
        XCTAssertEqual(object(#"{"a":{"b":2}}"#), #"{"a":{"b":2}}"#)
    }

    func testObject_WithTrailingText() {
        XCTAssertEqual(object(#"{"a":1} and then prose"#), #"{"a":1}"#)
    }

    func testObject_BraceInsideStringIsIgnored() {
        // The `}` inside the string value must NOT close the object early.
        // (The MistralXML inline scan — no string-state — got this wrong.)
        XCTAssertEqual(object(#"{"path":"/a}b"}"#), #"{"path":"/a}b"}"#)
    }

    func testObject_EscapedQuoteInsideStringIsIgnored() {
        // `\"` is an escaped quote, not a string boundary.
        XCTAssertEqual(object(#"{"a":"x\"y"}"#), #"{"a":"x\"y"}"#)
    }

    func testObject_EscapedBackslashBeforeClosingQuote_Balances() {
        // `{"k":"x\\"}` — value is `x\` (escaped backslash), then a REAL closing quote.
        // The old `prevChar != "\\"` scanners (Ollama / ReActMarkdown) treated that closing
        // quote as escaped, never closed the string, and returned nil. The escaped-flag
        // scanner closes correctly.
        XCTAssertEqual(object(#"{"k":"x\\"}"#), #"{"k":"x\\"}"#)
    }

    func testObject_Unbalanced_ReturnsNil() {
        XCTAssertNil(object(#"{"k":1"#))
    }

    func testObject_NoOpener_ReturnsNil() {
        XCTAssertNil(object("no json here"))
    }

    // MARK: - Arrays

    func testSimpleArray() {
        XCTAssertEqual(array("[1,2,[3]]"), "[1,2,[3]]")
    }

    func testArray_BracketInsideStringIsIgnored() {
        XCTAssertEqual(array(#"["a]b"]"#), #"["a]b"]"#)
    }

    // MARK: - splitProseAndBlock

    func testSplit_ObjectAfterProse() {
        let (prose, block) = BalancedJSONScanner.splitProseAndBlock(in: #"prose here {"k":1} tail"#)
        XCTAssertEqual(String(prose), "prose here ")
        XCTAssertEqual(block.map(String.init), #"{"k":1}"#)
    }

    func testSplit_ArrayOpenerFirst() {
        let (_, block) = BalancedJSONScanner.splitProseAndBlock(in: "x [1,2] y")
        XCTAssertEqual(block.map(String.init), "[1,2]")
    }

    func testSplit_NoBlock() {
        let (prose, block) = BalancedJSONScanner.splitProseAndBlock(in: "just prose")
        XCTAssertEqual(String(prose), "just prose")
        XCTAssertNil(block)
    }

    func testSplit_EscapedBackslashBlock() {
        // The escape-bug case in the prose-split context.
        let (_, block) = BalancedJSONScanner.splitProseAndBlock(in: #"pre {"k":"x\\"} post"#)
        XCTAssertEqual(block.map(String.init), #"{"k":"x\\"}"#)
    }

    // MARK: - from: start index

    func testFrom_SkipsEarlierOpener() {
        let text = #"first {"a":1} second {"b":2}"#
        guard let firstClose = text.firstIndex(of: "}") else { return XCTFail("setup") }
        let after = text.index(after: firstClose)
        XCTAssertEqual(BalancedJSONScanner.firstObject(in: text, from: after).map(String.init), #"{"b":2}"#)
    }
}
