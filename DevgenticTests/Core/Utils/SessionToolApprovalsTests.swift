//
//  SessionToolApprovalsTests.swift
//  DevgenticTests
//
//  Locks the "Allow for this chat" contract: a tool approval is scoped STRICTLY to the conversation it
//  was made in, survives an app restart (durable round-trip), and is dropped only when explicitly
//  cleared (conversation deletion).
//

import XCTest
@testable import devgentic

final class SessionToolApprovalsTests: XCTestCase {

    /// An isolated UserDefaults suite so the durable store doesn't touch `.standard` or other tests.
    private func makeDefaults() -> UserDefaults {
        let suiteName = "test.sessionToolApprovals.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        return defaults
    }

    /// The core of the user's requirement: an approval in one conversation must NOT apply to another.
    func testApprovalIsScopedPerConversation() async {
        let defaults = makeDefaults()
        let convA = UUID()
        let convB = UUID()
        let store = SessionToolApprovals(defaults: defaults)

        await store.allow(toolName: "write_file", risk: .moderate, conversationID: convA)

        let inA = await store.isAllowed(toolName: "write_file", conversationID: convA)
        let inB = await store.isAllowed(toolName: "write_file", conversationID: convB)
        XCTAssertTrue(inA, "the tool must be allowed in the conversation it was approved in")
        XCTAssertFalse(inB, "the approval must NOT leak into a different conversation")
    }

    /// Survives a quit/relaunch: a fresh instance reading the same store sees the grant.
    func testApprovalSurvivesRestart() async {
        let defaults = makeDefaults()
        let conv = UUID()

        let original = SessionToolApprovals(defaults: defaults)
        await original.allow(toolName: "execute_shell", risk: .moderate, conversationID: conv)

        // Simulate relaunch: a brand-new actor hydrating from the same durable store.
        let reloaded = SessionToolApprovals(defaults: defaults)
        let allowed = await reloaded.isAllowed(toolName: "execute_shell", conversationID: conv)
        XCTAssertTrue(allowed, "a per-conversation grant must survive an app restart")
    }

    /// Clearing a conversation (deletion) drops its grants — including from the durable store.
    func testClearRemovesConversationGrant() async {
        let defaults = makeDefaults()
        let conv = UUID()

        let store = SessionToolApprovals(defaults: defaults)
        await store.allow(toolName: "delete_file", risk: .moderate, conversationID: conv)
        await store.clear(conversationID: conv)

        let reloaded = SessionToolApprovals(defaults: defaults)
        let allowed = await reloaded.isAllowed(toolName: "delete_file", conversationID: conv)
        XCTAssertFalse(allowed, "a cleared grant must not persist after the conversation is deleted")
    }

    /// Clearing one conversation must not disturb another's grants.
    func testClearIsScopedToOneConversation() async {
        let defaults = makeDefaults()
        let convA = UUID()
        let convB = UUID()

        let store = SessionToolApprovals(defaults: defaults)
        await store.allow(toolName: "move_file", risk: .moderate, conversationID: convA)
        await store.allow(toolName: "move_file", risk: .moderate, conversationID: convB)
        await store.clear(conversationID: convA)

        let stillInB = await store.isAllowed(toolName: "move_file", conversationID: convB)
        XCTAssertTrue(stillInB, "clearing one conversation must not affect another")
    }

    // MARK: - Workflow node scoping
    //
    // Every node of a workflow run shares ONE conversationID, so a conversation-wide grant meant
    // approving a tool in one node silently auto-approved it in every other node — including
    // nodes the user had deliberately configured to ask. Nodes configure their tools
    // independently, so an approval given to one is not an answer for another.

    /// The requirement, stated directly: same conversation, same tool, different node → ask again.
    func testApprovalInOneNodeDoesNotLeakToAnotherNode() async {
        let defaults = makeDefaults()
        let conversation = UUID()
        let nodeA = UUID()
        let nodeB = UUID()
        let store = SessionToolApprovals(defaults: defaults)

        await store.allow(toolName: "write_file", risk: .moderate, conversationID: conversation, nodeID: nodeA)

        let inA = await store.isAllowed(toolName: "write_file", conversationID: conversation, nodeID: nodeA)
        let inB = await store.isAllowed(toolName: "write_file", conversationID: conversation, nodeID: nodeB)
        XCTAssertTrue(inA, "the granting node must not be re-prompted")
        XCTAssertFalse(inB, "a different node of the SAME run must still ask")
    }

