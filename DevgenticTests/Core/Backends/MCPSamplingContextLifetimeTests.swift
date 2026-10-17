// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
//
//  MCPSamplingContextLifetimeTests.swift
//  devgenticTests
//
//  Readiness CR-18: a sampling context lives exactly as long as the run that registered it.
//
//  ⚠️ THE DEFECT. `unregister` had zero callers. Contexts (each with a full ProviderConfig, API key
//  included) accumulated forever, and a server sampling outside any run was served by the newest
//  STALE one — approval raised in an unrelated conversation, billed to a finished run's profile.
//

import XCTest
@testable import devgentic

@MainActor
final class MCPSamplingContextLifetimeTests: XCTestCase {

    private let broker = MCPSamplingBroker.shared
    private var registered: [MCPSamplingContext] = []

    override func tearDown() async throws {
        for context in registered { broker.unregister(context) }
        registered = []
    }

    private func context(_ conversation: UUID, model: String = "m", at offset: TimeInterval = 0) -> MCPSamplingContext {
        let c = MCPSamplingContext(conversationID: conversation,
                                   providerConfig: ProviderConfig(apiProvider: .anthropic, modelName: model),
                                   profileID: nil, runMessageID: nil,
                                   registeredAt: Date().addingTimeInterval(offset))
        registered.append(c)
        return c
    }

    /// ⚠️⚠️ THE CR-18 DEFECT: once its run ends, a context must no longer serve sampling.
    func testAFinishedRunsContextNoLongerServesSampling() {
        let source = UUID()
        let run = context(UUID(), model: "finished-run-model", at: 1_000_000)  // newest, so the fallback would pick it
        broker.register(context: run)
        XCTAssertEqual(broker.resolveContext(for: source)?.providerConfig.modelName, "finished-run-model",
                       "precondition: while the run is live, it serves")

        broker.unregister(run)
        XCTAssertNotEqual(broker.resolveContext(for: source)?.registrationID, run.registrationID,
                          "a finished run's profile and key still served an out-of-band sampling request")
    }

    /// Ending an OLDER run must not withdraw a NEWER run's context for the same conversation.
    func testEndingAnOlderRunKeepsTheNewerRunsContext() {
        let conversation = UUID()
        let older = context(conversation, model: "older")
        let newer = context(conversation, model: "newer")
        broker.register(context: older)
        broker.register(context: newer)   // replaces older for this conversation

        broker.unregister(older)
        let source = UUID()
        broker.noteActivity(sourceID: source, conversationID: conversation)
        XCTAssertEqual(broker.resolveContext(for: source)?.registrationID, newer.registrationID)
    }

    /// A source that last drove a now-finished run falls back to a LIVE run, never the finished one.
    func testASourceMappingDoesNotOutliveItsRun() {
        let liveConversation = UUID(), finishedConversation = UUID(), source = UUID()
        let live = context(liveConversation, model: "live", at: 0)
        let finished = context(finishedConversation, model: "finished", at: 10)
        broker.register(context: live)
        broker.register(context: finished)
        broker.noteActivity(sourceID: source, conversationID: finishedConversation)

        broker.unregister(finished)
        XCTAssertNotEqual(broker.resolveContext(for: source)?.registrationID, finished.registrationID)
    }

    /// Both run paths (chat/agent and workflow node) withdraw their context when the run ends.
    func testBothRunPathsWithdrawTheirContext() throws {
        var dir = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        var source: String?
        for _ in 0..<10 {
            if let text = try? String(contentsOf: dir.appendingPathComponent("Devgentic/Core/Backends/TextGen/AgentConnect.swift"), encoding: .utf8) {
                source = text; break
            }
            dir = dir.deletingLastPathComponent()
        }
        let text = try XCTUnwrap(source)
        let registrations = text.components(separatedBy: "await MCPSamplingBroker.shared.register(context: samplingContext)").count - 1
        let withdrawals = text.components(separatedBy: "defer { Task { await MCPSamplingBroker.shared.unregister(samplingContext) } }").count - 1
        XCTAssertEqual(registrations, 2)
        XCTAssertEqual(withdrawals, registrations, "every registration must be paired with its withdrawal")
        XCTAssertFalse(text.contains("MCPSamplingBroker.shared.register(context: MCPSamplingContext("),
                       "a registration without a named context cannot be withdrawn")
    }
}
