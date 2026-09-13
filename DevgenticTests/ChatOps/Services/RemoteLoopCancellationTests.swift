// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2026 Raj Singh
//
//  RemoteLoopCancellationTests.swift
//  devgenticTests
//
//  TG-6. `catch is CancellationError` never matched a cancelled URLSession call, so every deliberate
//  ChatOps stop wrote a line claiming a polling failure and a retry that never happened — into the
//  exported diagnostic bundle, because that line was at a persisted level.
//

import XCTest
@testable import devgentic

final class RemoteLoopCancellationTests: XCTestCase {

    // MARK: - What IS a cancellation

    func testASwiftCancellationErrorIsACancellation() {
        XCTAssertTrue(RemoteLoopCancellation.isCancellation(CancellationError()))
    }

    /// ⚠️ THE CASE THE OLD `catch is CancellationError` MISSED, and the entire reason this exists.
    /// A cancelled `URLSession` task throws `URLError(.cancelled)` — an ordinary error.
    func testACancelledURLSessionCallIsACancellation() {
        XCTAssertTrue(RemoteLoopCancellation.isCancellation(URLError(.cancelled)))
        XCTAssertTrue(RemoteLoopCancellation.isCancellation(
            NSError(domain: NSURLErrorDomain, code: NSURLErrorCancelled)))
    }

    // MARK: - What is NOT  ⚠️ pinned as deliberately as the true arms

    /// ⚠️⚠️ A SLOPPY "SWALLOW EVERY URLError" WOULD SILENTLY DISABLE THIS SUBSYSTEM'S TERMINAL
    /// CLASSIFIERS. A timeout and a dropped connection are real failures the backoff exists for; if
    /// they classified as cancellation the loop would exit quietly and the bridge would look stopped
    /// rather than broken — the exact invisibility the 401/403/409 work was added to end.
    func testOrdinaryNetworkFailuresAreNotCancellations() {
        for error in [URLError(.timedOut), URLError(.notConnectedToInternet),
                      URLError(.cannotFindHost), URLError(.networkConnectionLost),
                      URLError(.badServerResponse)] {
            XCTAssertFalse(RemoteLoopCancellation.isCancellation(error),
                           "\(error.code) is a real failure — the backoff and the terminal classifiers handle it")
        }
    }

    /// A terminal API failure must stay terminal. If this classified as cancellation, a revoked bot
    /// token would end the loop silently instead of writing `.error` to the Settings pane.
    func testATerminalAPIFailureIsNotACancellation() {
        XCTAssertFalse(RemoteLoopCancellation.isCancellation(
            TelegramAPIError.apiError(code: 401, description: "Unauthorized")))
        XCTAssertFalse(RemoteLoopCancellation.isCancellation(
            TelegramAPIError.apiError(code: 409, description: "Conflict")))
    }

    /// An error from an unrelated domain that happens to share the numeric code must not match.
    func testANonURLErrorSharingTheCodeIsNotACancellation() {
        XCTAssertFalse(RemoteLoopCancellation.isCancellation(
            NSError(domain: "com.example.other", code: NSURLErrorCancelled)))
    }
}
