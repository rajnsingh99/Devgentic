// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2026 Raj Singh
//
//  TraceStoreSpanTests.swift
//  DevgenticTests
//
//  Covers span insertion semantics, in particular `ensureSpan` — the idempotent
//  insert-or-refresh primitive behind `TraceRecorder.ensureRootSpan`. The chat
//  pipeline's `beginTrace` auto-creates the root span as a generic "root"; the
//  workflow executor must be able to (a) guarantee the same row exists in
//  headless flows and (b) rename it to `workflow:<id8>` in the chat flow —
//  WITHOUT colliding on `spans.spanID` or clobbering the row's lifecycle
//  fields (startedAt / endedAt / status).
//

import XCTest
@testable import devgentic

final class TraceStoreSpanTests: XCTestCase {

    private var store: TraceStore!

    override func setUpWithError() throws {
        try super.setUpWithError()
        store = try TraceStore(inMemory: true)
    }

    override func tearDown() {
        store = nil
        super.tearDown()
    }

    private func makeSpan(
        spanID: String,
        traceID: String,
        name: String,
        startedAt: Date = Date()
    ) -> Span {
        Span(spanID: spanID, traceID: traceID, name: name, kind: .workflow, startedAt: startedAt)
    }

    /// `spans.traceID` references `traces` (FK enforced), so every span needs a
    /// parent trace row — mirrors what `beginTrace` inserts in production.
    private func insertTrace(_ traceID: String) throws {
        try store.insertTrace(TraceRecord(
            traceID: traceID,
            conversationID: UUID().uuidString,
            messageID: UUID().uuidString,
            profileID: UUID().uuidString,
            profileName: "Test Profile",
            profileType: "Workflow"
        ))
    }

    func testEnsureSpan_InsertsWhenMissing() throws {
        let traceID = UUID().uuidString
        try insertTrace(traceID)
        let span = makeSpan(spanID: UUID().uuidString, traceID: traceID, name: "workflow:abc")

        let inserted = try store.ensureSpan(span)

        XCTAssertTrue(inserted, "First ensure for a fresh spanID should report inserted")
        let rows = try store.fetchSpans(forTraceID: traceID)
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows.first?.name, "workflow:abc")
    }

    func testEnsureSpan_ExistingRow_RenamesAndPreservesLifecycle() throws {
        // The chat-flow sequence: beginTrace creates the root span ("root"), the
        // span runs and is even completed, then the workflow executor ensures the
        // same spanID under its own name. The ensure must rename the row but leave
        // its lifecycle (startedAt / endedAt / status) untouched.
        let traceID = UUID().uuidString
        try insertTrace(traceID)
        let spanID = UUID().uuidString
        let originalStart = Date(timeIntervalSinceNow: -120)
        try store.insertSpan(makeSpan(spanID: spanID, traceID: traceID, name: "root", startedAt: originalStart))
        try store.updateSpan(spanID: spanID, endedAt: Date(), status: .completed)

        let inserted = try store.ensureSpan(
            makeSpan(spanID: spanID, traceID: traceID, name: "workflow:abc")
        )

        XCTAssertFalse(inserted, "Existing spanID should be refreshed, not re-inserted")
        let rows = try store.fetchSpans(forTraceID: traceID)
        XCTAssertEqual(rows.count, 1, "No duplicate row")
        let row = try XCTUnwrap(rows.first)
        XCTAssertEqual(row.name, "workflow:abc", "Name should be refreshed to the caller's name")
        XCTAssertEqual(row.status, .completed, "Status must survive the rename")
        XCTAssertNotNil(row.endedAt, "endedAt must survive the rename")
        XCTAssertEqual(row.startedAt.timeIntervalSince1970,
                       originalStart.timeIntervalSince1970,
                       accuracy: 0.01,
                       "startedAt must keep the original (earlier) request start")
    }

    func testInsertSpan_DuplicateThrows() throws {
        // Documents why the executor must use ensureSpan: a plain insert of a
        // duplicate spanID violates the primary key.
        let traceID = UUID().uuidString
        try insertTrace(traceID)
        let spanID = UUID().uuidString
        try store.insertSpan(makeSpan(spanID: spanID, traceID: traceID, name: "root"))

        XCTAssertThrowsError(
            try store.insertSpan(makeSpan(spanID: spanID, traceID: traceID, name: "dup"))
        )
    }
}
