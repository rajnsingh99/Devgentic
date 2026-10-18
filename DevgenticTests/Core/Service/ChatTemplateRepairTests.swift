// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
//
//  ChatTemplateRepairTests.swift
//  DevgenticTests
//
//  Created by Raj Singh.
//

import XCTest
@testable import devgentic

final class ChatTemplateRepairTests: XCTestCase {

    /// The corrupt segment exactly as it exists in the shipped artifact (Jinja-source bytes:
    /// `\n` and `\"` are the template's OWN escapes inside its string literal).
    private let corruptSegment =
        "<tool_call>\\n{{\\\"name\\\": <function-name>, \\\"arguments\\\": <args-json-object>}}\\n</tool_call>"

    /// The official Qwen segment (verified against the installed Qwen2.5-VL-3B copy).
    private let healthySegment =
        "<tool_call>\\n{\\\"name\\\": <function-name>, \\\"arguments\\\": <args-json-object>}\\n</tool_call>"

    private func template(around segment: String) -> String {
        // Realistic surroundings: the segment sits inside a Jinja output statement with live
        // expressions before and after, which the repair must leave untouched.
        "{%- if tools %}\n{{- \"XML tags:\\n\" }}\n{{- \"" + segment + "<|im_end|>\\n\" }}\n{%- endif %}\n{{- messages[0].content }}"
    }

    // MARK: - The repair

    func testRepairsTheShippedQwenCorruption() {
        let result = ChatTemplateRepair.repair(template(around: corruptSegment))
        XCTAssertEqual(result.applied.count, 1, "exactly the doubled-brace repair must fire")
        XCTAssertFalse(result.template.contains(corruptSegment), "corrupt bytes must be gone")
        XCTAssertTrue(result.template.contains(healthySegment), "official single-brace example must be present")
    }

    /// Jinja EXPRESSIONS also use `{{` — the repair must never touch them. Byte-identity is the
    /// assertion: everything outside the corrupt segment survives exactly.
    func testOnlyTheCorruptSegmentChanges() {
        let corrupt = template(around: corruptSegment)
        let repaired = ChatTemplateRepair.repair(corrupt).template
        XCTAssertEqual(repaired, template(around: healthySegment),
                       "the repair must be exactly corrupt→healthy — no other byte may move")
        XCTAssertTrue(repaired.contains("{{- messages[0].content }}"),
                      "live Jinja expressions must survive untouched")
    }

    // MARK: - Pass-through guarantees

    func testHealthyTemplatePassesThroughByteIdentical() {
        let healthy = template(around: healthySegment)
        let result = ChatTemplateRepair.repair(healthy)
        XCTAssertTrue(result.applied.isEmpty, "no repair may fire on the official template")
        XCTAssertEqual(result.template, healthy)
    }

    func testIdempotent() {
        let once = ChatTemplateRepair.repair(template(around: corruptSegment))
        let twice = ChatTemplateRepair.repair(once.template)
        XCTAssertTrue(twice.applied.isEmpty, "repairing repaired output must be a no-op")
        XCTAssertEqual(twice.template, once.template)
    }

    /// A template with no tool support at all (most models) must pass through untouched — this is
    /// the overwhelmingly common case and it must never pay more than a `contains` scan.
    func testUnrelatedTemplateUntouched() {
        let plain = "{%- for message in messages %}{{ message.content }}{%- endfor %}"
        let result = ChatTemplateRepair.repair(plain)
        XCTAssertTrue(result.applied.isEmpty)
        XCTAssertEqual(result.template, plain)
    }
}
