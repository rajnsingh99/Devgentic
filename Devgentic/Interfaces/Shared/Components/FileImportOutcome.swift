// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
//
//  FileImportOutcome.swift
//  Devgentic
//
//  Created on 07/08/26.
//
//  Classifies a SwiftUI `.fileImporter` result so a genuine failure can be told apart from the user
//  simply changing their mind.
//
//  ⚠️ Register A40/A60. All three importers in the app were written `if case .success(let urls) = result`
//  and dropped `.failure` on the floor — no message, no log, no retry hint. A permission denial, an
//  ejected volume, or an iCloud placeholder that fails to materialise looked EXACTLY like pressing
//  Cancel: the sheet closed and nothing happened.
//
//  ⚠️ The reason nobody had fixed it is the trap in the middle: SwiftUI reports **cancellation as a
//  `.failure`** too. Naively surfacing every `.failure` as an error would put a red banner on screen
//  every time a user backs out of the picker, which is worse than the silence it replaced. That is
//  what this type exists to separate — and why the three call sites share one implementation rather
//  than each re-deriving the check.
//

import Foundation

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
            // ⚠️ An empty selection is a dismissal, not an import of nothing. Treating it as
            // `.selected([])` would make every caller re-check `isEmpty` and one of them forget.
            return urls.isEmpty ? .cancelled : .selected(urls)

        case .failure(let error):
            return Self.isUserCancellation(error)
                ? .cancelled
                : .failed(error.localizedDescription)
        }
    }

    /// Whether this error is the user dismissing the picker rather than something going wrong.
    ///
    /// ⚠️ Checked against the underlying `NSError` domain/code rather than by casting to
    /// `CocoaError`: AppKit surfaces this through more than one error type, and a failed cast here
    /// fails OPEN — it would report a cancellation as a hard error, which is the exact false alarm
    /// this file exists to avoid.
    private static func isUserCancellation(_ error: Error) -> Bool {
        let nsError = error as NSError
        return nsError.domain == NSCocoaErrorDomain && nsError.code == NSUserCancelledError
    }
}
