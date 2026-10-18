// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
//
//  FileImportOutcome.swift
//  Devgentic
//
//  Created by Raj Singh.
//

import Foundation

/// Classifies a SwiftUI `.fileImporter` result so a genuine failure can be told apart from the user changing their mind.
/// SwiftUI reports cancellation as a `.failure` too, so every call site shares this one implementation of the check.
enum FileImportOutcome {
    /// The user picked at least one item.
    case selected([URL])
    /// The user dismissed the picker. Not an error; must never be surfaced as one.
    case cancelled
    /// The import genuinely failed. Carries a message fit to show the user.
    case failed(String)
}

extension Result where Success == [URL], Failure == Error {

    /// Splits this result into "got files", "user cancelled", and "actually broke".
    func fileImportOutcome() -> FileImportOutcome {
        switch self {
        case .success(let urls):
            // An empty selection is a dismissal, not an import of nothing; `.selected([])` would make callers re-check `isEmpty`.
            return urls.isEmpty ? .cancelled : .selected(urls)

        case .failure(let error):
            return Self.isUserCancellation(error)
                ? .cancelled
                : .failed(error.localizedDescription)
        }
    }

    // Why: check the underlying `NSError` domain/code, not a `CocoaError` cast: AppKit uses several error types and
    // a failed cast would report a cancellation as an error.
    /// Whether this error is the user dismissing the picker rather than something going wrong.
    private static func isUserCancellation(_ error: Error) -> Bool {
        let nsError = error as NSError
        return nsError.domain == NSCocoaErrorDomain && nsError.code == NSUserCancelledError
    }
}
