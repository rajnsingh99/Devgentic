//
//  PendingInteractionTests.swift
//  DevgenticTests
//
//  Created on 03/04/26.
//
//  Comprehensive tests for the unified PendingInteraction enum —
//  Codable round-trip, Equatable semantics, Identifiable contract,
//  shim backward compatibility, mutual exclusivity, and edge cases.
//

import XCTest
@testable import devgentic

@MainActor
final class PendingInteractionTests: XCTestCase {

    // MARK: - Construction & Identity

    func testToolConfirmationIdentity() {
        let opId = UUID()
        let interaction = PendingInteraction.toolConfirmation(
            PendingToolConfirmation(id: opId, toolName: "delete_file", params: "{\"path\":\"/tmp/x\"}")
        )
        XCTAssertEqual(interaction.id, opId)
        XCTAssertEqual(interaction.operationID, opId)
        XCTAssertEqual(interaction.toolName, "delete_file")
    }

    func testClarificationIdentity() {
        let opId = UUID()
        let interaction = PendingInteraction.clarification(
            PendingClarification(id: opId, question: "Which branch?")
        )
        XCTAssertEqual(interaction.id, opId)
        XCTAssertEqual(interaction.operationID, opId)
        XCTAssertNil(interaction.toolName)
    }

    func testPlanReviewIdentity() {
        let opId = UUID()
        let subtask = SubTask(description: "Step 1", status: .pending)
        let interaction = PendingInteraction.planReview(
            PendingPlanReview(id: opId, subtasks: [subtask])
        )
        XCTAssertEqual(interaction.id, opId)
        XCTAssertNil(interaction.toolName)
    }

    // MARK: - Codable Round-Trip

    func testToolConfirmationCodableRoundTrip() throws {
        let original = PendingInteraction.toolConfirmation(
            PendingToolConfirmation(id: UUID(), toolName: "bash", params: "{\"cmd\":\"ls\"}")
        )
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(PendingInteraction.self, from: data)
        XCTAssertEqual(decoded, original)
    }

    func testClarificationCodableRoundTrip() throws {
        let original = PendingInteraction.clarification(
            PendingClarification(id: UUID(), question: "What language?")
        )
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(PendingInteraction.self, from: data)
        XCTAssertEqual(decoded, original)
    }

    func testPlanReviewCodableRoundTrip() throws {
        let subtasks = [
            SubTask(description: "Research", status: .pending),
            SubTask(description: "Implement", status: .pending)
        ]
        let original = PendingInteraction.planReview(
            PendingPlanReview(id: UUID(), subtasks: subtasks)
        )
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(PendingInteraction.self, from: data)
        XCTAssertEqual(decoded, original)
    }

    // MARK: - Equatable

    func testEqualityToolConfirmation() {
        let opId = UUID()
        let a = PendingInteraction.toolConfirmation(PendingToolConfirmation(id: opId, toolName: "x", params: "{}"))
        let b = PendingInteraction.toolConfirmation(PendingToolConfirmation(id: opId, toolName: "x", params: "{}"))
        XCTAssertEqual(a, b)
    }

    func testInequalityDifferentTypes() {
        let opId = UUID()
        let tool = PendingInteraction.toolConfirmation(PendingToolConfirmation(id: opId, toolName: "x", params: "{}"))
        let clarify = PendingInteraction.clarification(PendingClarification(id: opId, question: "?"))
        XCTAssertNotEqual(tool, clarify)
    }

    func testInequalityDifferentIds() {
        let a = PendingInteraction.toolConfirmation(PendingToolConfirmation(id: UUID(), toolName: "x", params: "{}"))
        let b = PendingInteraction.toolConfirmation(PendingToolConfirmation(id: UUID(), toolName: "x", params: "{}"))
        XCTAssertNotEqual(a, b)
    }

    // MARK: - ChatMessage Integration

    func testSetAndClearInteraction() {
        let msg = ChatMessage(conversationId: UUID(), sender: .agent, content: .markdownText(""), backendEntityId: UUID())
        XCTAssertNil(msg.pendingInteraction)

        msg.pendingInteraction = .toolConfirmation(PendingToolConfirmation(id: UUID(), toolName: "bash", params: "{}"))
        XCTAssertNotNil(msg.pendingInteraction)

        msg.pendingInteraction = nil
        XCTAssertNil(msg.pendingInteraction)
    }

    func testMutualExclusivityOnChatMessage() {
        let msg = ChatMessage(conversationId: UUID(), sender: .agent, content: .markdownText(""), backendEntityId: UUID())

        msg.pendingInteraction = .toolConfirmation(PendingToolConfirmation(id: UUID(), toolName: "bash", params: "{}"))
        // Replace with clarification
        msg.pendingInteraction = .clarification(PendingClarification(id: UUID(), question: "Which?"))

        // Only clarification should be active
        if case .clarification = msg.pendingInteraction {
            // correct
        } else {
            XCTFail("Expected clarification, got \(String(describing: msg.pendingInteraction))")
        }
    }

