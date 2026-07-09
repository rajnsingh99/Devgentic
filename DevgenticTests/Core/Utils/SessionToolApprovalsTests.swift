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

        await store.allow(toolName: "write_file", conversationID: convA)

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
        await original.allow(toolName: "execute_shell", conversationID: conv)

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
        await store.allow(toolName: "delete_file", conversationID: conv)
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
        await store.allow(toolName: "move_file", conversationID: convA)
        await store.allow(toolName: "move_file", conversationID: convB)
        await store.clear(conversationID: convA)

        let stillInB = await store.isAllowed(toolName: "move_file", conversationID: convB)
        XCTAssertTrue(stillInB, "clearing one conversation must not affect another")
    }
}
