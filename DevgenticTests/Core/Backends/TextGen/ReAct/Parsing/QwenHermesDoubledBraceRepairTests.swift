// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2026 Raj Singh
//
//  QwenHermesDoubledBraceRepairTests.swift
//  DevgenticTests
//
//  Cover for the doubled-brace tool-call repair in `QwenHermesJsonParser` — defense in depth for
//  the corrupt-template output shape observed 2026-08-21 (Qwen2.5-3B-4bit's shipped template
//  teaches `{{"name": ...}}`; the model copies it; the strict decoder rejects it).
//
//  On MLX the render-side `ChatTemplateRepair` prevents the model emitting this at all, so these
//  tests are the ONLY exercise the repair path gets — if they go, the repair is unverified.
//
//  ⚠️ The quoted-span tests are the ones that keep this out of the content-corruption class
//  (transforms that rewrote payload bytes by shape-matching): a `{{` inside a string VALUE must
//  never trigger or be altered by the repair.
//

import XCTest
@testable import devgentic

final class QwenHermesDoubledBraceRepairTests: XCTestCase {

    private let parser = QwenHermesJsonParser()

    private func onlyCall(_ raw: String, file: StaticString = #filePath, line: UInt = #line) -> PendingToolCall? {
        let step = parser.parse(rawResponse: raw)
        XCTAssertEqual(step.toolCalls.count, 1, "expected exactly one tool call", file: file, line: line)
        return step.toolCalls.first
    }

    // MARK: - The observed corruption shapes (byte-for-byte from the venv reproduction)

    /// Shape 1: doubled open, object, orphaned `}}` on its own line, closed wrapper.
    func testRepairsDoubledBracesWithOrphanedCloser() {
        let raw = """
        <tool_call>
        {{"name": "execute_shell", "arguments": {"command": "/Users/alice/Desktop"}}
        }}
        </tool_call>
        """
        let call = onlyCall(raw)
        XCTAssertEqual(call?.name, "execute_shell")
        XCTAssertEqual(call?.arguments["command"], .string("/Users/alice/Desktop"))
    }

    /// Shape 2: doubled open, no orphaned closer — the whole body is one brace short of balance.
    func testRepairsDoubledOpenWithClosedWrapper() {
        let raw = """
        <tool_call>
        {{"name": "execute_shell", "arguments": {"command": "/Users/alice/Desktop/Acme"}}
        </tool_call>
        """
        let call = onlyCall(raw)
        XCTAssertEqual(call?.name, "execute_shell")
        XCTAssertEqual(call?.arguments["command"], .string("/Users/alice/Desktop/Acme"))
    }

    /// Shape 3: EOS truncation — no closing wrapper at all, and the body never balances, so the
    /// unclosed-wrapper scanner finds nothing and only the gated remainder hand-off reaches it.
    func testRepairsTruncatedDoubledBracesWithoutCloser() {
        let raw = "<tool_call>\n{{\"name\": \"execute_shell\", \"arguments\": {\"command\": \"ls /tmp\"}}"
        let call = onlyCall(raw)
        XCTAssertEqual(call?.name, "execute_shell")
        XCTAssertEqual(call?.arguments["command"], .string("ls /tmp"))
    }

    /// The alias tolerance must survive the repair path: `tool_name` + doubled braces together.
    func testRepairComposesWithKeyAliasing() {
        let raw = """
        <tool_call>
        {{"tool_name": "execute_shell", "arguments": {"command": "pwd"}}
        }}
        </tool_call>
        """
        XCTAssertEqual(onlyCall(raw)?.name, "execute_shell")
    }

    // MARK: - Quoted-span safety (the content-corruption guard)

    /// A `{{` inside a string VALUE of a WELL-FORMED call: the repair must not fire, and the
    /// value must come through byte-exact.
    func testWellFormedCallWithDoubledBracesInContentIsUntouched() {
        let sed = "sed 's/{{//' template.txt"
        let raw = "<tool_call>\n{\"name\": \"execute_shell\", \"arguments\": {\"command\": \"\(sed.replacingOccurrences(of: "\"", with: "\\\""))\"}}\n</tool_call>"
        let call = onlyCall(raw)
        XCTAssertEqual(call?.arguments["command"], .string(sed),
                       "content bytes must never be rewritten by a structural repair")
    }

    /// The hard case: the OUTER braces are doubled AND the string value contains braces of its
    /// own. The repair must fix the structure while carrying the value through byte-exact —
    /// this is what the string/escape-aware re-scan exists for.
    func testRepairPreservesBracesInsideStringValues() {
        let raw = """
        <tool_call>
        {{"name": "execute_shell", "arguments": {"command": "echo '{{a}} and }}'"}}
        }}
        </tool_call>
        """
        let call = onlyCall(raw)
        XCTAssertEqual(call?.name, "execute_shell")
        XCTAssertEqual(call?.arguments["command"], .string("echo '{{a}} and }}'"),
                       "quoted braces must not be counted by the balance scan nor stripped")
    }

    // MARK: - Non-invention guarantees

    /// A healthy single-brace call must parse identically to before the repair existed.
    func testHealthyCallUnaffected() {
        let raw = "<tool_call>\n{\"name\": \"ask_user\", \"arguments\": {\"question\": \"Which folder?\"}}\n</tool_call>"
        let call = onlyCall(raw)
        XCTAssertEqual(call?.name, "ask_user")
        XCTAssertEqual(call?.arguments["question"], .string("Which folder?"))
    }

    /// Doubled braces around garbage must still fail — the repair recovers structure, it must
    /// never invent a call that is not there.
    func testDoubledBracesAroundGarbageStillFails() {
        let raw = "<tool_call>\n{{this is not json at all}}\n</tool_call>"
        let step = parser.parse(rawResponse: raw)
        XCTAssertTrue(step.toolCalls.isEmpty, "the repair must not conjure a call from garbage")
    }
}
