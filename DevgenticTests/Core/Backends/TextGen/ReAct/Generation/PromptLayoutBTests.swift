// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
//
//  PromptLayoutBTests.swift
//  devgenticTests
//
//  Layout B (owner decision 2026-10-07): the system message holds only what stays the same for the
//  whole conversation; everything that changes per message rides the user message. A prefix cache —
//  `MLXPromptCache`, Ollama's KV cache, OpenAI's and Gemini's automatic caching — can only skip the
//  tokens a request shares with the previous one from the START, and the old order opened the system
//  message with the new question.
//
//  These pin the invariant from the outside: two messages of one conversation, on every path, must
//  send the same system message; nothing that changes per message may appear in it; and every
//  payload must still reach the model exactly once.
//

import XCTest
@testable import devgentic

final class PromptLayoutBTests: XCTestCase {

    private let historyOne = "<episodic_memory>\n<turn n=\"1\">ZZ_FIRST_TURN_ZZ</turn>\n</episodic_memory>"
    private let historyTwo = "<episodic_memory>\n<turn n=\"1\">ZZ_FIRST_TURN_ZZ</turn>\n<turn n=\"2\">ZZ_SECOND_TURN_ZZ</turn>\n</episodic_memory>"

    private struct Message {
        let query: String
        let history: String
        let time: String
        let retrieval: String
        var projectKnowledge: String? = nil
    }

    private lazy var first = Message(query: "ZZ_QUESTION_ONE_ZZ", history: historyOne, time: "2:31 PM", retrieval: "ZZ_RETRIEVED_ONE_ZZ")
    private lazy var second = Message(query: "ZZ_QUESTION_TWO_ZZ", history: historyTwo, time: "2:45 PM", retrieval: "ZZ_RETRIEVED_TWO_ZZ")

    private func context(_ message: Message, layerConfig: PromptLayerConfig = .agent) -> SemanticContext {
        var context = SemanticContext(
            instructions: "You are a coding assistant.",
            environmentFacts: EnvironmentFacts(
                osVersion: "macOS 26",
                shellType: "Zsh",
                userName: "tester",
                homeDirectory: "/Users/tester",
                currentDate: "07/10/2026",
                currentTime: message.time,
                workspaceRoot: "/Users/tester/project"
            ),
            longTermMemory: StaticGroundingMemory(ragContext: message.retrieval),
            recentHistory: message.history,
            nativeHistoryTurns: nil,
            originalQuery: message.query,
            currentIteration: 1,
            compiledScratchpad: "",
            latestClarification: nil,
            negativeConstraints: [],
            hallucinatedTools: [],
            availableTools: [],
            userProfile: nil,
            skillManifests: nil,
            promptLayerConfig: layerConfig,
            workflowContext: nil,
            knowledgeBaseContext: "ZZ_KNOWLEDGE_BASE_ZZ"
        )
        context.projectKnowledge = message.projectKnowledge
        return context
    }

    /// The four ways a request is assembled. Native mirrors `NativeStructuredGenerator.compileMessages`.
    private enum Path: CaseIterable {
        case legacyXML, legacyMarkdown, bot, native
    }

    private func build(_ path: Path, _ message: Message) -> [[String: String]] {
        switch path {
        case .legacyXML:
            return PromptBuilder.buildStandardMessages(context: context(message), dialectRules: "RULES", wrapping: .xml)
        case .legacyMarkdown:
            return PromptBuilder.buildStandardMessages(context: context(message), dialectRules: "RULES", wrapping: .markdown)
        case .bot:
            return PromptBuilder.buildStandardMessages(context: context(message, layerConfig: .bot), layerConfig: .bot,
                                                       userMessagePrefix: message.query)
        case .native:
            return NativeStructuredGenerator().compileMessages(from: context(message))
        }
    }

    private func system(_ messages: [[String: String]]) -> String {
        messages.first { $0["role"] == "system" }?["content"] ?? ""
    }

    private func user(_ messages: [[String: String]]) -> String {
        messages.filter { $0["role"] == "user" }.compactMap { $0["content"] }.joined(separator: "\n")
    }

