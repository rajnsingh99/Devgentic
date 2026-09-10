// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2026 Raj Singh
//
//  WorkflowNativeDoubleSendTests.swift
//  DevgenticTests
//
//  Created on 31/08/26.
//
//  Register EIO-2: a workflow AGENT node on the native path sent its input TWICE — once as the
//  `<input>`-wrapped, escaped user message `compileMessages` builds from
//  `WorkflowExecutionContext.userMessagePrefix`, and again raw inside the kickoff user turn the
//  native executor appends (`parts.append(input.userInput)`). Two consecutive user turns, the same
//  payload in two encodings, on every iteration of every retry — for a 10 KB upstream, 20 KB per
//  request.
//
//  Observed at the ReAct seam: `MockLLMProvider` captures the exact message array the executor
//  sends, so the doubled payload is directly assertable — unlike the workflow-executor seam, where
//  the WF-CC1 note applies.
//

import XCTest
@testable import devgentic

final class WorkflowNativeDoubleSendTests: XCTestCase {

    /// A sentinel no template or boilerplate could contain twice by accident.
    private let sentinel = "UPSTREAM-SENTINEL-7f3a1c"

    private func workflowInput(query: String = "ignored") -> AgentInput {
        TestAgentInputFactory.make(
            query: sentinel,   // AgentConnect sets userInput = workflowContext.input; mirror that.
            generatorStrategy: NativeStructuredGenerator(),
            workflowContext: WorkflowExecutionContext(
                input: sentinel,
                isFirstNode: false,
                nodeName: "Downstream Agent",
                nodeID: UUID()
            )
        )
    }

    private func userMessagesContainingSentinel(_ request: [[String: String]]) -> [String] {
        request.filter { $0["role"] == "user" }
               .compactMap { $0["content"] }
               .filter { $0.contains(sentinel) }
    }

    /// ⚠️ THE FILED BUG. The upstream payload must reach the model in EXACTLY ONE user message —
    /// the `<input>`-wrapped one, which carries the escaping, the attachment manifest and the
    /// document text the security note refers to. The raw kickoff duplicate is the defect.
    func testWorkflowInputReachesTheModelExactlyOnce() async throws {
        let provider = MockLLMProvider(steps: [ModernCognitiveStep(reasoning: "Done.")])
        let stream = ReActAgentExecutor(maxIterations: 2)
            .execute(model: provider, input: workflowInput()) { _ in }
        _ = try await StreamCollector.collect(from: stream)

        let firstRequest = try XCTUnwrap(provider.receivedCognitiveMessages.first)
        let carriers = userMessagesContainingSentinel(firstRequest)

        XCTAssertEqual(carriers.count, 1,
                       "the workflow input must be sent once, in its designed <input> form — got "
                       + "\(carriers.count) user message(s) carrying it: "
                       + "\(carriers.map { String($0.prefix(80)) })")
        XCTAssertTrue(carriers.first?.contains("<input>") ?? false,
                      "the surviving copy must be the designed channel — <input>-wrapped, escaped, "
                      + "with the manifest sections — not the raw kickoff duplicate")

        // The kickoff turn is legitimately ABSENT here (no seeds, no attachments, no images) — and
        // its absence must not be papered over with a blank message, which some providers reject.
        XCTAssertFalse(firstRequest.contains { $0["role"] == "user" && ($0["content"] ?? "").isEmpty },
                       "an empty kickoff turn must be skipped, not sent blank")
    }

    /// The control: a CHAT run (no workflow context) has no prefix message, so the kickoff turn is
    /// the only carrier and must keep carrying the query — suppressing it globally would send chat
    /// requests with no user input at all.
    func testAChatRunsQueryStillRidesTheKickoffTurn() async throws {
        let provider = MockLLMProvider(steps: [ModernCognitiveStep(reasoning: "Done.")])
        let input = TestAgentInputFactory.make(
            query: sentinel,
            generatorStrategy: NativeStructuredGenerator()
        )
        let stream = ReActAgentExecutor(maxIterations: 2)
            .execute(model: provider, input: input) { _ in }
        _ = try await StreamCollector.collect(from: stream)

        let firstRequest = try XCTUnwrap(provider.receivedCognitiveMessages.first)
        XCTAssertEqual(userMessagesContainingSentinel(firstRequest).count, 1,
                       "a chat run's query has exactly one carrier: the kickoff turn")
    }
}
