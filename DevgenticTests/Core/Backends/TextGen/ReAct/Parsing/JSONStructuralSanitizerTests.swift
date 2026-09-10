// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2026 Raj Singh
//
//  JSONStructuralSanitizerTests.swift
//  DevgenticTests
//
//  The JSON sanitizers used to run their repair regexes over the WHOLE payload. An extracted
//  JSON object contains the file the model is writing — as the string value of
//  `arguments.content` — so every repair was also an edit to the user's source code, applied
//  silently because the payload stayed valid JSON either way.
//
//  Two halves to pin, and both matter:
//    1. structure is still repaired (or these parsers stop working on local models), and
//    2. string values come through byte-for-byte.
//
//  Same class as the `normalizePathArguments` bug — see `ActionEffectTests`.
//

import XCTest
@testable import devgentic

final class JSONStructuralSanitizerTests: XCTestCase {

    private func repair(_ s: String, keys: Bool = false) -> String {
        JSONStructuralSanitizer.repairingStructure(s, quotingUnquotedKeys: keys)
    }

    /// Decodes `arguments.content` the way the parsers do, so the assertions are about what
    /// actually reaches disk rather than about the payload text.
    private func writtenContent(_ payload: String, file: StaticString = #filePath, line: UInt = #line) -> String? {
        let repaired = repair(payload)
        guard let data = repaired.data(using: .utf8) else {
            XCTFail("not utf8", file: file, line: line); return nil
        }
        struct Payload: Decodable { let arguments: Args; struct Args: Decodable { let content: String } }
        guard let decoded = try? JSONDecoder().decode(Payload.self, from: data) else {
            XCTFail("payload did not decode after repair:\n\(repaired)", file: file, line: line); return nil
        }
        return decoded.arguments.content
    }

    // MARK: - Structure is still repaired

    func testTrailingCommasAreStillRemoved() {
        XCTAssertEqual(repair(#"{"a": 1,}"#), #"{"a": 1}"#)
        XCTAssertEqual(repair(#"[1, 2, 3,]"#), #"[1, 2, 3]"#)
        // `\s*` in the pattern spans newlines, so the whitespace goes with the comma. That
        // is pre-existing behaviour and only ever applies to structure now.
        XCTAssertEqual(repair("{\"a\": [1,\n],\n}"), "{\"a\": [1]}")
    }

    func testPythonLiteralsAreStillNormalized() {
        XCTAssertEqual(repair(#"{"a": True, "b": False, "c": None}"#),
                       #"{"a": true, "b": false, "c": null}"#)
        XCTAssertEqual(repair(#"{"a": NULL, "b": NaN}"#), #"{"a": null, "b": null}"#)
    }

    func testUnquotedKeysAreStillQuotedWhenRequested() {
        XCTAssertEqual(repair(#"{name: "read_file"}"#, keys: true), #"{ "name": "read_file"}"#)
    }

    /// The dialect parsers never quoted keys; unifying them must not widen that silently.
    func testUnquotedKeyRepairIsOptOutByDefault() {
        XCTAssertEqual(repair(#"{name: "x"}"#), #"{name: "x"}"#)
    }

    // MARK: - String values are data

    /// `\bNaN\b` → `null` turned this into `Double.null`, which does not compile.
    func testJavaNaNSurvives() {
        let java = "double d = Double.NaN;\nif (Double.isNaN(d)) { return; }"
        XCTAssertEqual(
            writtenContent(#"{"arguments": {"content": "\#(java.replacingOccurrences(of: "\n", with: "\\n"))"}}"#),
            java
        )
    }

    /// `\bNULL\b` → `null` silently rewrote every C null check.
    func testCNullCheckSurvives() {
        XCTAssertEqual(
            writtenContent(#"{"arguments": {"content": "if (ptr == NULL) { return NULL; }"}}"#),
            "if (ptr == NULL) { return NULL; }"
        )
    }

    /// Python source is the worst case — it is made of the exact tokens being repaired.
    func testPythonSourceSurvives() {
        XCTAssertEqual(
            writtenContent(#"{"arguments": {"content": "flag = True\nother = None\nassert flag is not False"}}"#),
            "flag = True\nother = None\nassert flag is not False"
        )
    }

    /// `,\s*([}\]])` deleted the trailing comma from an array initializer. The result still
    /// compiles in Java, which is what made it so hard to notice.
    func testTrailingCommaInsideAnArrayInitializerSurvives() {
        XCTAssertEqual(
            writtenContent(#"{"arguments": {"content": "int[] a = {\n  1,\n  2,\n};"}}"#),
            "int[] a = {\n  1,\n  2,\n};"
        )
    }

    /// The unquoted-key regex runs before raw newlines are escaped, so a bare `default:`
    /// line inside content was in "key position" as far as the regex could tell.
    func testSwitchLabelsInsideContentSurvive() {
        let src = "switch (x) {\ncase 1:\n  break;\ndefault:\n  break;\n}"
        let payload = #"{"arguments": {"content": "\#(src.replacingOccurrences(of: "\n", with: "\\n"))"}}"#
        let repaired = JSONStructuralSanitizer.repairingStructure(payload, quotingUnquotedKeys: true)
        struct P: Decodable { let arguments: A; struct A: Decodable { let content: String } }
        let decoded = try? JSONDecoder().decode(P.self, from: Data(repaired.utf8))
        XCTAssertEqual(decoded?.arguments.content, src)
    }

    /// A raw (unescaped) newline inside a string is what this pass runs BEFORE fixing. The
    /// walker keys on quotes, not lines, so string tracking must hold anyway.
    func testRawNewlineInsideAStringDoesNotBreakSpanTracking() {
        let out = repair("{\"content\": \"a = True\nb = None\", \"n\": True,}")
        XCTAssertTrue(out.contains("a = True\nb = None"), "content untouched, raw newline and all")
        XCTAssertTrue(out.contains("\"n\": true"), "the real literal outside the string is repaired")
        XCTAssertFalse(out.contains("true,}"), "and the trailing comma is gone")
    }

    /// Escaped quotes must not end a string span early — the char after `\` is data.
    func testEscapedQuoteDoesNotEndTheStringSpan() {
        XCTAssertEqual(
            writtenContent(#"{"arguments": {"content": "say(\"None\"); v = True;"}}"#),
            #"say("None"); v = True;"#
        )
    }

    /// A backslash that is ITSELF escaped does not escape the quote after it — the string
    /// really does end there. Getting this wrong desyncs the walker for the whole remainder.
    func testEscapedBackslashAtStringEndIsHandled() {
        // JSON `\\\\` is two escaped backslashes, so the decoded content ends with two.
        XCTAssertEqual(
            writtenContent(#"{"arguments": {"content": "path = \"C:\\\\"}}"#),
            #"path = "C:\\"#
        )
    }

    // MARK: - Failure behaviour

    /// An unbalanced quote leaves the walker inside a string. Skipping the repair for the
    /// tail degrades to "your JSON did not decode" — never to "we rewrote your file".
    func testUnbalancedQuoteSkipsRepairRatherThanCorrupting() {
        let broken = #"{"content": "he said "hi", "flag": True,}"#
        let out = repair(broken)
        XCTAssertTrue(out.contains("he said \"hi\""), "the string contents must survive verbatim")
    }

    func testEmptyAndStructurelessInputAreNoOps() {
        XCTAssertEqual(repair(""), "")
        XCTAssertEqual(repair("{}"), "{}")
        XCTAssertEqual(repair(#"{"a":"b"}"#), #"{"a":"b"}"#)
    }
}
