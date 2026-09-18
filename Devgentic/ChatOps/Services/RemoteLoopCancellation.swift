// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
//
//  RemoteLoopCancellation.swift
//  Devgentic
//
//  Whether an error is this loop being asked to stop, rather than a failure worth reporting.
//
//  ⚠️⚠️ `catch is CancellationError` DOES NOT CATCH A CANCELLED NETWORK CALL, AND ALL FOUR CHATOPS
//  LOOPS WERE WRITTEN AS IF IT DID. `URLSession.data(from:)` and `URLSessionWebSocketTask.receive()`
//  surface cancellation as `URLError(.cancelled)` (NSURLErrorCancelled, −999) — an ordinary error, not
//  `CancellationError` — so every deliberate stop fell through to the generic arm and wrote a line
//  claiming a polling failure and a retry that never happened. `DGLogger.shouldPersist` keeps
//  `.warning` and above, so that noise reached the exported diagnostic bundle: precisely the artefact
//  the terminal-failure classifiers were added to make legible.
//
//  ⚠️⚠️ THE ERROR IS THE EVIDENCE, NOT `Task.isCancelled`. This subsystem has already been bitten by
//  treating `Task.isCancelled` as proof of ownership — it is false for an ORPHAN, and it can lag the
//  throw. Classifying the ERROR answers "was this call cancelled", which is the actual question.
//
//  ⚠️⚠️ AND IT MUST NOT SWALLOW EVERY `URLError`. A timeout, a dropped connection and a refused host
//  are real failures that the backoff and the terminal classifiers exist to handle; matching all of
//  `URLError` would silently disable the 401/403/409 and close-code work those classifiers do. The
//  codes below are exactly the two that mean "someone cancelled this", and the tests pin the FALSE
//  arms as deliberately as the true ones.
//

import Foundation

enum RemoteLoopCancellation {

    /// True when `error` means "this call was cancelled", on any of the paths ChatOps polls.
    nonisolated static func isCancellation(_ error: Error) -> Bool {
        if error is CancellationError { return true }

        let nsError = error as NSError
        guard nsError.domain == NSURLErrorDomain else { return false }
        // ⚠️ `.cancelled` is what a cancelled URLSession task throws. `.userCancelledAuthentication`
        //    is included because a cancelled challenge surfaces there and is equally not a failure.
        return nsError.code == NSURLErrorCancelled
            || nsError.code == NSURLErrorUserCancelledAuthentication
    }
}