    /// No fall-back in either direction. A node grant must not satisfy a conversation-scoped
    /// check (that would leak into ordinary chat), and a conversation grant must not silently
    /// cover every node (that is the leak this scope exists to close).
    func testNodeAndConversationScopesDoNotFallBackToEachOther() async {
        let defaults = makeDefaults()
        let conversation = UUID()
        let node = UUID()
        let store = SessionToolApprovals(defaults: defaults)

        await store.allow(toolName: "read_file", risk: .moderate, conversationID: conversation, nodeID: node)
        let asConversation = await store.isAllowed(toolName: "read_file", conversationID: conversation)
        XCTAssertFalse(asConversation, "a node grant must not answer a conversation-scoped check")

        await store.allow(toolName: "grep_files", risk: .moderate, conversationID: conversation)
        let asNode = await store.isAllowed(toolName: "grep_files", conversationID: conversation, nodeID: node)
        XCTAssertFalse(asNode, "a conversation grant must not blanket-approve every node")
    }

    /// Deleting a conversation drops the whole run, nodes included — otherwise node grants would
    /// outlive the thing they were scoped to and never be reachable to clear.
    func testClearRemovesEveryNodeScopeInTheConversation() async {
        let defaults = makeDefaults()
        let conversation = UUID()
        let nodeA = UUID()
        let nodeB = UUID()
        let other = UUID()
        let store = SessionToolApprovals(defaults: defaults)

        await store.allow(toolName: "write_file", risk: .moderate, conversationID: conversation, nodeID: nodeA)
        await store.allow(toolName: "write_file", risk: .moderate, conversationID: conversation, nodeID: nodeB)
        await store.allow(toolName: "write_file", risk: .moderate, conversationID: conversation)
        await store.allow(toolName: "write_file", risk: .moderate, conversationID: other, nodeID: nodeA)

        await store.clear(conversationID: conversation)

        let a = await store.isAllowed(toolName: "write_file", conversationID: conversation, nodeID: nodeA)
        let b = await store.isAllowed(toolName: "write_file", conversationID: conversation, nodeID: nodeB)
        let conv = await store.isAllowed(toolName: "write_file", conversationID: conversation)
        let untouched = await store.isAllowed(toolName: "write_file", conversationID: other, nodeID: nodeA)
        XCTAssertFalse(a); XCTAssertFalse(b); XCTAssertFalse(conv)
        XCTAssertTrue(untouched, "a different conversation's node grant must survive")
    }

    func testNodeScopedGrantSurvivesRestart() async {
        let defaults = makeDefaults()
        let conversation = UUID()
        let node = UUID()

        let original = SessionToolApprovals(defaults: defaults)
        await original.allow(toolName: "batch_command", risk: .moderate, conversationID: conversation, nodeID: node)

        let reloaded = SessionToolApprovals(defaults: defaults)
        let sameNode = await reloaded.isAllowed(toolName: "batch_command", conversationID: conversation, nodeID: node)
        let otherNode = await reloaded.isAllowed(toolName: "batch_command", conversationID: conversation, nodeID: UUID())
        XCTAssertTrue(sameNode, "a node grant must survive an app restart")
        XCTAssertFalse(otherNode, "and must still not leak to another node after restart")
    }

    /// Grants written before node scoping existed are stored under a bare conversation UUID.
    /// They must hydrate as conversation-scoped rather than being discarded — the store key was
    /// deliberately NOT version-bumped so users keep the approvals they already gave.
    func testLegacyConversationOnlyKeysStillHydrate() async {
        let defaults = makeDefaults()
        let conversation = UUID()
        // Exactly the v1 on-disk shape: [conversationUUID: [toolName]], no node component.
        defaults.set([conversation.uuidString: ["execute_shell"]],
                     forKey: "hitl.perConversationToolApprovals.v1")

        let store = SessionToolApprovals(defaults: defaults)
        let allowed = await store.isAllowed(toolName: "execute_shell", conversationID: conversation)
        XCTAssertTrue(allowed, "a pre-existing conversation grant must not be dropped by the upgrade")
    }

    // MARK: - [WF-SE6] Grants are attended-only

    /// The store reads `WorkflowRunAttendance.isAttended` (a TaskLocal) on the caller's task:
    /// an interactive "Allow for this chat" grant must never auto-approve a scheduled or
    /// ChatOps run — that leak made one banner click a permanent unattended auto-approve.
    func testGrantIsNotServedWhenTheRunIsUnattended() async {
        let store = SessionToolApprovals(defaults: UserDefaults(suiteName: "se6-attendance-\(UUID().uuidString)")!)
        let conv = UUID(), node = UUID()
        await store.allow(toolName: "send_webhook", risk: .moderate, conversationID: conv, nodeID: node)

        let attended = await store.isAllowed(toolName: "send_webhook", conversationID: conv, nodeID: node)
        XCTAssertTrue(attended, "the default (attended) task keeps the existing behaviour")

        let unattended = await WorkflowRunAttendance.$isAttended.withValue(false) {
            await store.isAllowed(toolName: "send_webhook", conversationID: conv, nodeID: node)
        }
        XCTAssertFalse(unattended,
                       "an unattended run must not consume an interactive grant — unattended approval is the node's explicit setting, never a banner side effect")
    }
}
