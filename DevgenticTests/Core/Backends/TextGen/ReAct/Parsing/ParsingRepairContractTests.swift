// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
//
//  ParsingRepairContractTests.swift
//  DevgenticTests
//
//  Created by Raj Singh.
//

import XCTest
@testable import devgentic

final class ParsingRepairContractTests: XCTestCase {

    private func tool(_ name: String, _ properties: [(String, String, String)], required: [String]) -> AgentTool {
        AgentTool(name: name, description: "\(name) tool",
                  parameters: SchemaBuilder.object(properties: properties, required: required),
                  requiresConfirmation: false, run: { _ in ("ok", []) })
    }

    private lazy var tools: [AgentTool] = [
        tool("final_answer", [("answer", "string", "The answer.")], required: ["answer"]),
        tool("write_file", [("path", "string", "Path."), ("content", "string", "Content.")], required: ["path", "content"]),
        tool("read_lines", [("path", "string", "Path."), ("count", "integer", "Lines.")], required: ["path", "count"]),
        tool("git_status", [], required: []),
        tool("forget", [("key", "string", "Key.")], required: ["key"]),
        tool("git", [("action", "string", "Action.")], required: ["action"]),
    ]

    private func parse(_ raw: String, _ dialect: ModelDialect) -> ModernCognitiveStep {
        CognitiveParsePipeline(expectedDialect: dialect, registeredTools: tools).parse(raw: raw)
    }

    private func string(_ step: ModernCognitiveStep, _ tool: String, _ key: String) -> String? {
        guard case .string(let v)? = step.toolCalls.first(where: { $0.name == tool })?.arguments[key] else { return nil }
        return v
    }

    // MARK: - CR-19: repair first, and never a call with empty arguments

    /// ⚠️⚠️ THE CR-19 TRIGGER: a multi-line answer written with RAW line breaks inside the JSON string.
    func testAReActMultiLineFinalAnswerDecodes() {
        let raw = "Thought: done.\nAction: final_answer\nAction Input: {\"answer\": \"Line one\nLine two\"}"
        XCTAssertEqual(string(parse(raw, .reactMarkdown), "final_answer", "answer"), "Line one\nLine two")
    }