    private func everything(_ messages: [[String: String]]) -> String {
        messages.compactMap { $0["content"] }.joined(separator: "\n")
    }

    private func occurrences(of needle: String, in haystack: String) -> Int {
        haystack.components(separatedBy: needle).count - 1
    }

    // MARK: - The rule

    /// THE POINT. Message 2 of a conversation — a new question, one more history turn, a later
    /// time, different retrieval — must send the system message byte for byte, on every path.
    func testEveryPathSendsTheSameSystemMessageForEveryMessage() {
        for path in Path.allCases {
            XCTAssertEqual(system(build(path, first)), system(build(path, second)),
                           "\(path): the system message changed between two messages, so nothing after the change can be reused")
        }
    }

    /// The user message leads with the history, so message 2 shares message 1's history bytes before
    /// its first new token. (Native: the history rides the kickoff turn — see the executor pin below.)
    func testTheUserMessageStartsWithWhatThePreviousMessageAlsoSent() {
        for path in [Path.legacyXML, .legacyMarkdown, .bot] {
            let one = user(build(path, first))
            let two = user(build(path, second))
            let shared = zip(one, two).prefix { $0 == $1 }.count
            let firstTurnEnds = one.range(of: "ZZ_FIRST_TURN_ZZ</turn>")!.upperBound
            XCTAssertGreaterThanOrEqual(shared, one.distance(from: one.startIndex, to: firstTurnEnds),
                                        "\(path): the user message changes before the history it shares with the previous message")
        }
    }

    func testNothingThatChangesPerMessageIsInTheSystemMessage() {
        for path in Path.allCases {
            let system = system(build(path, first))
            for (what, marker) in [("the question", "ZZ_QUESTION_ONE_ZZ"), ("the time", "2:31 PM"),
                                   ("the history", "ZZ_FIRST_TURN_ZZ"), ("the retrieved context", "ZZ_RETRIEVED_ONE_ZZ")] {
                XCTAssertFalse(system.contains(marker), "\(path): \(what) is in the system message")
            }
            XCTAssertTrue(system.contains("07/10/2026"), "\(path): the day must stay in the environment")
            XCTAssertTrue(system.contains("ZZ_KNOWLEDGE_BASE_ZZ"), "\(path): the knowledge base is conversation-stable and stays")
        }
    }

    /// Moved, not lost: every per-message payload still reaches the model, and the question exactly
    /// once. Bot and the native agent path used to send it twice (system `<task>` + user turn).
    func testEveryPayloadStillReachesTheModelAndTheQuestionOnlyOnce() {
        for path in [Path.legacyXML, .legacyMarkdown, .bot] {
            let all = everything(build(path, first))
            XCTAssertEqual(occurrences(of: "ZZ_QUESTION_ONE_ZZ", in: all), 1, "\(path): the question must be sent exactly once")
            for marker in ["2:31 PM", "ZZ_FIRST_TURN_ZZ", "ZZ_RETRIEVED_ONE_ZZ"] {
                XCTAssertTrue(user(build(path, first)).contains(marker), "\(path): '\(marker)' no longer reaches the model")
            }
        }
        // Native: the executor's kickoff turn carries the question and the turn context.
        let native = everything(build(.native, first))
        for marker in ["ZZ_QUESTION_ONE_ZZ", "2:31 PM", "ZZ_FIRST_TURN_ZZ", "ZZ_RETRIEVED_ONE_ZZ"] {
            XCTAssertFalse(native.contains(marker), "native: '\(marker)' must ride the kickoff turn, not compileMessages")
        }
        let kickoffPart = PromptBuilder.turnContext(context: context(first), layerConfig: .agent, wrapping: .xml) ?? ""
        for marker in ["2:31 PM", "ZZ_FIRST_TURN_ZZ", "ZZ_RETRIEVED_ONE_ZZ"] {
            XCTAssertTrue(kickoffPart.contains(marker), "native: '\(marker)' is missing from the turn context")
        }
    }

