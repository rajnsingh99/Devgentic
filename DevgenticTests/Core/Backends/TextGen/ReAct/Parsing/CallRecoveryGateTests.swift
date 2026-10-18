// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
//
//  CallRecoveryGateTests.swift
//  DevgenticTests
//
//  Created by Raj Singh.
//

import XCTest
@testable import devgentic

final class CallRecoveryGateTests: XCTestCase {

    private static func tool(_ name: String) -> AgentTool {
        AgentTool(
            name: name,
            description: "A test tool.",
            parameters: SchemaBuilder.object(
                properties: [("path", "string", "File path."), ("content", "string", "File content.")],
                required: ["path"]
            ),
            requiresConfirmation: false,
            textOnlyRun: { _ in "ok" }
        )
    }

    private let tools = ["final_answer", "read_file", "write_file"].map(CallRecoveryGateTests.tool)
    private var toolNames: Set<String> { Set(tools.map(\.name)) }

    /// Prose before the call, as models write it — longer than the 300-char short-text rule.
    private let lead = String(repeating: "I looked through the repository layout and the January file before answering this. ", count: 4) + "\n\n"

    private func parse(_ text: String, _ dialect: ModelDialect, known: Set<String>? = nil) -> ModernCognitiveStep {
        CognitiveParsePipeline(
            expectedDialect: dialect, knownToolNames: known ?? toolNames, registeredTools: tools
        ).parse(raw: text)
    }

    /// Ollama's content fallback, then the native verdict — as `NativeStructuredGenerator` runs it.
    private func native(_ text: String, requestToolNames: Set<String>? = nil) -> ModernCognitiveStep {
        let provider = OllamaLLMProvider.contentFallbackStep(
            content: text, thinking: nil, usage: nil, modelName: "test", toolNames: requestToolNames ?? toolNames)
        return NativeParsePipeline(registeredTools: tools).validate(step: provider)
    }

    /// Every prompt dialect, plus the native path.
    private func everyPath(_ text: String) -> [(String, ModernCognitiveStep)] {
        ModelDialect.allCases.map { ($0.rawValue, parse(text, $0)) } + [("native", native(text))]
    }

    private func isAnswer(_ step: ModernCognitiveStep) -> Bool {
        if case .genuineCompletion = step.parseOutcome { return true }
        return false
    }

    private func label(_ step: ModernCognitiveStep) -> String {
        switch step.parseOutcome {
        case .genuineCompletion: return "answer"
        case .success: return "call(\(step.toolCalls.map(\.name).joined(separator: ",")))"
        case .failed(let reason): return "FAILED(\(reason.uiChipLabel))"
        }
    }

    // MARK: - Valid calls are recovered