    func testAReActInvalidEscapeDecodesKeepingTheBackslash() {
        let raw = #"Action: final_answer"# + "\n" + #"Action Input: {"answer": "Devgentic\'s models"}"#
        XCTAssertEqual(string(parse(raw, .reactMarkdown), "final_answer", "answer"), #"Devgentic\'s models"#)
    }

    /// Arguments that are present but unrecoverable are a TYPED malformed-JSON failure — not a call.
    func testUnrecoverableReActArgumentsAreAMalformedJSONFailureNotAnEmptyCall() {
        // Both shapes: not object-shaped at all, and object-shaped but still invalid after repair.
        // ⚠️ The second one matters — an earlier draft only had the first, which fails on a different
        // line, so a mutant restoring the `?? [:]` fallback went uncaught.
        for input in ["answer = maybe later", #"{"answer": "x", "extra": }"#] {
            let step = ReActMarkdownParser().parse(rawResponse: "Action: final_answer\nAction Input: \(input)")
            XCTAssertTrue(step.toolCalls.isEmpty, "a call with [:] was sent for \(input): \(step.toolCalls)")
            guard case .failed(.malformedJSON) = step.parseOutcome else { return XCTFail("\(input): \(step.parseOutcome)") }
        }
    }

    /// The control: no Action Input at all is a legitimate zero-argument call.
    func testAZeroArgumentReActCallStillWorks() {
        let step = ReActMarkdownParser().parse(rawResponse: "Thought: check.\nAction: git_status")
        XCTAssertEqual(step.toolCalls.map(\.name), ["git_status"])
        XCTAssertEqual(step.toolCalls.first?.arguments, [:])
    }

    /// The shared repair, and that it never alters a valid document.
    func testRawControlCharactersAreEscapedOnlyInsideStrings() {
        XCTAssertEqual(JSONStructuralSanitizer.decodeObject("{\"a\": \"x\ny\t\"}"), ["a": .string("x\ny\t")])
        let valid = "{\n  \"a\": \"x\\ny\"\n}"
        XCTAssertEqual(JSONStructuralSanitizer.escapingRawControlCharacters(valid), valid,
                       "a newline BETWEEN tokens is whitespace, not a string value")
    }

    func testMistralXMLUsesTheSharedRepair() throws {
        let source = try Self.read("Devgentic/Core/Backends/TextGen/ReAct/Parsing/MistralXMLParser.swift")
        XCTAssertTrue(source.contains("JSONStructuralSanitizer.decodeObject(cleanArgs)"))
    }

    // MARK: - CR-20: a tool name in prose is not a broken call

    /// ⚠️⚠️ THE CR-20 MISCLASSIFICATION.
    func testOrdinaryWordsAreNotToolCalls() {
        XCTAssertFalse(CognitiveParsePipeline.mentionsAsACall("did you forget the extension?", name: "forget"))
        XCTAssertFalse(CognitiveParsePipeline.mentionsAsACall("it has 7 digits.", name: "git"))
        XCTAssertFalse(CognitiveParsePipeline.mentionsAsACall("run git status to see.", name: "git"))
    }

    /// The controls: call-shaped emissions are still caught.
    func testCallShapedMentionsAreStillCaught() {
        XCTAssertTrue(CognitiveParsePipeline.mentionsAsACall(#"codebase_map path: "/x""#, name: "codebase_map"))
        XCTAssertTrue(CognitiveParsePipeline.mentionsAsACall(#"forget(key: "a")"#, name: "forget"))
        XCTAssertTrue(CognitiveParsePipeline.mentionsAsACall("git: status", name: "git"))
    }

    /// Through the pipeline: a short prose answer is an ANSWER, not a retried format failure.
    func testAShortProseAnswerMentioningAToolWordIsAnAnswer() {
        for dialect: ModelDialect in [.qwenHermesToolCall, .reactMarkdown, .mistralXML] {
            let step = parse("I couldn't find it — did you forget the extension?", dialect)
            guard case .genuineCompletion = step.parseOutcome else {
                return XCTFail("\(dialect.rawValue): \(step.parseOutcome)")
            }
        }
    }

    // MARK: - CR-21: Qwen3-Coder values are typed by the schema

    private func qwen3(_ params: String, function: String) -> String {
        "<tool_call>\n<function=\(function)>\n\(params)\n</function>\n</tool_call>"
    }

    /// ⚠️⚠️ THE CR-21 DEFECT: JSON file content became an object, so `write_file` failed every time.
    func testJSONFileContentStaysText() {
        let raw = qwen3("<parameter=path>\napp.json\n</parameter>\n<parameter=content>\n{\"name\":\"app\",\"version\":\"1.10\"}\n\n</parameter>",
                        function: "write_file")
        let step = parse(raw, .qwen3CoderDeepXml)
        XCTAssertEqual(string(step, "write_file", "content"), "{\"name\":\"app\",\"version\":\"1.10\"}\n",
                       "content must be the text the model wrote, its own trailing newline included")
        XCTAssertEqual(string(step, "write_file", "path"), "app.json")
    }

    /// The schema still types what it declares: an integer parameter becomes a number.
    func testADeclaredIntegerIsStillANumber() {
        let raw = qwen3("<parameter=path>\na.txt\n</parameter>\n<parameter=count>\n5\n</parameter>", function: "read_lines")
        XCTAssertEqual(parse(raw, .qwen3CoderDeepXml).toolCalls.first?.arguments["count"], .number(5))
    }

    /// The coercion rule on its own: only what the schema declares, only when the text really is it.
    func testSchemaCoercionOnlyTypesWhatTheSchemaDeclares() {
        let schema = SchemaBuilder.object(properties: [("n", "integer", ""), ("flag", "boolean", ""), ("s", "string", "")],
                                          required: [])
        let out = CognitiveParsePipeline.coercingToSchema(
            ["n": .string(" 7 "), "flag": .string("maybe"), "s": .string("42")], schema: schema)
        XCTAssertEqual(out["n"], .number(7))
        XCTAssertEqual(out["flag"], .string("maybe"), "not a boolean — left for the tool to report precisely")
        XCTAssertEqual(out["s"], .string("42"), "a string parameter is never retyped")
    }

    // MARK: - CR-22: unknown escapes keep their backslash

    func testThePythonicParserKeepsAnUnknownEscapesBackslash() {
        let step = PythonicListParser().parse(rawResponse: #"[grep_files(pattern='\d+\.\d+')]"#)
        guard case .string(let pattern)? = step.toolCalls.first?.arguments["pattern"] else {
            return XCTFail("\(step.toolCalls)")
        }
        XCTAssertEqual(pattern, #"\d+\.\d+"#)
    }

    private static func read(_ relativePath: String) throws -> String {
        var dir = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        for _ in 0..<10 {
            let candidate = dir.appendingPathComponent(relativePath)
            if FileManager.default.fileExists(atPath: candidate.path) { return try String(contentsOf: candidate, encoding: .utf8) }
            dir = dir.deletingLastPathComponent()
        }
        throw XCTSkip("Could not locate \(relativePath)")
    }
}
