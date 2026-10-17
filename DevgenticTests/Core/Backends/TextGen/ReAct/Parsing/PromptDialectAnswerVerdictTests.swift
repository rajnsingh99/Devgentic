// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
//
//  PromptDialectAnswerVerdictTests.swift
//  DevgenticTests
//
//  Invariant (prompt-based dialects, i.e. CognitiveParsePipeline WITH a registry):
//  a reply in which recovery finds no call, and which declares no attempted call,
//  is the final answer — on every dialect. Brackets decide nothing.
//
//  Probe 2026-10-05: before the fix, 12 of 18 dialects rejected each answer below.
//

import XCTest
@testable import devgentic

final class PromptDialectAnswerVerdictTests: XCTestCase {

    private let tools = ["final_answer", "read_file", "ask_user"].map { TestToolFactory.make(name: $0) }

    /// Verbatim shapes of real answers that were rejected.
    private let answers: [(label: String, text: String)] = [
        ("javaArray", "I added `maxProfit`. With the sample array `{7, 1, 5, 3, 6, 4}` it returns 7."),
        ("intBrackets", "Added `public static int maxProfit(int[] prices)` to January2026.java. It runs in O(n)."),
        ("listIndex", "The loop compares prices[i] with prices[i - 1] and adds the gain."),
        ("markdownLink", "See [January2026.java](src/dsa/jan26/January2026.java) for the change."),
        ("jsonAnalysis", "Summary below.\n\n```json\n{\n  \"analysis\": {\"expected_output\": 7, \"input\": [7,1,5]}\n}\n```"),
        // Bug 3 (2026-10-06): a JSON record with a `name` key was lifted out as a call to a tool
        // named after the person — or named "" — and the correct answer retried.
        ("t2JohnDoe", "Here is a JSON example of a user:\n\n```json\n{\n  \"name\": \"John Doe\",\n  \"email\": \"john@example.com\",\n  \"roles\": [\"admin\", \"editor\", \"viewer\"]\n}\n```\n\nAnd the Swift array literal:\n\n```swift\n[7, 1, 5]\n```"),
        ("t2EmptyName", "To create a JSON example of a user with name, email, and roles without using tools:\n\n```json\n{\n  \"name\": \"\",\n  \"email\": \"\",\n  \"roles\": [\"user\"]\n}\n```\n\nFor the Swift array literal of numbers 7, 1 and 5:\n\n```swift\n[7, 1, 5]\n```\n\nIs this what you need?"),
        ("bareUserRecord", #"{"name": "Alice", "email": "alice@example.com", "roles": ["a", "b", "c"]}"#),
    ]

    private func parse(_ text: String, _ dialect: ModelDialect, tools: [AgentTool]? = nil) -> ModernCognitiveStep {
        CognitiveParsePipeline(expectedDialect: dialect, registeredTools: tools ?? self.tools).parse(raw: text)
    }

    private func outcomeLabel(_ step: ModernCognitiveStep) -> String {
        switch step.parseOutcome {
        case .genuineCompletion: return "answer"
        case .success: return "call(\(step.toolCalls.map(\.name).joined(separator: ",")))"
        case .failed(let reason): return "FAILED(\(reason.uiChipLabel))"
        }
    }

    // MARK: - Answers are answers, on every dialect

    func testBracketedAnswersAreFinalAnswersOnEveryDialect() {
        var wrong: [String] = []
        for dialect in ModelDialect.allCases {
            for (label, text) in answers {
                // The Pythonic dialect reads `maxProfit(int[] prices)` as a call to an unknown
                // tool. It used to be excluded here as a tool-NAME failure; since bug 3 a call
                // recovered from text to an unknown name, in a reply that declares no call, is
                // the answer on every path — so it is no longer an exception.
                let step = parse(text, dialect)
                if case .genuineCompletion = step.parseOutcome { continue }
                wrong.append("\(dialect.rawValue) × \(label) → \(outcomeLabel(step))")
            }
        }
        XCTAssertTrue(wrong.isEmpty, "answers rejected:\n" + wrong.joined(separator: "\n"))
    }

    func testTheAnswerTextIsKept() {
        let step = parse(answers[0].text, .llama3JsonSingle)
        XCTAssertTrue(step.reasoning.contains("{7, 1, 5, 3, 6, 4}"), step.reasoning)
    }

    // MARK: - Bug 3: a JSON record in an answer is not a call to an unknown tool

    /// Every path, the native (Ollama content fallback) one included, and the WHOLE reply is the
    /// answer: the text after the JSON block too. On the native path the step's text used to be
    /// only the prose before the first brace.
    func testJSONRecordsInAnswersAreAnswersOnEveryPath() {
        let records = answers.filter { ["t2JohnDoe", "t2EmptyName", "bareUserRecord"].contains($0.label) }
        XCTAssertEqual(records.count, 3, "fixture labels drifted — the test would pass vacuously")
        var wrong: [String] = []
        for (label, text) in records {
            for (path, step) in allPaths(text) where !isAnswer(step) {
                wrong.append("\(path) × \(label) → \(outcomeLabel(step))")
            }
        }
        XCTAssertTrue(wrong.isEmpty, "answers rejected:\n" + wrong.joined(separator: "\n"))

        let johnDoe = answers.first { $0.label == "t2JohnDoe" }!.text
        for (path, step) in allPaths(johnDoe) {
            for kept in ["john@example.com", "[7, 1, 5]"] {
                XCTAssertTrue(step.reasoning.contains(kept), "\(path): the answer lost '\(kept)': \(step.reasoning)")
            }
        }
    }

    /// The other side, on every path: a made-up tool written as a call is still corrected.
    func testCallsToMadeUpToolsAreStillCorrectedOnEveryPath() {
        let calls: [(String, String)] = [
            ("bareWithArguments", #"{"name": "open_file", "arguments": {"path": "a.java"}}"#),
            ("hermesTags", "<tool_call>\n{\"name\": \"open_file\", \"arguments\": {\"path\": \"a.java\"}}\n</tool_call>"),
            ("llamaParameters", #"{"name": "open_file", "parameters": {"path": "a.java"}}"#),
            ("llamaNoParameters", #"{"name": "get_time", "parameters": {}}"#),
        ]
        var accepted: [String] = []
        for (label, text) in calls {
            for variant in [text, leadIn + text] {
                for (path, step) in allPaths(variant) where isAnswer(step) {
                    accepted.append("\(path) × \(label)")
                }
            }
        }
        XCTAssertTrue(accepted.isEmpty, "calls to made-up tools shown as the answer:\n" + accepted.joined(separator: "\n"))
    }

    /// A structured call (Ollama `tool_calls`, cloud) to an unknown tool is a real hallucination:
    /// only calls recovered from TEXT get the answer verdict.
    func testAStructuredCallToAnUnknownToolIsStillCorrected() {
        let structured = ModernCognitiveStep(
            reasoning: "",
            toolCalls: [PendingToolCall(id: "1", name: "John Doe", arguments: [:])])
        guard case .failed(.unknownToolName) = NativeParsePipeline(registeredTools: tools).validate(step: structured).parseOutcome else {
            return XCTFail("a structured call to an unknown tool must keep its correction")
        }
    }

    /// ⚠️ THE ACCEPTED TRADE-OFF (owner decision 2026-10-06), pinned so it is never a surprise: a
    /// bare call to a made-up tool with NO arguments object and no call-format token declares
    /// nothing the grammar can see, exactly like `{"name": "Raj"}`, so it is the answer.
    func testABareArgumentLessCallToAMadeUpToolIsTheAnswer() {
        for (path, step) in allPaths(#"{"name": "open_file"}"#) {
            XCTAssertTrue(isAnswer(step), "\(path) → \(outcomeLabel(step))")
        }
    }

    // MARK: - Calls are still calls

    /// The regression `testWrongSchemaKey_FunctionName_YieldsFailed` guards — but WITH a
    /// registry, where the new verdict applies. A hallucinated tool behind a wrong key is a call.
    func testWrongSchemaKeyCallIsStillRetried_WithARegistry() {
        let text = #"{"function_name": "final_summary", "arguments": {"summary": "Project analysis complete."}}"#
        for dialect: ModelDialect in [.nativeJSON, .heuristicJson, .llama3JsonSingle, .qwenHermesToolCall] {
            let step = parse(text, dialect)
            guard case .failed = step.parseOutcome else {
                XCTFail("\(dialect.rawValue): a wrong-schema call was accepted as the answer → \(outcomeLabel(step))"); continue
            }
        }
    }

    func testAnUndecodableCallToARegisteredToolIsStillRetried() {
        let step = parse(#"{"name":"read_file","arguments":{"input": a.java}}"#, .llama3JsonSingle)
        guard case .failed = step.parseOutcome else { return XCTFail(outcomeLabel(step)) }
    }

    func testAValidCallIsStillRecovered() {
        let step = parse(#"{"name":"read_file","parameters":{"input":"a.java"}}"#, .llama3JsonSingle)
        XCTAssertEqual(step.toolCalls.map(\.name), ["read_file"])
    }

    // MARK: - Deliberately unchanged

    /// No registry = a provider-level parse; `NativeParsePipeline` decides that one.
    func testWithoutARegistryTheVerdictIsLeftToTheLayerAbove() {
        let step = parse(answers[0].text, .nativeJSON, tools: [])
        guard case .failed = step.parseOutcome else {
            return XCTFail("the provider-level cascade must stay provisional: \(outcomeLabel(step))")
        }
    }

    /// `.toolNameInProse` (short prose naming a tool) keeps its deliberate meaning.
    func testShortProseNamingAToolIsUnchanged() {
        let step = parse("I used read_file on January2026.java; maxProfit returns 7.", .llama3JsonSingle)
        guard case .failed(.toolNameInProse) = step.parseOutcome else {
            return XCTFail("expected toolNameInProse, got \(outcomeLabel(step))")
        }
    }

    // MARK: - Grammar

    func testGrammarRule2_CallShapeWithAnyName() {
        XCTAssertEqual(AttemptedToolCallGrammar.attemptedCallName(
            in: #"{"function_name": "final_summary", "arguments": {"#, callableNames: []), "final_summary")
        XCTAssertEqual(AttemptedToolCallGrammar.attemptedCallName(
            in: #"{"action": "search", "action_input": {"q": "x"}}"#, callableNames: []), "search")
    }

    func testGrammarDataIsNotACall() {
        for text in [#"{"name": "Raj", "input": 5}"#, #"{"analysis": {"input": [7,1,5]}}"#, #"{"name": "Raj"}"#,
                     "Render it with `<span>{count}</span>` in the component.",
                     "Action: none needed.\nThe code already handles empty arrays [] correctly."] {
            XCTAssertNil(AttemptedToolCallGrammar.attemptedCallName(in: text, callableNames: ["read_file"]), text)
        }
        for (label, text) in answers {
            XCTAssertNil(AttemptedToolCallGrammar.attemptedCallName(in: text, callableNames: ["read_file"]), label)
        }
    }

    // MARK: - Calls in tag/token formats (2026-10-05 audit)

    /// Broken calls in every format the app reads. Each was found in the audit's probe matrix.
    private let brokenCalls: [(label: String, text: String)] = [
        ("pythonTag", #"<|python_tag|>read_file.call(path="a.java""#),
        ("deepXml", "<function=read_file>\n<parameter=path>\na.java\n"),
        ("hermesWrongInner", "<tool_call>\nread_file(path=\"a.java\")\n</tool_call>"),
        ("hermesCutOff", "<tool_call>\n{\"name\": \"read_file\", \"arguments\": {\"path\": \"a.java\""),
        ("mistralV11", #"[TOOL_CALLS]read_file[ARGS]{"path": "a.java""#),
        ("pythonicList", #"[read_file(path="a.java")"#),
        ("reactMarkdown", "Action: read_file\nAction Input: {\"path\": \"a.java\""),
        ("gorilla", #"<<function>>read_file(path="a.java""#),
        ("commandKey", #"{"command": "read_file", "options": {"path": "a.java"}}"#),
        ("deepSeek", "<\u{FF5C}tool\u{2581}calls\u{2581}begin\u{FF5C}><\u{FF5C}tool\u{2581}call\u{2581}begin\u{FF5C}>function<\u{FF5C}tool\u{2581}sep\u{FF5C}>read_file\n```json\n{\"path\": \"a.java\""),
        ("gemmaToolCode", "```tool_code\nread_file(path=\"a.java\")\n```"),
        ("dynamicTag", #"<read_file>{"path": "a.java"</read_file>"#),
        ("functionCallTag", #"<functioncall>read_file(path="a.java")</functioncall>"#),
        ("graniteCutOff", #"<|tool_call|>[{"name": "read_file", "arguments": {"path": "a.java""#),
        ("phiCutOff", #"functools[{"name": "read_file", "arguments": {"path": "a.java""#),
        ("bareCutOff", #"{"name": "read_file", "arguments": {"path": "a.java""#),
        ("unquotedArgs", #"{"name": "read_file", "arguments": {"path": a.java}}"#),
    ]

    /// Prose before the call, as models actually write it — long enough (> 300 chars) that the
    /// short-text `.toolNameInProse` rule cannot be what catches it.
    private let leadIn = String(repeating: "I looked through the repository layout and the January file before answering this. ", count: 4) + "\n\n"

    func testGrammarRecognisesEveryBrokenCallFormat() {
        for (label, text) in brokenCalls {
            XCTAssertNotNil(AttemptedToolCallGrammar.attemptedCallName(in: leadIn + text, callableNames: ["read_file"]), label)
        }
    }

    /// ⚠️ THE REGRESSION GUARD. Before the grammar knew format tokens, the verdict turned these
    /// failures into answers on up to 19 of 19 paths — and every existing suite stayed green.
    /// Retried on every prompt dialect AND the native (Ollama content) path.
    func testCallsInTokenFormatsAreRetriedOnEveryPath() {
        let everywhere = brokenCalls.filter { ["gorilla", "functionCallTag"].contains($0.label) }
            .map { ($0.label, leadIn + $0.text) }
            + brokenCalls.filter { $0.label == "commandKey" }.map { ($0.label, $0.text) }
        XCTAssertEqual(everywhere.count, 3, "fixture labels drifted — the matrix would pass vacuously")
        var accepted: [String] = []
        for (label, text) in everywhere {
            for (path, step) in allPaths(text) where isAnswer(step) { accepted.append("\(path) × \(label)") }
        }
        XCTAssertTrue(accepted.isEmpty, "broken calls shown as the answer:\n" + accepted.joined(separator: "\n"))
    }

    /// Same, for cut-off calls. These used to pass on the six marker/XML/Python dialects, where
    /// the cascade never looked for a call in text without a closing brace; it now asks the
    /// grammar first (CallRecoveryGateTests).
    func testCutOffMistralAndDeepXmlCallsAreRetriedOnEveryPath() {
        let cutOff = brokenCalls.filter { ["mistralV11", "deepXml"].contains($0.label) }
        XCTAssertEqual(cutOff.count, 2, "fixture labels drifted — the matrix would pass vacuously")
        var accepted: [String] = []
        for (label, text) in cutOff {
            for (path, step) in allPaths(leadIn + text) where isAnswer(step) {
                accepted.append("\(path) × \(label)")
            }
        }
        XCTAssertTrue(accepted.isEmpty, "broken calls shown as the answer:\n" + accepted.joined(separator: "\n"))
    }

    private func isAnswer(_ step: ModernCognitiveStep) -> Bool {
        if case .genuineCompletion = step.parseOutcome { return true }
        return false
    }

    /// Every prompt dialect with a registry, plus the native path: Ollama's content fallback
    /// re-decided by `NativeParsePipeline` against the run's tools.
    private func allPaths(_ text: String, excluding: Set<ModelDialect> = []) -> [(String, ModernCognitiveStep)] {
        var out: [(String, ModernCognitiveStep)] = ModelDialect.allCases.filter { !excluding.contains($0) }.map {
            ($0.rawValue, parse(text, $0))
        }
        let provider = OllamaLLMProvider.contentFallbackStep(
            content: text, thinking: nil, usage: nil, modelName: "test", toolNames: Set(tools.map(\.name)))
        out.append(("native", NativeParsePipeline(registeredTools: tools).validate(step: provider)))
        XCTAssertEqual(out.count, ModelDialect.allCases.count - excluding.count + 1)
        return out
    }
}
