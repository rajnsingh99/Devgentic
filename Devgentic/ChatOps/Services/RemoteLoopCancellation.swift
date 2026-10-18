// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
//
//  RemoteLoopCancellation.swift
//  Devgentic
//
//  Created by Raj Singh.
//

import Foundation

// Why: `catch is CancellationError` misses a cancelled URLSession call (`URLError(.cancelled)`); other URLErrors are real failures
/// Whether an error is this loop being asked to stop rather than a failure worth reporting.
/// Classifies the error, not `Task.isCancelled`, and matches only the two URLError codes that mean cancellation.
enum RemoteLoopCancellation {

    /// True when `error` means "this call was cancelled", on any of the paths ChatOps polls.
    nonisolated static func isCancellation(_ error: Error) -> Bool {
        if error is CancellationError { return true }

        let nsError = error as NSError
        guard nsError.domain == NSURLErrorDomain else { return false }
        // `.cancelled` is what a cancelled URLSession task throws; `.userCancelledAuthentication` is included because a
        // cancelled challenge surfaces there and is equally not a failure.
        return nsError.code == NSURLErrorCancelled
            || nsError.code == NSURLErrorUserCancelledAuthentication
    }
}