    /// The question sits after the context it is about, nearest the trigger.
    func testTheQuestionComesAfterTheTurnContext() {
        for path in [Path.legacyXML, .legacyMarkdown, .bot] {
            let user = user(build(path, first))
            let question = user.range(of: "ZZ_QUESTION_ONE_ZZ")!.lowerBound
            for marker in ["ZZ_FIRST_TURN_ZZ", "2:31 PM", "ZZ_RETRIEVED_ONE_ZZ"] {
                XCTAssertLessThan(user.range(of: marker)!.lowerBound, question, "\(path): '\(marker)' must precede the question")
            }
        }
    }

    // MARK: - Code project knowledge

    /// A memory saved or a stale mark flipped changes the project knowledge. Last in the system
    /// message, it costs only itself: everything before it — instructions, tools, environment —
    /// stays the same bytes.
    func testProjectKnowledgeChangesOnlyTheEndOfTheSystemMessage() {
        var before = first
        before.projectKnowledge = "# Project Memory Entries\n\n- build: run make"
        var after = first
        after.projectKnowledge = "# Project Memory Entries\n\n- build: run make (may be stale: Makefile)"

        for path in Path.allCases {
            let one = system(build(path, before))
            let two = system(build(path, after))
            let knowledgeStarts = one.range(of: "# Project Memory Entries")!.lowerBound
            XCTAssertTrue(two.hasPrefix(String(one[..<knowledgeStarts])), "\(path): something before the project knowledge changed")
            for stable in ["You are a coding assistant.", "07/10/2026", "ZZ_KNOWLEDGE_BASE_ZZ"] {
                XCTAssertLessThan(one.range(of: stable)!.lowerBound, knowledgeStarts,
                                  "\(path): '\(stable)' must come before the project knowledge")
            }
        }
    }

    func testProjectKnowledgeIsNeverPartOfTheInstructionsSection() {
        var message = first
        message.projectKnowledge = "ZZ_PROJECT_KNOWLEDGE_ZZ"
        let system = system(build(.legacyXML, message))
        let instructions = system.range(of: "<system_instructions>")!.upperBound..<system.range(of: "</system_instructions>")!.lowerBound
        XCTAssertFalse(system[instructions].contains("ZZ_PROJECT_KNOWLEDGE_ZZ"))
        XCTAssertTrue(system.contains("ZZ_PROJECT_KNOWLEDGE_ZZ"))
    }

    // MARK: - Workflow nodes

    /// A workflow node has no history, retrieval or task layer to move — only the clock splits.
    func testAWorkflowNodeKeepsTheTimeOutOfItsSystemMessage() {
        let messages = PromptBuilder.buildStandardMessages(context: context(first, layerConfig: .workflow), layerConfig: .workflow)
        XCTAssertFalse(system(messages).contains("2:31 PM"))
        XCTAssertTrue(user(messages).contains("2:31 PM"))
        XCTAssertFalse(everything(messages).contains("ZZ_FIRST_TURN_ZZ"), "a node has no episodic history")
    }

    // MARK: - Wiring

