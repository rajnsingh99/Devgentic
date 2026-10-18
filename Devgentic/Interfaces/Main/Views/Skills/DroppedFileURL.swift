// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
//
//  DroppedFileURL.swift
//  Devgentic
//
//  Created by Raj Singh.
//

import Foundation
import UniformTypeIdentifiers

/// Helpers for resolving a dragged item provider to a file URL.
extension NSItemProvider {
    /// Resolves a dropped item to a file URL, or nil when the item is neither a `URL` nor `Data`.
    /// A genuine file promise (`NSFilePromiseReceiver`) is not handled; the drop zone does not accept promise types.
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

/// The message to show for a drop that did not fully resolve, so an unreadable drop never fails in silence.
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
