// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
//
//  StopQueuedRunWiringTests.swift
//  DevgenticTests
//
//  Created by Raj Singh.
//

import XCTest

final class StopQueuedRunWiringTests: XCTestCase {

    /// The snapshot Stop reads must mark queued runs — from admission, the one place that knows.
    func testTheLiveRunSnapshotMarksQueuedRunsFromAdmission() throws {
        let source = try Self.read("Devgentic/Core/Utils/ActiveStreamManager.swift")
        let snapshot = try XCTUnwrap(source.range(of: "func liveRunSnapshot()"))
        let mark = try XCTUnwrap(source.range(of: "isQueued: admission.isWaiting(message.id)"))
        let cancel = try XCTUnwrap(source.range(of: "public func cancelStream(for messageId: UUID)"))
        XCTAssertTrue(snapshot.lowerBound < mark.lowerBound && mark.lowerBound < cancel.lowerBound,
                      "`isQueued` must be filled in INSIDE `liveRunSnapshot`")
    }

    /// Cancelling a queued run must withdraw its waiter, or it sits until the run in front ends.
    func testCancelStreamWithdrawsAQueuedWaiter() throws {
        let source = try Self.read("Devgentic/Core/Utils/ActiveStreamManager.swift")
        let cancel = try XCTUnwrap(source.range(of: "public func cancelStream(for messageId: UUID)"))
        let body = source[cancel.upperBound...].prefix(1500)
        let taskCancel = try XCTUnwrap(body.range(of: "taskToCancel.cancel()"))
        let forget = try XCTUnwrap(body.range(of: "admission.forget(messageID: messageId"),
                                   "cancelStream must call `admission.forget`")
        XCTAssertTrue(taskCancel.lowerBound < forget.lowerBound,
                      "cancel the task FIRST, so the resumed waiter sees `Task.isCancelled` and exits")
    }

    /// Stop must never run its conversation-wide park drain for a QUEUED target — that drain resolves
    /// another run's approval with `false` while its task is not cancelled: a denial nobody made.
    func testStopDoesNotDrainParksForAQueuedTarget() throws {
        let source = try Self.read("Devgentic/Interfaces/Main/MessagingCoordinator.swift")
        let stop = try XCTUnwrap(source.range(of: "func cancelStreamingResponse()"))
        let body = source[stop.upperBound...].prefix(6000)
        let cancel = try XCTUnwrap(body.range(of: "activeStreamManager.cancelStream(for: target.messageID)"))
        let guardQueued = try XCTUnwrap(body.range(of: "guard !target.isQueued else { return }"))
        let drain = try XCTUnwrap(body.range(of: "ExecutionSuspensionService.shared.cancel(for: conversationID)"))
        XCTAssertTrue(cancel.lowerBound < guardQueued.lowerBound, "the target is still cancelled")
        XCTAssertTrue(guardQueued.lowerBound < drain.lowerBound, "the guard must come BEFORE the drain")
    }

    private static func read(_ relativePath: String) throws -> String {
        var dir = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        for _ in 0..<10 {
            let candidate = dir.appendingPathComponent(relativePath)
            if FileManager.default.fileExists(atPath: candidate.path) {
                return try String(contentsOf: candidate, encoding: .utf8)
            }
            dir = dir.deletingLastPathComponent()
        }
        throw XCTSkip("Could not locate \(relativePath) — source-reading tests need the checkout present.")
    }
}