    private static var repoRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // Generation
            .deletingLastPathComponent()   // ReAct
            .deletingLastPathComponent()   // TextGen
            .deletingLastPathComponent()   // Backends
            .deletingLastPathComponent()   // Core
            .deletingLastPathComponent()   // devgenticTests
            .deletingLastPathComponent()   // repo root
    }

    /// The native executor is the turn context's second carrier. It needs a live model to drive, so
    /// this pins the call site: without it, history, time and retrieval vanish from every native run.
    func testTheNativeKickoffTurnLeadsWithTheTurnContext() throws {
        guard let source = try? String(contentsOf: Self.repoRoot.appendingPathComponent("Devgentic/Core/Backends/TextGen/ReAct/ReActAgentExecutor.swift"), encoding: .utf8) else {
            throw XCTSkip("ReActAgentExecutor.swift not reachable — running outside a checkout")
        }
        let kickoff = try XCTUnwrap(source.range(of: "let kickoffText: String = {"))
        let turn = try XCTUnwrap(source.range(of: "PromptBuilder.turnContext(context: context, layerConfig: context.promptLayerConfig, wrapping: .xml)"),
                                 "the kickoff turn no longer carries the turn context")
        let query = try XCTUnwrap(source.range(of: "parts.append(input.userInput)"))
        XCTAssertTrue(kickoff.upperBound < turn.lowerBound && turn.lowerBound < query.lowerBound,
                      "the turn context must lead the kickoff turn, before the question")
    }

    /// A workflow node's native request has no kickoff carrier for it, so `compileMessages` keeps it.
    func testANativeWorkflowNodeKeepsTheTurnContextInItsOwnUserMessage() {
        var ctx = context(first, layerConfig: .workflow)
        ctx = SemanticContext(
            instructions: ctx.instructions, environmentFacts: ctx.environmentFacts, longTermMemory: ctx.longTermMemory,
            recentHistory: nil, nativeHistoryTurns: nil, originalQuery: "node input", currentIteration: 1,
            compiledScratchpad: "", latestClarification: nil, negativeConstraints: [], hallucinatedTools: [],
            availableTools: [], userProfile: nil, skillManifests: nil, promptLayerConfig: .workflow,
            workflowContext: WorkflowExecutionContext(input: "node input", isFirstNode: true, nodeName: "Node", nodeID: UUID())
        )
        let messages = NativeStructuredGenerator().compileMessages(from: ctx)
        XCTAssertTrue(user(messages).contains("2:31 PM"), "a native workflow node lost the current time")
        XCTAssertFalse(system(messages).contains("2:31 PM"))
    }
}

// MARK: - Bot prompt cache key

/// Records the MLX prompt-cache key in force when the Bot path starts its stream.
private final class KeyRecordingProvider: LLMProvider, @unchecked Sendable {
    let modelName = "key-recorder"
    private let lock = NSLock()
    private var _keys: [String?] = []
    var keys: [String?] { lock.lock(); defer { lock.unlock() }; return _keys }

    func stream(messages: [[String: String]], tools: [[String: Any]]?) -> AsyncThrowingStream<String, Error> {
        let key = MLXPromptCacheScope.key
        lock.lock(); _keys.append(key); lock.unlock()
        return AsyncThrowingStream { continuation in
            continuation.yield("Hello.")
            continuation.finish()
        }
    }

    func generate(messages: [[String: String]], tools: [[String: Any]]?, responseSchema: Any?) async throws -> String { "" }

    func generateCognitiveStep(messages: [[String: String]], tools: [[String: Any]]?) async throws -> ModernCognitiveStep {
        ModernCognitiveStep(reasoning: "unused")
    }
}

final class BotPromptCacheKeyTests: XCTestCase {

    private func run(_ input: AgentInput, on provider: KeyRecordingProvider) async throws {
        for try await _ in ChatExecutor().execute(model: provider, input: input, onTraceUpdate: { _ in }) {}
    }

    /// The Bot's stream runs under its conversation's key, so MLX keeps the prompt for the next
    /// message — and only that call: nothing else the Bot does carries it.
    func testABotMessageRunsUnderItsConversationsCacheKey() async throws {
        let provider = KeyRecordingProvider()
        let input = TestAgentInputFactory.make(query: "Say hello")
        try await run(input, on: provider)
        XCTAssertEqual(provider.keys, [input.conversationID.uuidString])
        XCTAssertNil(MLXPromptCacheScope.key, "the key must not outlive the call it was set for")
    }

    /// One-shot workflow nodes sharing a run's conversation would only evict each other.
    func testAWorkflowBotNodeRunsWithoutACacheKey() async throws {
        let provider = KeyRecordingProvider()
        let input = TestAgentInputFactory.make(
            query: "node input",
            workflowContext: WorkflowExecutionContext(input: "node input", isFirstNode: true, nodeName: "Node", nodeID: UUID()))
        try await run(input, on: provider)
        XCTAssertEqual(provider.keys, [nil])
    }
}