    // MARK: - Deprecated Shim Tests (Backward Compatibility)

    func testToolConfirmationShimGetter() {
        let msg = ChatMessage(conversationId: UUID(), sender: .agent, content: .markdownText(""), backendEntityId: UUID())
        let confirmation = PendingToolConfirmation(id: UUID(), toolName: "delete", params: "{}")
        msg.pendingInteraction = .toolConfirmation(confirmation)

        // Deprecated getter should return the confirmation
        XCTAssertEqual(msg.pendingToolConfirmation?.toolName, "delete")
    }

    func testToolConfirmationShimGetterReturnsNilForOtherType() {
        let msg = ChatMessage(conversationId: UUID(), sender: .agent, content: .markdownText(""), backendEntityId: UUID())
        msg.pendingInteraction = .clarification(PendingClarification(id: UUID(), question: "?"))

        // pendingToolConfirmation should return nil when interaction is clarification
        XCTAssertNil(msg.pendingToolConfirmation)
    }

    func testToolConfirmationShimSetter() {
        let msg = ChatMessage(conversationId: UUID(), sender: .agent, content: .markdownText(""), backendEntityId: UUID())
        msg.pendingToolConfirmation = PendingToolConfirmation(id: UUID(), toolName: "bash", params: "{}")

        if case .toolConfirmation(let c) = msg.pendingInteraction {
            XCTAssertEqual(c.toolName, "bash")
        } else {
            XCTFail("Shim setter should create .toolConfirmation")
        }
    }

    func testClarificationShimSetter() {
        let msg = ChatMessage(conversationId: UUID(), sender: .agent, content: .markdownText(""), backendEntityId: UUID())
        msg.pendingClarification = PendingClarification(id: UUID(), question: "How?")

        if case .clarification(let c) = msg.pendingInteraction {
            XCTAssertEqual(c.question, "How?")
        } else {
            XCTFail("Shim setter should create .clarification")
        }
    }

    func testPlanReviewShimSetter() {
        let msg = ChatMessage(conversationId: UUID(), sender: .agent, content: .markdownText(""), backendEntityId: UUID())
        msg.pendingPlanReview = PendingPlanReview(id: UUID(), subtasks: [])

        if case .planReview = msg.pendingInteraction {
            // correct
        } else {
            XCTFail("Shim setter should create .planReview")
        }
    }

    func testShimSetNilOnlyClearsMatchingType() {
        let msg = ChatMessage(conversationId: UUID(), sender: .agent, content: .markdownText(""), backendEntityId: UUID())
        msg.pendingInteraction = .clarification(PendingClarification(id: UUID(), question: "?"))

        // Setting pendingToolConfirmation = nil should NOT clear clarification
        msg.pendingToolConfirmation = nil
        XCTAssertNotNil(msg.pendingInteraction, "Clearing wrong shim type should not affect active interaction")

        // Setting pendingClarification = nil SHOULD clear it
        msg.pendingClarification = nil
        XCTAssertNil(msg.pendingInteraction)
    }

    // MARK: - Equatable on ChatMessage with pendingInteraction

    func testChatMessageEqualityIncludesPendingInteraction() {
        let id = UUID()
        let convId = UUID()
        let msg1 = ChatMessage(id: id, conversationId: convId, sender: .user, content: .plainText("Test"))
        let msg2 = ChatMessage(id: id, conversationId: convId, sender: .user, content: .plainText("Test"))

        XCTAssertEqual(msg1, msg2)

        msg1.pendingInteraction = .toolConfirmation(PendingToolConfirmation(id: UUID(), toolName: "x", params: "{}"))
        XCTAssertNotEqual(msg1, msg2, "Messages with different pending interactions should not be equal")
    }

    func testChatMessageEqualityIncludesConversationId() {
        let id = UUID()
        let msg1 = ChatMessage(id: id, conversationId: UUID(), sender: .user, content: .plainText("A"))
        let msg2 = ChatMessage(id: id, conversationId: UUID(), sender: .user, content: .plainText("A"))
        XCTAssertNotEqual(msg1, msg2, "Messages from different conversations should not be equal")
    }

    func testChatMessageEqualityComparesTimelineEvents() {
        let id = UUID()
        let convId = UUID()
        let msg1 = ChatMessage(id: id, conversationId: convId, sender: .user, content: .plainText("A"))
        let msg2 = ChatMessage(id: id, conversationId: convId, sender: .user, content: .plainText("A"))

        msg1.timelineEvents = [.thought(id: UUID(), text: "X")]
        XCTAssertNotEqual(msg1, msg2, "Messages with different timeline events should not be equal")
    }

