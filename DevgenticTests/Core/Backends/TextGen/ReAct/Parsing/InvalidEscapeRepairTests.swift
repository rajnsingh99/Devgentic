// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
//
//  InvalidEscapeRepairTests.swift
//  devgenticTests
//
//  An escape JSON does not define (`\'`, `\d`, `\u` without four hex digits) used to fail the
//  whole call. On the 2026-10-06 device run Qwen2.5-3B answered T3 correctly with
//  `Devgentic\'s` in the answer; the decode failed, both retries repeated it, and the run ended
//  on a wrong answer. Such an escape now keeps its backslash: nothing the model wrote is lost.
//

import XCTest
@testable import devgentic

final class InvalidEscapeRepairTests: XCTestCase {

    private func decoded(_ json: String) -> String? {
        let repaired = JSONStructuralSanitizer.keepingInvalidEscapesLiteral(json)
        guard let object = try? JSONSerialization.jsonObject(with: Data(repaired.utf8)) as? [String: Any] else { return nil }
        return object["a"] as? String
    }

    // MARK: - The repair

    /// Valid JSON is never touched, including the escapes an invalid one looks like.
    func testValidDocumentsAreUnchanged() {
        let valid = [
            #"{"a": "it's"}"#,
            #"{"a": "a \\' b"}"#,                 // an escaped backslash, then an apostrophe
            #"{"a": "say \"hi\"", "b": "\/ \b \f \n \r \t"}"#,
            #"{"a": "caf\u00e9 \u00E9"}"#,
            #"{"a": "C:\\users\\new"}"#,
            #"{"a": "ends with a backslash \\"}"#,
            #"{"a": "x"} trailing \ outside a string"#,
        ]
        for json in valid {
            XCTAssertEqual(JSONStructuralSanitizer.keepingInvalidEscapesLiteral(json), json)
        }
    }

    func testAnInvalidEscapeDecodesAsTheCharactersTheModelWrote() {
        XCTAssertEqual(decoded(#"{"a": "Devgentic\'s"}"#), #"Devgentic\'s"#)
        XCTAssertEqual(decoded(#"{"a": "\d+\s*"}"#), #"\d+\s*"#)
        XCTAssertEqual(decoded(#"{"a": "C:\users"}"#), #"C:\users"#, #"\u without four hex digits is a path"#)
        XCTAssertEqual(decoded(#"{"a": "\u12"}"#), #"\u12"#)
        XCTAssertEqual(decoded(#"{"a": "it\'s \"quoted\" and \\ kept"}"#), #"it\'s "quoted" and \ kept"#)
    }

    /// Code keeps its backslash: in Python source `\'` IS a backslash and a quote.
    func testFileContentKeepsItsBackslash() {
        XCTAssertEqual(decoded(#"{"a": "print('don\'t')"}"#), #"print('don\'t')"#)
        XCTAssertEqual(decoded(#"{"a": "echo 'it'\''s'"}"#), #"echo 'it'\''s'"#)
    }

    // MARK: - The wiring: every dialect parser goes through `repairingStructure`

    private let tools: [AgentTool] = [
        AgentTool(
            name: "final_answer", description: "Finish.",
            parameters: SchemaBuilder.object(properties: [("answer", "string", "The answer.")], required: ["answer"]),
            requiresConfirmation: false, textOnlyRun: { _ in "" }),
        TestToolFactory.make(name: "read_file"),
    ]

    private func parse(_ raw: String) -> ModernCognitiveStep {
        CognitiveParsePipeline(expectedDialect: .qwenHermesToolCall, registeredTools: tools).parse(raw: raw)
    }

    /// The T3 reply, byte for byte as the framework rejected it.
    func testTheT3AnswerIsNoLongerLost() {
        let raw = "<tool_call>\n{\"name\": \"final_answer\", \"arguments\": {\"answer\": \"# Testbed\\nA tiny utilities project used to test Devgentic\\'s local models.\\n\\nCodename: BLUEFIN-42\"}}\n</tool_call>"
        let step = parse(raw)
        guard case .success = step.parseOutcome else { return XCTFail("\(step.parseOutcome)") }
        XCTAssertEqual(step.toolCalls.map(\.name), ["final_answer"])
        guard case .string(let answer)? = step.toolCalls.first?.arguments["answer"] else {
            return XCTFail("no answer argument: \(String(describing: step.toolCalls.first?.arguments))")
        }
        XCTAssertTrue(answer.contains("Codename: BLUEFIN-42"), answer)
    }

    func testAnEditArgumentReachesTheToolIntact() {
        let raw = #"<tool_call>{"name": "read_file", "arguments": {"input": "src\dsa\print('don\'t').py"}}</tool_call>"#
        let step = parse(raw)
        guard case .success = step.parseOutcome else { return XCTFail("\(step.parseOutcome)") }
        XCTAssertEqual(step.toolCalls.first?.arguments["input"], .string(#"src\dsa\print('don\'t').py"#))
    }
}
