// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
//
//  ParserBatch7Tests.swift
//  DevgenticTests
//
//  Core readiness P2 batch 7 (2026-10-12): prompted-dialect parsing.
//    CR-50  Command-R7B calls lost every argument (marker stripped before the parser ran)
//    CR-52  a partial batch dropped its failed calls without telling anyone
//    CR-53  the sanitizer kept only the first of two DIFFERENT JSON blocks
//    CR-54  ReAct `Action:` matched inside prose ("transaction: history")
//    CR-55  Command-R re-read the same array after a second `Action:`
//
//  Calls are driven through the REAL `CognitiveParsePipeline` (sanitizer first, as in production),
//  because the CR-50 defect lived exactly in the gap between the sanitizer and the parser.
//

import XCTest
@testable import devgentic

final class ParserBatch7Tests: XCTestCase {

    private func tool(_ name: String, _ args: [String]) -> AgentTool {
        AgentTool(name: name, description: "test tool",
                  parameters: ToolParameters(type: "object",
                                             properties: Dictionary(uniqueKeysWithValues: args.map { ($0, ToolParameterProperty(type: "string", description: nil, items: nil)) }),
                                             required: args),
                  requiresConfirmation: false,
                  run: { _ in ("ok", []) })
    }

    private lazy var tools = [tool("search", ["q"]), tool("read_file", ["path"]), tool("final_answer", ["answer"])]

    private func parse(_ raw: String, _ dialect: ModelDialect) -> ModernCognitiveStep {
        CognitiveParsePipeline(expectedDialect: dialect, registeredTools: tools).parse(raw: raw)
    }

    // MARK: - CR-50

    /// The canonical R7B shape, two calls. Before the fix: the sanitizer stripped
    /// `<|START_ACTION|>`, the parser found nothing, and the heuristic produced ONE call with
    /// `[:]` arguments (it reads `arguments`, never `parameters`).
    func testCR50_CommandR7BCallsKeepTheirParameters_ThroughTheRealPipeline() {
        let raw = """
        <|START_THINKING|>I will search, then read the file.<|END_THINKING|><|START_ACTION|>[
            {"tool_call_id": "0", "tool_name": "search", "parameters": {"q": "weather in Pune"}},
            {"tool_call_id": "1", "tool_name": "read_file", "parameters": {"path": "/tmp/a.txt"}}
        ]<|END_ACTION|>
        """
        let step = parse(raw, .commandR7BAction)

        XCTAssertEqual(step.toolCalls.map(\.name), ["search", "read_file"])
        XCTAssertEqual(step.toolCalls.first?.arguments["q"], .string("weather in Pune"))
        XCTAssertEqual(step.toolCalls.last?.arguments["path"], .string("/tmp/a.txt"))
    }

