// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
//
//  CrossRunHITLEgressTests.swift
//  devgenticTests
//
//  Cross-run HITL egress (found 2026-09-11 during the cluster-D fix, recorded in §6, fixed here).
//
//  Invariant 46 gates which RUNS the mirror observes: a run reaches a remote channel only when the
//  source that started it matches the remote session. `evaluateMessageState` then went around that
//  gate — it pulled pending interactions from `InteractionCenter.items(for: conversationID)`, which
//  is keyed by CONVERSATION, and `HITLOrigin` carried nothing to say which run had raised one. So
//  while a remote run was being mirrored, a tool confirmation raised by a LOCALLY-started run in the
//  same conversation had its tool name and parameters posted to the third-party chat.
//
//  ⚠️ THE PRECONDITION IS REACHABLE, WHICH IS WHY THIS IS A FIX AND NOT A THEORY. `ActiveStreamManager`
//  keys `activeStreams` by MESSAGE id, so two root runs in one conversation are representable; BR-4
//  closed the remote half of that door but the Mac composer is not disabled during a remote run, so
//  the local user can still start the second run.
//

import XCTest
@testable import devgentic

final class CrossRunHITLEgressTests: XCTestCase {

    // MARK: - The join key exists and says which run

    /// ⚠️ THE KEY IS THE AGENT MESSAGE ID, because that is the identifier BOTH sides already hold:
    /// `ActiveStreamManager` mints `TraceContext(messageID: agentMessage.id)` for the run and the
    /// mirror observes that same message. Nothing new is invented, so nothing can drift.
    func testAnOriginCarriesTheRunThatRaisedIt() {
        let run = UUID()
        let origin = HITLOrigin(interface: .chat, conversationID: UUID(), title: "t", runMessageID: run)
        XCTAssertEqual(origin.runMessageID, run)
    }

    /// Nil is representable and means "raised outside any run" — not "unknown run". The mirror's
    /// nil policy below depends on this distinction.
    func testAnOriginRaisedOutsideARunCarriesNoRunID() {
        XCTAssertNil(HITLOrigin(interface: .chat, conversationID: UUID(), title: "t").runMessageID)
    }

    // MARK: - The filter

    /// ⚠️ THE ACTUAL LEAK. Two runs, one conversation: only the observed run's item may be posted.
    func testAnItemRaisedByADifferentRunIsWithheld() {
        let conversation = UUID()
        let observedRun = UUID(), otherRun = UUID()

        let items = [
            pending(conversation: conversation, run: observedRun, tool: "read_file"),
            pending(conversation: conversation, run: otherRun, tool: "execute_shell")
        ]

        let mirrored = Self.mirrorable(items, observing: observedRun)
        XCTAssertEqual(mirrored.count, 1)
        XCTAssertEqual(Self.toolName(mirrored[0]), "read_file",
                       "the other run's tool name and parameters must not reach the remote channel")
    }

    /// ⚠️ NIL IS POSTED, DELIBERATELY. MCP elicitation's source→conversation association is made in
    /// `resolveMCPTool`, where no run identity is in scope, so its items carry nil. Treating nil as a
    /// mismatch would stop mirroring those prompts even for a run the remote user started — turning a
    /// leak fix into a hang. If elicitation later becomes attributable, this test is the one to change.
    func testAnItemRaisedOutsideAnyRunIsStillPosted() {
        let conversation = UUID()
        let observedRun = UUID()
        let items = [pending(conversation: conversation, run: nil, tool: "MCP elicitation")]

        XCTAssertEqual(Self.mirrorable(items, observing: observedRun).count, 1,
                       "an unattributable item must not be silently withheld — that is a hang, not a fix")
    }

    /// The common case must be untouched: a conversation with one run mirrors everything it raises.
    func testASingleRunMirrorsAllOfItsOwnItems() {
        let conversation = UUID(), run = UUID()
        let items = [
            pending(conversation: conversation, run: run, tool: "a"),
            pending(conversation: conversation, run: run, tool: "b")
        ]
        XCTAssertEqual(Self.mirrorable(items, observing: run).count, 2)
    }

    // MARK: - Wiring

    /// ⚠️ THE WIRING GUARD. The filter is one line inside `evaluateMessageState`; a policy test over a
    /// filter the mirror does not apply is exactly the shape of green-over-dead-code this repo has
    /// shipped before. Reads the real method and requires it to compare against the observed message.
    func testTheMirrorFiltersPendingItemsByTheObservedRun() throws {
        let source = try ChatOpsSecurityTierMatrixTests
            .readSourceStrippingComments("Devgentic/ChatOps/Services/RemoteMirrorService.swift")
        guard let range = source.range(of: "items(for: conversationID)") else {
            return XCTFail("evaluateMessageState no longer reads items(for: conversationID) — this test is blind")
        }
        let window = String(source[range.lowerBound...].prefix(400))
        XCTAssertTrue(window.contains("RemoteInteractionScope.belongingToRun"),
                      "the conversation-keyed item list must be narrowed by the shared scope function")
        XCTAssertTrue(window.contains("message.id"),
                      "it must be narrowed against the RUN BEING OBSERVED, not against anything else")
    }

    /// ⚠️ The stamp must survive at its one always-in-a-run producer. If `enqueueHITL` stops passing
    /// the trace context's message id, every item becomes nil — and, per the nil policy above, every
    /// item is posted again: the leak returns silently with all the policy tests still green.
    func testEnqueueHITLStampsTheRunFromTheTraceContext() throws {
        let source = try ChatOpsSecurityTierMatrixTests
            .readSourceStrippingComments("Devgentic/Core/Utils/ActiveStreamManager.swift")
        XCTAssertTrue(source.contains("runMessageID: traceContext.messageID"),
                      "enqueueHITL must stamp the run id, or every interaction becomes unattributable")
    }

    // MARK: - Helpers

    /// ⚠️ THE PRODUCTION FUNCTION, NOT A COPY OF IT. An earlier draft of this file transcribed the
    /// predicate, and mutation-checking showed every behavioural test above staying green while the
    /// mirror posted the whole conversation's items — they were exercising the transcription. Calling
    /// `RemoteInteractionScope` directly is what makes those tests mean something.
    private static func mirrorable(_ items: [PendingHITL], observing run: UUID) -> [PendingHITL] {
        RemoteInteractionScope.belongingToRun(run, in: items)
    }

    private static func toolName(_ item: PendingHITL) -> String? {
        if case .toolConfirmation(let c) = item.kind { return c.toolName }
        return nil
    }

    private func pending(conversation: UUID, run: UUID?, tool: String) -> PendingHITL {
        let id = UUID()
        return PendingHITL(
            id: id,
            origin: HITLOrigin(interface: .chat, conversationID: conversation,
                               title: "Permission required", runMessageID: run),
            kind: .toolConfirmation(PendingToolConfirmation(
                id: id, toolName: tool, params: "{}", risk: .moderate, arguments: nil))
        )
    }
}
