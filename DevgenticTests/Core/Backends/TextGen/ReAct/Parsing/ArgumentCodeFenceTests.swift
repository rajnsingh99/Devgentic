// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
//
//  ArgumentCodeFenceTests.swift
//  devgenticTests
//
//  Readiness CR-3: a tool call's ARGUMENTS keep the code fences the model wrote.
//
//  ⚠️ THE DEFECT. `OutputSanitizer.sanitize` strips every ``` from the WHOLE reply before any parser
//  reads it, so argument VALUES lost their fences too: a README written via `write_file` reached disk
//  without its code blocks, an `edit_code_single.old_string` containing ``` could never match the
//  file, and a ReAct `final_answer` lost its code. `AnswerCodeFenceTests` covers plain answers; this
//  covers arguments. The 6th member of the content-corruption class (see `CodeFenceShield`): a transform that rewrote CONTENT
//  because of what it looked like.
//

import XCTest
@testable import devgentic

final class ArgumentCodeFenceTests: XCTestCase {

    /// Real argument names — `TestToolFactory.make` gives every tool one required `input`, which would
    /// fail these calls on schema validation before a fence ever mattered.
    private let tools: [AgentTool] = [
        ("final_answer", [("answer", "string", "The answer.")], ["answer"]),
        ("read_file", [("path", "string", "File path.")], ["path"]),
        ("write_file", [("path", "string", "File path."), ("content", "string", "File content.")], ["path", "content"]),
        ("ask_user", [("question", "string", "Question.")], ["question"]),
    ].map { name, properties, required in
        AgentTool(name: name, description: "\(name) test tool",
                  parameters: SchemaBuilder.object(properties: properties, required: required),
                  requiresConfirmation: false, run: { _ in ("ok", []) })
    }

    private func parse(_ text: String, _ dialect: ModelDialect) -> ModernCognitiveStep {
        CognitiveParsePipeline(expectedDialect: dialect, registeredTools: tools).parse(raw: text)
    }

    private func string(_ step: ModernCognitiveStep, _ tool: String, _ key: String) -> String? {
        guard let call = step.toolCalls.first(where: { $0.name == tool }),
              case .string(let value)? = call.arguments[key] else { return nil }
        return value
    }

    // `\\n` below is a JSON escape the model wrote, i.e. a backslash and an `n` in the raw text.
    private let readme = #"# App\n\n```swift\nlet x = 1\n```\n"#

    func testAHermesWriteFileKeepsTheFencesInItsContent() throws {
        let raw = "Writing it.\n<tool_call>\n{\"name\": \"write_file\", \"arguments\": {\"path\": \"README.md\", \"content\": \"\(readme)\"}}\n</tool_call>"
        let step = parse(raw, .qwenHermesToolCall)
        let content = try XCTUnwrap(string(step, "write_file", "content"), "\(step.parseOutcome) \(step.toolCalls)")
        XCTAssertTrue(content.contains("```swift\nlet x = 1\n```"), "fences stripped from the file content: \(content)")
    }

    func testAReActFinalAnswerKeepsTheFencesInItsAnswer() throws {
        let raw = "Thought: I can answer.\nAction: final_answer\nAction Input: {\"answer\": \"Use:\\n```swift\\nlet x = 1\\n```\"}"
        let step = parse(raw, .reactMarkdown)
        let answer = try XCTUnwrap(string(step, "final_answer", "answer"), "\(step.parseOutcome) \(step.toolCalls)")
        XCTAssertTrue(answer.contains("```swift"), "fences stripped from the answer: \(answer)")
    }

    func testANativeJSONCallKeepsTheFencesInItsArguments() throws {
        let raw = "{\"name\": \"write_file\", \"arguments\": {\"path\": \"README.md\", \"content\": \"\(readme)\"}}"
        let step = parse(raw, .nativeJSON)
        let content = try XCTUnwrap(string(step, "write_file", "content"), "\(step.parseOutcome) \(step.toolCalls)")
        XCTAssertTrue(content.contains("```swift"), "fences stripped: \(content)")
    }

    // MARK: - What stripping is still for

    /// The control: a call the model WRAPPED in a fence still parses, and its arguments carry no
    /// fence — the wrapper was never part of any value.
    func testAFenceWrappedCallStillParses() throws {
        for dialect: ModelDialect in [.nativeJSON, .heuristicJson, .qwenHermesToolCall] {
            let raw = "```json\n{\"name\": \"read_file\", \"arguments\": {\"path\": \"a.swift\"}}\n```"
            let step = parse(raw, dialect)
            XCTAssertEqual(step.toolCalls.map(\.name), ["read_file"], "\(dialect.rawValue): \(step.parseOutcome)")
            XCTAssertEqual(string(step, "read_file", "path"), "a.swift", dialect.rawValue)
        }
    }