    /// Without the marker, `name` alone must not make an answer a call: `[{"name": "Ada"}]` is a
    /// JSON answer, not a call to a tool called "Ada".
    func testCR50_AMarkerlessArrayNeedsTheDialectsOwnKey() {
        let parser = CommandR7BActionParser()
        XCTAssertTrue(parser.parse(rawResponse: #"The team: [{"name": "Ada", "role": "lead"}]"#).toolCalls.isEmpty)
        XCTAssertEqual(parser.parse(rawResponse: #"Plan [1] first. [{"tool_name": "search", "parameters": {"q": "x"}}]"#).toolCalls.map(\.name),
                       ["search"], "a bracket in the prose before the array must not hide it")
    }

    /// The heuristic, the last fallback for every dialect, reads the Cohere spelling too.
    func testCR50_HeuristicReadsTheParametersSpelling() {
        let step = HeuristicCognitiveParser().parse(rawResponse: #"{"tool_name": "search", "parameters": {"q": "swift"}}"#)
        XCTAssertEqual(step.toolCalls.first?.arguments["q"], .string("swift"))
    }

    // MARK: - CR-52

    private static let partialBatch = """
    <tool_call>{"name": "read_file", "arguments": {"path": "/tmp/a.txt"}}</tool_call>
    <tool_call>{"name": "launch_rocket", "arguments": {"target": "moon"}}</tool_call>
    """

    func testCR52_PromptedPipelineCarriesTheRejectedSibling() {
        let step = parse(Self.partialBatch, .qwenHermesToolCall)

        XCTAssertEqual(step.toolCalls.map(\.name), ["read_file"])
        guard case .success = step.parseOutcome else { return XCTFail("partial progress is still a success, got \(step.parseOutcome)") }
        XCTAssertEqual(step.rejectedCalls.map(\.call.name), ["launch_rocket"], "the failed sibling must not vanish")
        guard case .unknownToolName = step.rejectedCalls.first?.reason else { return XCTFail("expected an unknown-tool reason") }
    }

    /// A fence inside an argument string makes the pipeline shield and then UNSHIELD the step,
    /// which rebuilds it field by field. The rejected sibling must survive that rebuild too.
    func testCR52_TheRejectedSiblingSurvivesTheCodeFenceShield() {
        let raw = #"<tool_call>{"name": "read_file", "arguments": {"path": "/tmp/notes```md"}}</tool_call>"# + "\n"
            + #"<tool_call>{"name": "launch_rocket", "arguments": {"target": "```moon```"}}</tool_call>"#
        let step = parse(raw, .qwenHermesToolCall)

        XCTAssertEqual(step.toolCalls.first?.arguments["path"], .string("/tmp/notes```md"), "precondition: the shield ran")
        XCTAssertEqual(step.rejectedCalls.map(\.call.name), ["launch_rocket"])
        XCTAssertEqual(step.rejectedCalls.first?.call.arguments["target"], .string("```moon```"), "and its arguments are unshielded")
    }

    func testCR52_NativePipelineCarriesTheRejectedSibling() {
        let providerStep = ModernCognitiveStep(reasoning: "", toolCalls: [
            PendingToolCall(id: "a", name: "read_file", arguments: ["path": .string("/tmp/a.txt")]),
            PendingToolCall(id: "b", name: "search", arguments: ["query": .string("wrong key")]),
        ])
        let step = NativeParsePipeline(registeredTools: tools).validate(step: providerStep)

        XCTAssertEqual(step.toolCalls.map(\.name), ["read_file"])
        XCTAssertEqual(step.rejectedCalls.map(\.call.id), ["b"])
        XCTAssertTrue(step.rejectedCalls.first?.modelNote.contains("missing required: q") == true,
                      "got \(String(describing: step.rejectedCalls.first?.modelNote))")
    }

    /// The wiring: through the REAL executor, the model's next prompt must say the sibling did
    /// not run. Fails if anything between the parsed step and the loop drops `rejectedCalls`.
    func testCR52_TheModelIsToldTheRejectedSiblingDidNotRun() async throws {
        let rejected = RejectedSiblingCall(
            call: PendingToolCall(id: "r1", name: "launch_rocket", arguments: ["target": .string("moon")]),
            reason: .unknownToolName(attempted: "launch_rocket", suggestions: ["read_file"]))
        let provider = MockLLMProvider(steps: [
            ModernCognitiveStep(reasoning: "Reading.", toolCalls: [PendingToolCall(id: "c1", name: "read_file", arguments: ["path": .string("/tmp/a.txt")])],
                                rejectedCalls: [rejected]),
            ModernCognitiveStep(reasoning: "Done.", parseOutcome: .genuineCompletion),
        ])
        let input = TestAgentInputFactory.make(query: "read it", tools: tools)

        _ = try await StreamCollector.collect(from: ReActAgentExecutor(maxIterations: 4).execute(model: provider, input: input) { _ in })

        let secondPrompt = provider.receivedCognitiveMessages.dropFirst().first?.map { $0["content"] ?? "" }.joined(separator: "\n") ?? ""
        XCTAssertTrue(secondPrompt.contains("there is no tool named 'launch_rocket'"),
                      "the model was never told its call did not run. Second prompt:\n\(secondPrompt.suffix(1500))")
    }

    // MARK: - CR-53

    func testCR53_TwoDifferentJSONBlocksAreBothKept() {
        let raw = #"{"name": "read_file", "arguments": {"path": "/a"}}"# + "\n" + #"{"name": "search", "arguments": {"q": "b"}}"#
        let cleaned = OutputSanitizer.sanitize(raw).cleaned
        XCTAssertTrue(cleaned.contains("read_file") && cleaned.contains("search"), "a different second call was dropped: \(cleaned)")
    }

    func testCR53_AnExactRepeatIsStillDropped_EvenWithAnEscapedBackslash() {
        let block = #"{"name": "read_file", "arguments": {"path": "C:\\"}}"#
        let cleaned = OutputSanitizer.sanitize(block + "\n" + block).cleaned
        XCTAssertEqual(cleaned, block, "an exact repeat must leave one copy (and the escaped backslash must not end the scan)")
    }

    // MARK: - CR-54

    func testCR54_ActionInsideProseIsNotACall() {
        let step = parse("The last transaction: history shows two payments of $40, so the balance is $120.", .reactMarkdown)
        XCTAssertTrue(step.toolCalls.isEmpty, "prose became a call to \(step.toolCalls.map(\.name))")
        XCTAssertTrue(step.reasoning.contains("$120"), "the answer must survive")
    }

    func testCR54_LineStartActionsStillParse_IncludingMarkdownBold() {
        let plain = parse("Thought: I need the file.\nAction: read_file\nAction Input: {\"path\": \"/tmp/a.txt\"}", .reactMarkdown)
        XCTAssertEqual(plain.toolCalls.map(\.name), ["read_file"])
        let bold = ReActMarkdownParser.extractField(named: "Action", from: "**Thought:** check\n**Action:** read_file\n")
        XCTAssertEqual(bold, "read_file")
        XCTAssertNil(ReActMarkdownParser.extractField(named: "Action", from: "the transaction: history"))
    }

    // MARK: - CR-55

    func testCR55_ASecondActionBeforeTheArrayDoesNotDuplicateTheCalls() {
        let raw = """
        Thought: The next Action: is a search.
        Action: ```json
        [{"tool_name": "search", "parameters": {"q": "weather"}}]
        ```
        """
        XCTAssertEqual(CommandRActionParser().parse(rawResponse: raw).toolCalls.count, 1, "the parser itself")
        XCTAssertEqual(parse(raw, .commandRAction).toolCalls.count, 1, "and through the real pipeline (fences stripped first)")
    }

    func testCR55_TwoRealActionBlocksAreBothKept() {
        let raw = """
        Action: [{"tool_name": "search", "parameters": {"q": "a"}}]
        Action: [{"tool_name": "read_file", "parameters": {"path": "/b"}}]
        """
        XCTAssertEqual(CommandRActionParser().parse(rawResponse: raw).toolCalls.map(\.name), ["search", "read_file"])
    }
}
