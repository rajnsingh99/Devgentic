// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
//
//  DroppedFileURL.swift
//  Devgentic
//
//  Resolving a dragged item to a file URL.
//
//  ⚠️ Lifted out of `SkillImportSheet` so it can be tested. It was `fileprivate` inside the view,
//  which is how it came to carry a doc comment describing a fix that had never been made: the
//  comment warned against `loadObject(ofClass: URL.self)` and the body called exactly that, and
//  nothing could reach it to notice.
//

import Foundation
import UniformTypeIdentifiers

extension NSItemProvider {
    /// Resolves a dropped item to a file URL.
    ///
    /// ⚠️ THE COMMENT THAT USED TO BE HERE WAS WRONG, AND SO WAS THE REASONING THAT REPLACED IT.
    /// It claimed `loadObject(ofClass: URL.self)` "returns nil for a promised file" while calling
    /// that very API. Measured (`registerDataRepresentation` and `registerItem`, both for
    /// `public.file-url`): **both APIs resolve both shapes**. The API choice was never the bug.
    ///
    /// `loadItem` is kept because the two `as` arms make the accepted shapes explicit rather than
    /// relying on NSItemProvider's coercion, but do not expect it to rescue a genuine file promise:
    /// that arrives as an `NSFilePromiseReceiver` under a promise type identifier, which
    /// `onDrop(of: [.fileURL])` does not accept in the first place. Supporting those is a separate
    /// change to the drop zone's accepted types, not to this function.
    ///
    /// ⚠️ The real defect was downstream: a nil here was `continue`d past in silence. See
    /// `SkillDropReport` — the drop that resolves to nothing now says so.
    func loadFileURL() async -> URL? {
        await withCheckedContinuation { continuation in
            loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, _ in
                switch item {
                case let url as URL:
                    continuation.resume(returning: url)
                case let data as Data:
                    continuation.resume(returning: URL(dataRepresentation: data, relativeTo: nil))
                default:
                    continuation.resume(returning: nil)
                }
            }
        }
    }
}

/// What to tell the user about a drop that did not fully resolve.
///
/// ⚠️⚠️ THIS IS THE ACTUAL FIX FOR THE SILENT DROP, and it is a pure function so it has a test.
/// The defect was never which NSItemProvider API was called — it was that a provider resolving to
/// nil was `continue`d past, so the user aimed at the target, let go, and the sheet did not react
/// at all: no row, no error, no spinner. Silence there reads as the feature being broken, and it is
/// the one failure they can act on (drag from Finder instead, or use Browse).
enum SkillDropReport {

    /// Nil when everything resolved — the caller must not overwrite a real error with a non-message.
    static func message(resolved: Int, unreadable: Int) -> String? {
        guard unreadable > 0 else { return nil }
        if resolved == 0 {
            return "That drop could not be read as \(unreadable == 1 ? "a file" : "files"). Some apps hand over a placeholder rather than a real file — try dragging from Finder, or use Browse."
        }
        return "\(unreadable) of \(unreadable + resolved) dropped items could not be read and were skipped. Try dragging those from Finder, or use Browse."
    }
}
