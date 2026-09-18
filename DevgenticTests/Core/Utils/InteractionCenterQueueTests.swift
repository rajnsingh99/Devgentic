// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
//
//  InteractionCenterQueueTests.swift
//  DevgenticTests
//
//  The regression net for N5 (`LLM_Execution_Concurrency_Design.md` §9): when two workflow nodes
//  park at the same moment in one conversation, only ONE banner is visible and the second was
//  completely invisible — the user answered one and another appeared with no warning it existed.
//
//  ⚠️ `InteractionCenter` had ZERO test coverage before this file. `PendingInteractionTests` covers
//  only the PendingInteraction enum (Codable/Equatable/Identifiable), never the center's queue,
//  FIFO ordering, resolve, or conversation scoping. The banner's "1 of N" indicator reads
//  `items(for:)` and `current(for:)`, so those two are pinned here.
//
//  Constructs `InteractionCenter` directly — it is `@MainActor` with no injected dependencies.
//  Deliberately does NOT call `HITLPresenter.claim`, which sets a global weak reference.
//

import XCTest
@testable import devgentic

@MainActor
final class InteractionCenterQueueTests: XCTestCase {

    private let convA = UUID()
    private let convB = UUID()

    private func pending(_ conversation: UUID, node: String? = nil, id: UUID = UUID()) -> PendingHITL {
        PendingHITL(
            id: id,
            origin: HITLOrigin(
                interface: node == nil ? .chat : .workflow,
                conversationID: conversation,
                nodeID: node == nil ? nil : UUID(),
                nodeName: node,
                title: node.map { "\($0) · Permission required" } ?? "Permission required",
                profileID: nil
            ),
            kind: .clarification(PendingClarification(id: id, question: "?"))
        )
    }

    // MARK: - The N5 case: two nodes parked at once in ONE conversation

    func testTwoSimultaneousRequestsInOneConversation_bothQueuedButOnlyOnePresented() {
        let center = InteractionCenter()
        let first = pending(convA, node: "Security Review")
        let second = pending(convA, node: "Data Export")

        center.enqueue(first)
        center.enqueue(second)

        // The banner presents exactly one…
        XCTAssertEqual(center.current(for: convA)?.id, first.id, "presentation is FIFO — oldest first")
        // …but the queue depth the indicator reports must be 2, which is the whole point:
        // before this, nothing told the user a second request existed.
        XCTAssertEqual(center.items(for: convA).count, 2)
    }

    func testResolvingTheCurrentRequestAdvancesToTheNext() {
        let center = InteractionCenter()
        let first = pending(convA), second = pending(convA)
        center.enqueue(first)
        center.enqueue(second)

        center.resolve(operationID: first.id)

        XCTAssertEqual(center.current(for: convA)?.id, second.id)
        XCTAssertEqual(center.items(for: convA).count, 1, "the indicator must stop showing a queue of 2")
    }

    func testQueueDepthIsPerConversation() {
        let center = InteractionCenter()
        center.enqueue(pending(convA))
        center.enqueue(pending(convA))
        center.enqueue(pending(convB))

        // The banner is conversation-scoped (InteractionBannerStack keys on selectedConversationID),
        // so a request parked in another conversation must not inflate this one's count.
        XCTAssertEqual(center.items(for: convA).count, 2)
        XCTAssertEqual(center.items(for: convB).count, 1)
        XCTAssertEqual(center.current(for: convB)?.origin.conversationID, convB)
    }

    func testNoPendingMeansNoBannerAndNoIndicator() {
        let center = InteractionCenter()
        XCTAssertNil(center.current(for: convA))
        XCTAssertEqual(center.items(for: convA).count, 0)
        XCTAssertFalse(center.hasPending(for: convA))
    }

    func testResolveAllClearsOnlyThatConversation() {
        let center = InteractionCenter()
        center.enqueue(pending(convA))
        center.enqueue(pending(convA))
        center.enqueue(pending(convB))

        center.resolveAll(conversationID: convA)

        XCTAssertEqual(center.items(for: convA).count, 0)
        XCTAssertEqual(center.items(for: convB).count, 1, "a sibling conversation's park must survive")
    }

    // MARK: - Node attribution (the other half of N5)

    /// Each queued request must carry its own node name, so two simultaneous banners are
    /// distinguishable. Before the fix, a request forwarded out of a sub-workflow arrived with
    /// `nodeName == nil` because the title was resolved by looking `sourceNodeID` up in the PARENT's
    /// `nodeResults`, which never contains an inner node.
    func testEachQueuedRequestCarriesItsOwnNodeAttribution() {
        let center = InteractionCenter()
        center.enqueue(pending(convA, node: "Security Review"))
        center.enqueue(pending(convA, node: "Data Export"))

        let names = center.items(for: convA).map { $0.origin.nodeName }
        XCTAssertEqual(names, ["Security Review", "Data Export"])
        XCTAssertFalse(
            Set(center.items(for: convA).map { $0.origin.title }).count == 1,
            "two simultaneous requests must not render identical titles — that is the N5 defect"
        )
    }
}
