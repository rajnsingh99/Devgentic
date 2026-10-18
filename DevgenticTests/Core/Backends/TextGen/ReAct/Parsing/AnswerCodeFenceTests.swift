// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
//
//  AnswerCodeFenceTests.swift
//  DevgenticTests
//
//  Created by Raj Singh.
//

import XCTest
@testable import devgentic

final class AnswerCodeFenceTests: XCTestCase {

    private let tools = ["final_answer", "read_file", "ask_user"].map { TestToolFactory.make(name: $0) }

    private func parse(_ text: String, _ dialect: ModelDialect) -> ModernCognitiveStep {
        CognitiveParsePipeline(expectedDialect: dialect, registeredTools: tools).parse(raw: text)
    }

    private let t2Answer = "Here is a JSON example of a user:\n\n```json\n{\n  \"name\": \"John Doe\",\n  \"email\": \"john@example.com\",\n  \"roles\": [\"admin\", \"editor\", \"viewer\"]\n}\n```\n\nAnd the Swift array literal:\n\n```swift\n[7, 1, 5]\n```"

    private let prose = "The loop starts at index 1:\n\n```java\nfor (int i = 1; i < n; i++) {\n    best = Math.max(best, prices[i] - low);\n}\n```\n\nIt runs in O(n)."

    func testAPlainAnswerKeepsItsCodeBlocksOnEveryDialect() {
        var wrong: [String] = []
        for dialect in ModelDialect.allCases {
            for (label, text, fences) in [("t2", t2Answer, ["```json", "```swift"]), ("java", prose, ["```java"])] {
                let step = parse(text, dialect)
                guard case .genuineCompletion = step.parseOutcome else {
                    wrong.append("\(dialect.rawValue) × \(label): not an answer (\(step.parseOutcome))"); continue
                }
                for fence in fences where !step.reasoning.contains(fence) {
                    wrong.append("\(dialect.rawValue) × \(label): lost \(fence) → \(step.reasoning)")
                }
            }
        }
        XCTAssertTrue(wrong.isEmpty, "code blocks stripped from answers:\n" + wrong.joined(separator: "\n"))
    }

    /// The fence stripper knows five language names; for any other it removed the backticks and
    /// left the name as a stray line of the answer.
    func testNoStrayLanguageLineIsLeftBehind() {
        let step = parse(prose, .qwenHermesToolCall)
        XCTAssertFalse(step.reasoning.contains("\njava\n") || step.reasoning.hasPrefix("java\n"), step.reasoning)
    }

    /// A parser that returns only PART of the reply as the answer keeps its own text: the whole
    /// reply would leak the scaffolding around the answer.
    func testAPartialAnswerKeepsTheParsersText() {
        let react = "Thought: I can answer directly.\nFinal Answer: Use this:\n```python\nprint(1)\n```"
        let step = parse(react, .reactMarkdown)
        XCTAssertFalse(step.reasoning.contains("Thought:"), "the scaffolding leaked into the answer: \(step.reasoning)")
    }

    /// Only final answers change. A call keeps everything it had.
    func testCallsAreUntouched() {
        let call = "Reading it.\n<tool_call>\n{\"name\": \"read_file\", \"arguments\": {\"input\": \"a.java\"}}\n</tool_call>"
        let step = parse(call, .qwenHermesToolCall)
        XCTAssertEqual(step.toolCalls.map(\.name), ["read_file"])
        guard case .success = step.parseOutcome else { return XCTFail("\(step.parseOutcome)") }
    }

    /// The parse itself still reads fence-free text: an answer whose only content is a code block
    /// is still an answer, not a call.
    func testAnAnswerThatIsOnlyACodeBlockIsStillAnAnswerWithItsFence() {
        let step = parse("```swift\nlet x = [7, 1, 5]\n```", .qwenHermesToolCall)
        guard case .genuineCompletion = step.parseOutcome else { return XCTFail("\(step.parseOutcome)") }
        XCTAssertTrue(step.reasoning.hasPrefix("```swift"), step.reasoning)
    }
}
