// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2026 Raj Singh
//
//  HITLAuditResumeTests.swift
//  DevgenticTests
//
//  G1 Piece 2 — when a parked-then-interrupted HITL is successfully resumed, its durable audit row is
//  flipped from "interrupted" to "resumed" so the log reflects the recovery instead of over-counting it.
//  Verifies the flip, the guard (never clobber a genuine approve/deny outcome), and the no-op cases.
//

import XCTest
@testable import devgentic

final class HITLAuditResumeTests: XCTestCase {

    private var store: TraceStore!

    override func setUpWithError() throws {
        store = try TraceStore(inMemory: true)
    }

    override func tearDownWithError() throws {
        store = nil
    }

    private func record(op: String, conv: String, raisedAt: Date, outcome: String? = nil, resolvedAt: Date? = nil) -> HITLAuditRecord {
        HITLAuditRecord(
            operationID: op, conversationID: conv, interface: "chat", type: "permission",
            toolName: "write_file", nodeName: nil, title: "write_file",
            raisedAt: raisedAt, resolvedAt: resolvedAt, outcome: outcome
        )
    }

    func testInterruptedThenResumedFlipsOutcome() throws {
        let conv = "conv-1"
        try store.insertHITLAudit(record(op: "op-X", conv: conv, raisedAt: Date().addingTimeInterval(-60)))

        // Launch reconcile stamps the still-pending row "interrupted".
        XCTAssertEqual(try store.reconcileOrphanedHITL(before: Date(), reason: "test"), 1)
        XCTAssertEqual(try store.fetchHITLAudit(forConversationID: conv).first?.outcome, "interrupted")

        // A successful resume flips interrupted → resumed.
        XCTAssertEqual(try store.markHITLAuditResumed(operationID: "op-X"), 1)
        XCTAssertEqual(try store.fetchHITLAudit(forConversationID: conv).first?.outcome, "resumed")
    }

    func testResumeDoesNotClobberGenuineOutcome() throws {
        let conv = "conv-2"
        // A HITL that resolved cleanly (approved) before the quit — resume must NOT rewrite it.
        try store.insertHITLAudit(record(op: "op-Y", conv: conv, raisedAt: Date().addingTimeInterval(-60), outcome: "approved", resolvedAt: Date()))
        XCTAssertEqual(try store.markHITLAuditResumed(operationID: "op-Y"), 0, "Guard must skip non-interrupted rows.")
        XCTAssertEqual(try store.fetchHITLAudit(forConversationID: conv).first?.outcome, "approved")
    }

    func testResumeUnknownOperationIsNoOp() throws {
        XCTAssertEqual(try store.markHITLAuditResumed(operationID: "does-not-exist"), 0)
    }
}