    // MARK: - ToolOutput Clearing Logic Simulation

    func testClearingClarificationOnAskUserToolOutput() {
        let msg = ChatMessage(conversationId: UUID(), sender: .agent, content: .markdownText(""), backendEntityId: UUID())
        msg.pendingInteraction = .clarification(PendingClarification(id: UUID(), question: "?"))

        // Simulate toolOutput clearing for ask_user
        if case .clarification = msg.pendingInteraction {
            msg.pendingInteraction = nil
        }

        XCTAssertNil(msg.pendingInteraction)
    }

    func testClearingToolConfirmationOnMatchingToolOutput() {
        let msg = ChatMessage(conversationId: UUID(), sender: .agent, content: .markdownText(""), backendEntityId: UUID())
        msg.pendingInteraction = .toolConfirmation(
            PendingToolConfirmation(id: UUID(), toolName: "delete_file", params: "{}")
        )

        // Simulate toolOutput clearing for matching tool
        if case .toolConfirmation(let pending) = msg.pendingInteraction, pending.toolName == "delete_file" {
            msg.pendingInteraction = nil
        }

        XCTAssertNil(msg.pendingInteraction)
    }

    func testNotClearingToolConfirmationOnNonMatchingToolOutput() {
        let msg = ChatMessage(conversationId: UUID(), sender: .agent, content: .markdownText(""), backendEntityId: UUID())
        msg.pendingInteraction = .toolConfirmation(
            PendingToolConfirmation(id: UUID(), toolName: "delete_file", params: "{}")
        )

        // Different tool output should NOT clear the confirmation
        if case .toolConfirmation(let pending) = msg.pendingInteraction, pending.toolName == "bash" {
            msg.pendingInteraction = nil
        }

        XCTAssertNotNil(msg.pendingInteraction, "Non-matching tool should not clear pending interaction")
    }

    func testNotClearingPlanReviewOnToolOutput() {
        let msg = ChatMessage(conversationId: UUID(), sender: .agent, content: .markdownText(""), backendEntityId: UUID())
        msg.pendingInteraction = .planReview(
            PendingPlanReview(id: UUID(), subtasks: [SubTask(description: "Step 1", status: .pending)])
        )

        // Tool output for ask_user should NOT clear plan review
        switch msg.pendingInteraction {
        case .clarification:
            msg.pendingInteraction = nil
        case .toolConfirmation(let pending) where pending.toolName == "ask_user":
            msg.pendingInteraction = nil
        default:
            break
        }

        XCTAssertNotNil(msg.pendingInteraction, "Plan review should not be cleared by unrelated tool output")
    }

    // MARK: - Finalization Clearing

    func testFinalizationClearsAllInteractionTypes() {
        let msg = ChatMessage(conversationId: UUID(), sender: .agent, content: .markdownText(""), backendEntityId: UUID())

        // Test each type is cleared by setting pendingInteraction = nil
        for interaction: PendingInteraction in [
            .toolConfirmation(PendingToolConfirmation(id: UUID(), toolName: "x", params: "{}")),
            .clarification(PendingClarification(id: UUID(), question: "?")),
            .planReview(PendingPlanReview(id: UUID(), subtasks: []))
        ] {
            msg.pendingInteraction = interaction
            XCTAssertNotNil(msg.pendingInteraction)

            // Simulate finalization
            msg.pendingInteraction = nil
            XCTAssertNil(msg.pendingInteraction)
        }
    }

    // MARK: - PendingInteraction with Empty/Edge Payloads

    func testToolConfirmationWithEmptyParams() {
        let interaction = PendingInteraction.toolConfirmation(
            PendingToolConfirmation(id: UUID(), toolName: "no_op", params: "")
        )
        XCTAssertEqual(interaction.toolName, "no_op")
    }

    func testClarificationWithEmptyQuestion() {
        let interaction = PendingInteraction.clarification(
            PendingClarification(id: UUID(), question: "")
        )
        if case .clarification(let c) = interaction {
            XCTAssertEqual(c.question, "")
        }
    }

    func testPlanReviewWithEmptySubtasks() {
        let interaction = PendingInteraction.planReview(
            PendingPlanReview(id: UUID(), subtasks: [])
        )
        if case .planReview(let p) = interaction {
            XCTAssertTrue(p.subtasks.isEmpty)
        }
    }

    func testPlanReviewWithManySubtasks() {
        let subtasks = (0..<50).map { SubTask(description: "Task \($0)", status: .pending) }
        let interaction = PendingInteraction.planReview(
            PendingPlanReview(id: UUID(), subtasks: subtasks)
        )
        if case .planReview(let p) = interaction {
            XCTAssertEqual(p.subtasks.count, 50)
        }
    }
}
