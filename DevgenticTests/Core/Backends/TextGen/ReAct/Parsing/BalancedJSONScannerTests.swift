// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
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
        // ⚠️ `tail` asserted. This test fed exactly this string and checked only `prose` and
        // `block`, so it stayed green while `" tail"` was silently discarded — which is how the
        // content loss survived review.
        let (prose, block, tail) = BalancedJSONScanner.splitProseAndBlock(in: #"prose here {"k":1} tail"#)
        XCTAssertEqual(String(prose), "prose here ")
        XCTAssertEqual(block.map(String.init), #"{"k":1}"#)
        XCTAssertEqual(String(tail), " tail", "text after the block must be returned, not dropped")
    }

    func testSplit_ArrayOfScalarsIsNotABlock() {
        // ⚠️ CHANGED BEHAVIOUR, deliberately. `[1,2]` is valid JSON but cannot be a tool call, and
        // treating it as one is what let `[1]` in ordinary prose swallow the rest of a sentence.
        let (prose, block, tail) = BalancedJSONScanner.splitProseAndBlock(in: "x [1,2] y")
        XCTAssertNil(block, "an array of scalars is prose, not a leaked tool call")
        XCTAssertEqual(String(prose), "x [1,2] y", "the whole text must survive as prose")
        XCTAssertTrue(tail.isEmpty)
    }

    func testSplit_ArrayOfObjectsIsABlock() {
        // The shape a real leaked tool call takes when a model emits several at once.
        let (_, block, _) = BalancedJSONScanner.splitProseAndBlock(in: #"go [{"name":"ls"}] now"#)
        XCTAssertEqual(block.map(String.init), #"[{"name":"ls"}]"#)
    }

    func testSplit_NoBlock() {
        let (prose, block, tail) = BalancedJSONScanner.splitProseAndBlock(in: "just prose")
        XCTAssertEqual(String(prose), "just prose")
        XCTAssertNil(block)
        XCTAssertTrue(tail.isEmpty)
    }

    // MARK: - Bracketed prose is prose (F4)

    /// ⚠️⚠️ THE REGRESSION TABLE. Every one of these lost most of its text to the old splitter,
    /// measured against the real implementation before the fix. Balanced brackets are everywhere
    /// in ordinary model output; none of these is JSON.
    func testSplit_BracketedProseIsNeverTreatedAsABlock() {
        let prose = [
            "I read the file but the output was [truncated] so I could not see the end of it.",
            "See [the docs](https://example.com) for details on the retry policy.",
            "This follows the approach in [1] which uses exponential backoff.",
            "Use the pattern [a-z]+ to match lowercase words in the input.",
            "The log line [INFO] startup complete confirms the service booted.",
            "The set {alpha, beta} is unordered.",
        ]
        for text in prose {
            let (before, block, tail) = BalancedJSONScanner.splitProseAndBlock(in: text)
            XCTAssertNil(block, "treated as a JSON block: \(text)")
            XCTAssertEqual(String(before), text, "text was split: \(text)")
            XCTAssertTrue(tail.isEmpty)
        }
    }

    /// The other direction — the fix must not stop finding real leaked tool calls, which is the
    /// entire reason the split exists (G7).
    func testSplit_StillFindsALeakedToolCallAfterBracketedProse() {
        let text = #"The output was [truncated]. Retrying: {"name":"read_file","arguments":{"path":"a"}} done."#
        let (before, block, tail) = BalancedJSONScanner.splitProseAndBlock(in: text)

        XCTAssertEqual(block.map(String.init), #"{"name":"read_file","arguments":{"path":"a"}}"#,
                       "rejecting the bracketed word must not abandon the search for a real block")
        XCTAssertTrue(String(before).contains("[truncated]"), "the bracketed prose stays in the prose")
        XCTAssertEqual(String(tail), " done.")
    }

    func testIsToolCallShaped_Discriminates() {
        // Pinned directly so a future relaxation to "any valid JSON" is visible as a decision.
        XCTAssertTrue(BalancedJSONScanner.isToolCallShaped(#"{"name":"x"}"#[...]))
        XCTAssertTrue(BalancedJSONScanner.isToolCallShaped(#"[{"name":"x"}]"#[...]))
        XCTAssertFalse(BalancedJSONScanner.isToolCallShaped("[1]"[...]), "valid JSON, but not a tool call")
        XCTAssertFalse(BalancedJSONScanner.isToolCallShaped("[truncated]"[...]))
        XCTAssertFalse(BalancedJSONScanner.isToolCallShaped("[]"[...]), "an empty array carries no call")
        XCTAssertFalse(BalancedJSONScanner.isToolCallShaped(#"["a","b"]"#[...]))
    }

    func testSplit_EscapedBackslashBlock() {
        // The escape-bug case in the prose-split context.
        let (_, block, tail) = BalancedJSONScanner.splitProseAndBlock(in: #"pre {"k":"x\\"} post"#)
        XCTAssertEqual(block.map(String.init), #"{"k":"x\\"}"#)
        XCTAssertEqual(String(tail), " post")
    }

    // MARK: - from: start index

    func testFrom_SkipsEarlierOpener() {
        let text = #"first {"a":1} second {"b":2}"#
        guard let firstClose = text.firstIndex(of: "}") else { return XCTFail("setup") }
        let after = text.index(after: firstClose)
        XCTAssertEqual(BalancedJSONScanner.firstObject(in: text, from: after).map(String.init), #"{"b":2}"#)
    }
}