    /// Both at once: a wrapped call whose content itself holds a fenced block keeps the INNER fence.
    func testAFenceWrappedCallKeepsTheFencesInsideItsValues() throws {
        let raw = "```json\n{\"name\": \"write_file\", \"arguments\": {\"path\": \"README.md\", \"content\": \"\(readme)\"}}\n```"
        let step = parse(raw, .nativeJSON)
        let content = try XCTUnwrap(string(step, "write_file", "content"), "\(step.parseOutcome) \(step.toolCalls)")
        XCTAssertTrue(content.contains("```swift"), "inner fence stripped: \(content)")
    }

    /// A reply with no fences is parsed exactly once and is untouched.
    func testAFenceFreeCallIsUnchanged() {
        let raw = "<tool_call>\n{\"name\": \"read_file\", \"arguments\": {\"path\": \"a.swift\"}}\n</tool_call>"
        let step = parse(raw, .qwenHermesToolCall)
        XCTAssertEqual(step.toolCalls.map(\.name), ["read_file"])
        XCTAssertEqual(string(step, "read_file", "path"), "a.swift")
    }

    // MARK: - The placeholder never leaks

    /// A call that FAILS to parse is re-parsed unshielded, so the corrective message the model gets
    /// quotes its own reply — never private-use placeholder characters.
    func testAFailedParseNeverCarriesThePlaceholder() {
        let raw = "<tool_call>\n{\"name\": \"write_file\", \"arguments\": {\"path\": \"a.md\", \"content\": \"```x``` \"}, }\n</tool_call>"
        let step = parse(raw, .qwenHermesToolCall)
        XCTAssertFalse(String(describing: step).contains(CodeFenceShield.placeholder), "\(step)")
    }

    /// A plain ANSWER explaining JSON keeps the fence inside its example string as well.
    func testAnAnswerWithAFenceInsideAJSONExampleKeepsIt() {
        let raw = "Escape it like this:\n\n```json\n{\"doc\": \"use ``` for code\"}\n```"
        let step = parse(raw, .qwenHermesToolCall)
        guard case .genuineCompletion = step.parseOutcome else { return XCTFail("\(step.parseOutcome)") }
        XCTAssertTrue(step.reasoning.contains("\"use ``` for code\""), step.reasoning)
        XCTAssertTrue(step.reasoning.hasPrefix("Escape it like this:\n\n```json"), step.reasoning)
        XCTAssertFalse(step.reasoning.contains(CodeFenceShield.placeholder))
    }
}

/// The shield's own rule: ``` inside a JSON string literal, and nowhere else.
final class CodeFenceShieldTests: XCTestCase {

    func testOnlyFencesInsideStringLiteralsAreShielded() {
        let text = "```json\n{\"a\": \"x ``` y\", \"b\": 1}\n```"
        let shielded = CodeFenceShield.shield(text)
        XCTAssertEqual(shielded.count, 1)
        XCTAssertTrue(shielded.text.hasPrefix("```json"), "a wrapper fence is outside every literal")
        XCTAssertTrue(shielded.text.hasSuffix("```"))
        XCTAssertEqual(CodeFenceShield.unshield(shielded.text), text, "round trip is exact")
    }

    /// An escaped quote does not end the literal, so the fence after it is still inside.
    func testAnEscapedQuoteDoesNotEndTheLiteral() {
        let text = #"{"a": "say "hi" then ``` done"}"#
        XCTAssertEqual(CodeFenceShield.shield(text).count, 1)
    }

    /// Prose and unbalanced braces are left exactly as they are.
    func testProseAndUnbalancedObjectsAreUntouched() {
        for text in ["Use ``` around code, \"like ``` this\".", "{\"a\": \"``` never closed", "no fences {\"a\": 1}"] {
            let shielded = CodeFenceShield.shield(text)
            XCTAssertEqual(shielded.count, 0, text)
            XCTAssertEqual(shielded.text, text)
        }
    }

    /// Several objects in one reply are each shielded.
    func testEveryObjectInTheReplyIsShielded() {
        let text = #"{"a": "```"} and {"b": "``` ```"}"#
        XCTAssertEqual(CodeFenceShield.shield(text).count, 3)
    }
}
