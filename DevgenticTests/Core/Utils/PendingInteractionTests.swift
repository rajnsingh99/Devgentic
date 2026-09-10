// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2026 Raj Singh
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

    // [HITL/P6] The `ChatMessage.pendingInteraction` single-optional + its deprecated shims
    // (pendingToolConfirmation/Clarification/PlanReview) were removed in the P6 cutover — pending HITL
    // now lives solely in `InteractionCenter`. The tests that exercised that removed API were deleted
    // here; the `PendingInteraction` enum tests above and the ChatMessage equality tests below remain.

    // MARK: - ChatMessage Equality

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