    /// ⚠️ The sanitizer guard. Each of these was accepted as the ANSWER on Mistral XML, ReAct
    /// Markdown, Mistral v11, Pythonic, Qwen3-Coder and DeepSeek V3.2: a trailing `</tool_call>`
    /// was stripped as an "orphan" though it closed a real pair, and `<|python_tag|>` was stripped
    /// as a control token though it opens a call.
    func testValidCallsAfterProseAreRecoveredOnEveryDialect() {
        let calls = [
            ("toolCallEndingTheReply", "<tool_call>\n{\"name\": \"read_file\", \"arguments\": {\"path\": \"a.java\"}}\n</tool_call>"),
            ("pythonTag", #"<|python_tag|>{"name": "read_file", "parameters": {"path": "a.java"}}"#),
            ("granite3", #"<|tool_call|>[{"name": "read_file", "arguments": {"path": "a.java"}}]"#),
        ]
        var missed: [String] = []
        for (label, call) in calls {
            for dialect in ModelDialect.allCases {
                let step = parse(lead + call, dialect)
                if step.toolCalls.map(\.name) != ["read_file"] || step.toolCalls.first?.arguments["path"] != .string("a.java") {
                    missed.append("\(dialect.rawValue) × \(label) → \(self.label(step))")
                }
            }
        }
        XCTAssertTrue(missed.isEmpty, "valid calls not recovered:\n" + missed.joined(separator: "\n"))
    }

    /// Keeping `<|python_tag|>` through sanitizing lets the drift detector route the reply to the
    /// Llama 3.1 parser, which keeps the model's prose before the call. Without the token, generic
    /// recovery still finds the call but drops that prose — from the thinking timeline and from
    /// the reasoning carried into the next iteration. Pinned on Native JSON — the dialect of the
    /// Ollama content fallback and MLX JSON mode. (Some dialects, e.g. Qwen/Hermes, recover this
    /// call by another route that drops the prose with or without the token.)
    func testAPythonTagCallKeepsTheProseBeforeIt() {
        let text = lead + #"<|python_tag|>{"name": "read_file", "parameters": {"path": "a.java"}}"#
        for dialect: ModelDialect in [.nativeJSON] {
            let step = parse(text, dialect)
            XCTAssertEqual(step.toolCalls.map(\.name), ["read_file"], dialect.rawValue)
            XCTAssertTrue(step.reasoning.contains("I looked through the repository"),
                          "\(dialect.rawValue): the prose before the call was dropped — got '\(step.reasoning.prefix(60))'")
        }
    }

    // MARK: - Cut-off calls are never the answer

    func testCutOffCallsAfterProseAreNeverTheAnswer() {
        let calls = [
            ("bare", #"{"name": "read_file", "arguments": {"path": "a.java""#),
            ("toolCall", "<tool_call>\n{\"name\": \"read_file\", \"arguments\": {\"path\": \"a.java\""),
            ("toolCallWrongInner", "<tool_call>\nread_file(path=\"a.java\")\n</tool_call>"),
            ("granite3", #"<|tool_call|>[{"name": "read_file", "arguments": {"path": "a.java""#),
            ("phi", #"functools[{"name": "read_file", "arguments": {"path": "a.java""#),
            ("pythonTag", #"<|python_tag|>read_file.call(path="a.java""#),
            ("pythonicList", #"[read_file(path="a.java")"#),
            ("gemmaToolCode", "```tool_code\nread_file(path=\"a.java\")\n```"),
            ("deepSeek", "<\u{FF5C}tool\u{2581}calls\u{2581}begin\u{FF5C}><\u{FF5C}tool\u{2581}call\u{2581}begin\u{FF5C}>function<\u{FF5C}tool\u{2581}sep\u{FF5C}>read_file\n```json\n{\"path\": \"a.java\""),
            ("unknownKeys", #"{"command": "read_file", "options": {"path": "a.java"}}"#),
        ]
        var accepted: [String] = []
        for (label, call) in calls {
            for (path, step) in everyPath(lead + call) where isAnswer(step) {
                accepted.append("\(path) × \(label)")
            }
        }
        XCTAssertTrue(accepted.isEmpty, "cut-off calls shown as the answer:\n" + accepted.joined(separator: "\n"))
    }

    /// ⚠️ THE SAFETY ASSERTION. Routing cut-off calls into recovery must not EXECUTE one whose value
    /// was cut short — a `write_file` with half its content would corrupt the file.
    func testACallCutMidValueIsNeverExecuted() {
        let cuts = [
            "{\"name\": \"write_file\", \"arguments\": {\"path\": \"a.java\", \"content\": \"class A {\\n  int x = 1;\\n  void f() {",
            "<tool_call>\n{\"name\": \"write_file\", \"arguments\": {\"path\": \"a.java\", \"content\": \"class A {\\n  int x",
            #"{"name": "read_file", "arguments": {"path": "src/dsa/jan26/Janu"#,
        ]
        var executed: [String] = []
        for cut in cuts {
            for text in [cut, lead + cut] {
                for (path, step) in everyPath(text) where !step.toolCalls.isEmpty || isAnswer(step) {
                    executed.append("\(path) → \(label(step)) for: \(cut.prefix(40))")
                }
            }
        }
        XCTAssertTrue(executed.isEmpty, "a call cut mid-value was run or shown:\n" + executed.joined(separator: "\n"))
    }

    /// Recovery of a call whose every value is complete — only its closing braces were lost — runs
    /// it with exactly what the model wrote. (The parser already did this for SHORT replies; the
    /// grammar check extends it past a paragraph of prose.)
    func testACallMissingOnlyItsClosersRunsWithExactlyWhatWasWritten() {
        let text = lead + #"{"name": "write_file", "arguments": {"path": "a.java", "content": "class A {}""#
        for dialect: ModelDialect in [.nativeJSON, .llama3JsonSingle, .qwenHermesToolCall, .reactMarkdown, .mistralXML] {
            let step = parse(text, dialect)
            XCTAssertEqual(step.toolCalls.map(\.name), ["write_file"], dialect.rawValue)
            XCTAssertEqual(step.toolCalls.first?.arguments["content"], .string("class A {}"), dialect.rawValue)
        }
    }

    /// A broken call to a tool withheld from THIS iteration's schema: recognised only when the
    /// run's loadout reaches the parser (`SemanticContext.runToolNames` → `knownToolNames`).
    func testAWithheldToolCutOffIsRetriedOnlyWhenTheRunLoadoutIsKnown() {
        let text = lead + "{\"name\": \"save_notes\", \"content\": \"# Project\\nA Java DSA repo"
        let loadout = toolNames.union(["save_notes"])
        for dialect in ModelDialect.allCases {
            XCTAssertFalse(isAnswer(parse(text, dialect, known: loadout)), "\(dialect.rawValue): shown as the answer")
            XCTAssertTrue(isAnswer(parse(text, dialect, known: toolNames)),
                          "\(dialect.rawValue): fixture precondition — without the loadout nothing declares a call")
        }
    }

    // MARK: - Answers stay answers

    /// An answer that QUOTES a format token in inline code is prose, not a call.
    func testFormatTokensQuotedInInlineCodeAreAnAnswer() {
        let text = lead + "Hermes wraps calls in `<tool_call>` tags, Mistral uses `[TOOL_CALLS]`, and Llama 3.1 starts with `<|python_tag|>`."
        var rejected: [String] = []
        for (path, step) in everyPath(text) where !isAnswer(step) { rejected.append("\(path) → \(label(step))") }
        XCTAssertTrue(rejected.isEmpty, "a quoted token was taken for a call:\n" + rejected.joined(separator: "\n"))
    }

    /// A call the model only CONSIDERED while thinking is not an attempt.
    func testACallOnlyConsideredWhileThinkingIsNotAnAttempt() {
        let text = "<think>I could call {\"name\": \"read_file\", \"arguments\": {\"path\": \"a.java\"} but I already know.</think>"
            + lead + "The method returns 7 for the sample input."
        var rejected: [String] = []
        for (path, step) in everyPath(text) where !isAnswer(step) { rejected.append("\(path) → \(label(step))") }
        XCTAssertTrue(rejected.isEmpty, "a thought was taken for a call:\n" + rejected.joined(separator: "\n"))
    }

    /// Native path: the content cascade fails this answer on its braces, and the native verdict
    /// must then ignore the call that appears only inside the thinking block.
    func testTheNativeVerdictIgnoresACallConsideredWhileThinking() {
        let text = "<think>Maybe {\"name\": \"read_file\", \"arguments\": {\"path\": \"a.java\"}}.</think>"
            + "With the sample array {7, 1, 5, 3, 6, 4} the method returns 7."
        let provider = OllamaLLMProvider.contentFallbackStep(
            content: text, thinking: nil, usage: nil, modelName: "test", toolNames: toolNames)
        guard case .failed = provider.parseOutcome else {
            return XCTFail("fixture precondition: the content cascade must fail the answer on its braces")
        }
        XCTAssertTrue(isAnswer(NativeParsePipeline(registeredTools: tools).validate(step: provider)),
                      "a call considered while thinking kept a real answer from being accepted")
    }

    // MARK: - Wiring

    func testOllamaReadsToolNamesFromTheRequest() {
        let tools: [[String: Any]] = [
            ["type": "function", "function": ["name": "read_file", "parameters": [:] as [String: Any]]],
            ["type": "function", "function": ["name": "git"]],
        ]
        XCTAssertEqual(OllamaLLMProvider.declaredToolNames(in: tools), ["read_file", "git"])
        XCTAssertEqual(OllamaLLMProvider.declaredToolNames(in: nil), [])
    }

    /// A cut-off call declared only by its tool NAME (no arguments object, no format token): the
    /// content fallback needs the request's tool names to see it.
    private let nameOnlyCutOff = "I checked the layout first.\n\n{\"name\": \"read_file\", \"path\": \"src/a.ja"

    func testOllamaContentFallbackUsesTheRequestToolNames() {
        XCTAssertFalse(isAnswer(native(nameOnlyCutOff)), "shown as the answer with the request's tool names known")
        XCTAssertTrue(isAnswer(native(nameOnlyCutOff, requestToolNames: [])),
                      "fixture precondition: without the names nothing declares a call")
    }

    /// ⚠️ THE CALL SITE. The provider must hand its request's tools to the fallback — a unit test of
    /// `contentFallbackStep` alone passes even when the provider forgets to.
    func testOllamaProviderPassesItsRequestToolsToTheFallback() async throws {
        URLProtocol.registerClass(OllamaStubProtocol.self)
        defer { URLProtocol.unregisterClass(OllamaStubProtocol.self) }
        OllamaStubProtocol.content = nameOnlyCutOff

        let provider = OllamaLLMProvider(config: LLMProviderConfig(
            baseURL: URL(string: "http://\(OllamaStubProtocol.host)")!, modelName: "stub", rateLimitKey: "call-recovery-gate-test"))
        let requestTools: [[String: Any]] = [["type": "function", "function": ["name": "read_file"]]]
        let step = try await provider.generateCognitiveStep(
            nativeMessages: [["role": "user", "content": "read it"]], tools: requestTools)

        XCTAssertFalse(isAnswer(step), "the provider dropped its request's tool names: \(label(step))")
    }

    /// Every prompt-dialect generator must hand the run's loadout to its parser.
    func testEveryPromptGeneratorReadsTheRunLoadout() async throws {
        let response = lead + "{\"name\": \"save_notes\", \"content\": \"# Project\\nA Java DSA repo"
        let generators: [(String, any CognitiveGenerator)] = [
            ("XMLStructuredGenerator", XMLStructuredGenerator()),
            ("MLXNativeStructuredGenerator", MLXNativeStructuredGenerator()),
            ("JsonStructuredGenerator", JsonStructuredGenerator()),
            ("XMLNativeStructuredGenerator", XMLNativeStructuredGenerator()),
            ("NativeToolTemplateGenerator", NativeToolTemplateGenerator.qwenHermes()),
            ("MarkdownStructuredGenerator", MarkdownStructuredGenerator()),
        ]
        for (name, generator) in generators {
            var context = Self.context(tools: tools)
            context.runToolNames = toolNames.union(["save_notes"])
            let step = try await generator.generateCognitiveStep(
                model: MockLLMProvider(generateResponses: [response]), context: context, iteration: 1)
            XCTAssertFalse(isAnswer(step), "\(name) ignored the run loadout: a broken call to a withheld tool was the answer")
        }
    }

    /// The executor fills `runToolNames` with the FULL loadout, and since the reading gate was
    /// removed (2026-10-06) every tool is offered from the first iteration — the memory tools too.
    func testTheExecutorGivesGeneratorsTheRunLoadout() async throws {
        let spy = LoadoutSpyGenerator()
        let input = TestAgentInputFactory.make(
            query: "remember the test command",
            tools: [Self.tool("read_file"), Self.tool("remember")],
            generatorStrategy: spy)
        _ = try await StreamCollector.collect(
            from: ReActAgentExecutor(maxIterations: 3).execute(model: MockLLMProvider(), input: input) { _ in })

        let first = try XCTUnwrap(spy.seen.first)
        XCTAssertTrue(first.run.contains("remember"), "the run loadout never reached the generator")
        XCTAssertTrue(first.available.contains("remember"),
                      "a tool was withheld on iteration 1 — the reading gate is back")
    }

    // MARK: - Fixtures

    private static func context(tools: [AgentTool]) -> SemanticContext {
        SemanticContext(
            instructions: "You are a helpful agent.",
            environmentFacts: EnvironmentFacts(osVersion: "macOS", shellType: "zsh", userName: "t", homeDirectory: "/Users/t", currentDate: "01/01/2026"),
            longTermMemory: StaticGroundingMemory(ragContext: ""),
            recentHistory: nil,
            nativeHistoryTurns: nil,
            originalQuery: "update the context",
            currentIteration: 1,
            compiledScratchpad: "",
            latestClarification: nil,
            negativeConstraints: [],
            hallucinatedTools: [],
            availableTools: tools,
            userProfile: nil,
            skillManifests: nil,
            promptLayerConfig: .agent,
            workflowContext: nil
        )
    }
}

/// Records the tool names each iteration's context offered vs. the run's loadout, then answers.
private final class LoadoutSpyGenerator: CognitiveGenerator, @unchecked Sendable {
    let toolAdapter: ToolSchemaAdapter = LegacyPromptAdapter()
    let dialectRules: String? = nil
    var expectedDialect: ModelDialect? { .heuristicJson }
    private(set) var seen: [(available: Set<String>, run: Set<String>)] = []

    func compileMessages(from context: SemanticContext) -> [[String: String]] {
        [["role": "user", "content": context.originalQuery]]
    }

    func generateCognitiveStep(model: any LLMProvider, context: SemanticContext, iteration: Int) async throws -> ModernCognitiveStep {
        seen.append((Set(context.availableTools.map(\.name)), context.runToolNames))
        return ModernCognitiveStep(reasoning: "Done.", parseOutcome: .genuineCompletion)
    }
}

/// Answers `/api/chat` for one fake host with a fixed assistant `content` and no tool calls.
private final class OllamaStubProtocol: URLProtocol {
    static let host = "ollama-stub.test"
    nonisolated(unsafe) static var content = ""

    override class func canInit(with request: URLRequest) -> Bool { request.url?.host == host }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let body: [String: Any] = [
            "model": "stub", "done": true,
            "message": ["role": "assistant", "content": Self.content],
        ]
        let data = (try? JSONSerialization.data(withJSONObject: body)) ?? Data()
        let response = HTTPURLResponse(
            url: request.url!, statusCode: 200, httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "application/json"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
